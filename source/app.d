module app;
import config;
import uuid;

import std;
import serverino;

mixin ServerinoMain;

/**
 * Qualsiasi richiesta che non sia post o delete, viene scartata.
 * Priorità 1000 per essere eseguita per prima, è un check fatto prima di tutti gli altri endpoint.
 */
@endpoint @priority(1000)
void notvalid(Request request, Output output)
{
	if (request.method != Request.Method.Post && request.method != Request.Method.Delete)
	{
		output.status(400);
		output ~= "Bad request.";
		warning("Metodo non valido: ", request.method);
	}
}

/**
 * Gestisce le richieste non valide o non corrispondenti ad altri endpoint.
 * Priorità -1 per essere eseguita per ultima, se nient'altro ha risposto.
 */
@endpoint @priority(-1)
void wrong(Request request, Output o)
{
	o.status(400);
	o ~= "Bad request.";

	warning("Richiesta non gestita: ", request.path);
}

/**
 * Gestisce la cancellazione di file dal bucket S3.
 * Accetta richieste DELETE nel formato /{hash}/{path} dove:
 * - hash è lo SHA256 del percorso del file concatenato con una chiave segreta
 * - path è il percorso completo del file da eliminare
 */
@endpoint
void remove(Request request, Output output)
{
	if (request.method != Request.Method.Delete)
		return;

	import std.regex;
	import std.digest.sha;

	// Verifica che il path sia nel formato corretto /{hash}/path/nomefile
	auto pathRegex = regex(r"^/([a-f0-9]{64})(/.*?)$");
	auto match = request.path.matchFirst(pathRegex);

	if (match.empty)
	{
		output.status(400);
		output ~= "Error: Bad request.\n";
		info("Match non valido: ", request.path);
		return;
	}

	string providedHash = match[1];
	string filePath = match[2];

	// Calcola l'hash atteso (SHA256 di /path/nomefile + DELETE_SECRET)
	string expectedHash = (filePath ~ DELETE_SECRET).sha256Of.toHexString.toLower.dup;

	// Verifica che l'hash sia corretto
	if (providedHash != expectedHash)
	{
		output.status(403);
		output ~= "Error: Forbidden.\n";
		warning("Hash non valido: ", providedHash);
		return;
	}

	// Esegui il comando s3cmd per cancellare il file
	import std.process : executeShell;

	auto result = executeShell(i"s3cmd del s3://filesharing/$(filePath.strip('/')) --access_key=$(AWS_ACCESS_KEY_ID) --secret_key=$(AWS_SECRET_ACCESS_KEY) --host=$(AWS_ENDPOINT_URL) --host-bucket=$(AWS_ENDPOINT_URL)/filesharing --region=$(AWS_REGION)".text);

	if (result.status != 0)
	{
		warning("Failed to delete ", filePath, " from cloud: ", result.output);
		output.status(500);
		output ~= "Error: Delete failed.\n";
		return;
	}
	else info("Deleted ", filePath, " from cloud");

	output.status(200);
	output.addHeader("Content-Type", "text/plain");
	output ~= "OK: File deleted successfully.\n";
}

/**
 * Gestisce l'upload di file al bucket S3.
 * Accetta richieste POST con un header x-file-path che indica il percorso locale del file.
 * Genera un UUID v7 come prefisso per il nome del file per garantire unicità.
 * Restituisce l'URL pubblico del file caricato e il comando per eliminarlo.
 */
@endpoint
void upload(Request request, Output output)
{
	if (request.method != Request.Method.Post)
		return;

	if (API_USER != "" && request.user != API_USER)
	{
		output.status(400);
		output ~= "Error: Bad request.\n";
		warning("Utente non autorizzato: ", request.user);
		return;
	}

	if (API_PASSWORD != "" && request.password != API_PASSWORD)
	{
		output.status(400);
		output ~= "Error: Bad request.\n";
		warning("Password non corretta: ", request.password);
		return;
	}

	if (request.header.read("x-file-path").empty)
	{
		output.status(400);
		output ~= "Error: Bad request.\n";
		warning("x-file-path non presente: ", request.path);
		return;
	}

	if (request.path == "/")
	{
		output.status(400);
		output ~= "Error: Bad request. Please add a file path to the URL.\n";
		warning("Path non valido: ", request.path);
		return;
	}

	string filePath = UUIDv7!string() ~ request.path;
	string localFile = request.header.read("x-file-path");

	import std.file : exists;
	import std.process : executeShell;

	if (!exists(localFile)) {
		output.status(400);
		output ~= "Error: File not found.\n";
		warning("File non trovato: ", localFile);
		return;
	}

	auto result = executeShell(i"s3cmd put $(localFile) s3://filesharing/$(filePath) --access_key=$(AWS_ACCESS_KEY_ID) --secret_key=$(AWS_SECRET_ACCESS_KEY) --host=$(AWS_ENDPOINT_URL) --host-bucket=$(AWS_ENDPOINT_URL)/filesharing --region=$(AWS_REGION) --acl-public".text);

	if (result.status != 0) {
		output.status(500);
		output ~= "Error: Upload failed.\n";
		warning("Upload failed: ", filePath);
		warning(result.output);
		return;
	}
	else info("Uploaded ", filePath, " to cloud");

	// Calcola l'hash SHA256 per il link di cancellazione
	import std.digest.sha;
	string deleteHash = ("/" ~ filePath ~ DELETE_SECRET).sha256Of.toHexString.toLower.dup;

	output.status(200);
	output.addHeader("Content-Type", "text/plain");
	output ~= "\n OK: File uploaded successfully.\n";
	output ~= i"\n * Public URL:\n https://$(CLOUD_SERVER)/".text ~ filePath ~ "\n";
	output ~= i"\n * To delete:\n curl -X DELETE https://$(API_SERVER)/".text ~ deleteHash ~ "/" ~ filePath ~ "\n";
	output ~= "\n";
}

/**
 * Configurazione di serverino
 */
@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
		.addListener("0.0.0.0", API_PORT)
		.setMaxWorkers(4)
		.setMinWorkers(0)
		.setWorkerUser(NGINX_USER)
		.setWorkerGroup(NGINX_GROUP)
		.setMaxRequestTime(30.seconds)
		.setMaxRequestSize(1024);
}
