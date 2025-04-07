module app;
import config;

import std;
import serverino;

mixin ServerinoMain;

/**
 * Gestisce le richieste non valide o non corrispondenti ad altri endpoint.
 * Priorità -1 per essere eseguita per ultima, se nient'altro ha risposto.
 */
@endpoint @priority(-1)
void wrong(Request request, Output o)
{
	o.status(400);
	o.addHeader("Content-Type", "text/plain");
	o ~= "Bad request.";

	warning("Richiesta non gestita: ", request.path);
}

/**
 * Gestisce la cancellazione di file dal bucket S3.
 * Accetta richieste DELETE nel formato /file/path?h=hash dove:
 * - path è il percorso completo del file da eliminare
 * - hash è lo SHA256 del percorso del file concatenato con una chiave segreta
 */
@endpoint
void remove(Request request, Output output)
{
	import std.digest.sha;
	if (request.method != Request.Method.Delete)
		return;

	output.addHeader("Content-Type", "text/plain");

	// Verifica che ci sia un parametro h nella query
	if (request.get.has("h") == false)
	{
		output.status(400);
		output ~= "Error: Missing hation hash.\n";
		info("Hash di conferma mancante: ", request.path);
		return;
	}

	string providedHash = request.get.read("h");
	string filePath = request.path;

	// Calcola l'hash atteso (SHA256 di /path/nomefile + DELETE_SECRET)
	string expectedHash = (filePath ~ DELETE_SECRET).sha256Of.toHexString.toLower.dup[0..32];

	// Verifica che l'hash sia corretto
	if (providedHash != expectedHash)
	{
		output.status(403);
		output ~= "Error: Forbidden.\n";
		warning("Hash non valido: ", providedHash);
		return;
	}

	// Esegui il comando s3cmd per cancellare il file
	auto result = execute(["s3cmd", "del", i"s3://$(AWS_BUCKET)/".text ~ filePath.strip('/'),
		"--access_key=" ~ AWS_ACCESS_KEY_ID,
		"--secret_key=" ~ AWS_SECRET_ACCESS_KEY,
		"--host=" ~ AWS_ENDPOINT_URL,
		"--host-bucket=" ~ AWS_ENDPOINT_URL ~ i"/$(AWS_BUCKET)".text,
		"--region=" ~ AWS_REGION,
		"-q"]);

	if (result.status != 0)
	{
		warning("Failed to delete ", filePath, " from cloud: ", result.output);
		output.status(500);
		output ~= "Error: Delete failed.\n";
		return;
	}
	else info("Deleted ", filePath, " from cloud");

	output.status(200);
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

	output.addHeader("Content-Type", "text/plain");

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


	string filePath = customUUID() ~ request.path;
	string localFile = request.header.read("x-file-path");

	if (!exists(localFile)) {
		output.status(400);
		output ~= "Error: File not found.\n";
		warning("File non trovato: ", localFile);
		return;
	}

	auto cmd = ["s3cmd", "put", localFile, i"s3://$(AWS_BUCKET)/".text ~ filePath,
		"--access_key=" ~ AWS_ACCESS_KEY_ID,
		"--secret_key=" ~ AWS_SECRET_ACCESS_KEY,
		"--host=" ~ AWS_ENDPOINT_URL,
		"--host-bucket=" ~ AWS_ENDPOINT_URL ~ i"/$(AWS_BUCKET)".text,
		"--region=" ~ AWS_REGION,
		"--acl-public", "-q"];


	if (STORAGE_CLASS != "")
		cmd ~= ["--storage-class=" ~ STORAGE_CLASS];

	// Lancia un processo per l'upload e un altro per rimuovere il file locale quando l'upload è completo
	auto pid = spawnProcess(cmd, environment.toAA(), Config.detached).osHandle;
	spawnShell(i"while kill -0 $(pid) 2>/dev/null; do sleep 1; done; rm $(localFile)".text, environment.toAA(), Config.detached);

	/*
	 * NOTE:Diamo per scontato che l'upload server --> S3 funzioni (di norma è in locale), quindi non aspettiamo il risultato
	 * mal che vada l'utente non trova il file e riproverà.
	 */

	/*
	// Attende il completamento dell'upload su S3
	scope(exit) remove(localFile);

	auto result = execute(cmd);
	if (result.status != 0)
		output.status(500);
		output ~= "Error: Upload failed.\n";
		warning("Upload failed: ", filePath);
		warning(result.output);
		return;
	}
	*/

	info("Uploaded ", filePath, " to cloud");

	// Calcola l'hash SHA256 per il link di cancellazione
	import std.digest.sha;
	string deleteHash = ("/" ~ filePath ~ DELETE_SECRET).sha256Of.toHexString.toLower.dup[0..32];

	output.status(200);
	output ~= "\n OK: File uploaded successfully. It should be available soon.\n";
	output ~= i"\n * Public URL:\n https://$(API_SERVER)/".text ~ encode(filePath) ~ "\n";
	output ~= i"\n * To delete:\n curl -X DELETE https://$(API_SERVER)/".text ~ encode(filePath) ~ "?h=" ~ deleteHash ~ "\n";
	output ~= "\n";
}

@endpoint
void download(Request request, Output output)
{
	if (request.method != Request.Method.Get)
		return;

	// Verifica che il path sia nel formato corretto: /[base62]/percorso
	auto pathRegex = regex(r"^/[0-9a-zA-Z]{12,}/.*$");
	if (!matchFirst(request.path, pathRegex))
	{
		output.status(400);
		output.addHeader("Content-Type", "text/plain");
		output ~= "Error: Bad request.\n";
		warning("Formato path non valido: ", request.path);
		return;
	}

	output.status(302);
	output.addHeader("Location", i"https://$(CLOUD_SERVER)$(request.path)".text);
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


/**
 * Genera un UUID personalizzato nel formato:
 * timestamp_ms(padded) ~ contatore(0-999) - random(000-999) - pid
 */
private string customUUID() {
	immutable shared static dt = DateTime(2000, 1, 1, 0, 0, 0);

	static int counter = 0;
	counter = (counter + 1) % 1000;

	auto ts = (Clock.currTime() - cast(SysTime)dt).total!"usecs";
	auto rnd = uniform(0, 1000);
	auto pid = thisProcessID();

	auto id = format("%017d%03d%03d%d", ts, counter, rnd, pid);
	return decimalToBase62(id);
}

/**
 * Converte una stringa decimale in base62 (0-9, a-z, A-Z)
 * Usato per generare ID più compatti e URL-friendly
 */
string decimalToBase62(string decimalStr)
{

	// Caratteri per la codifica base62
	immutable string BASE62_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
	immutable int BASE = BASE62_CHARS.length;

	// Rimuovi eventuali spazi e verifica input
	decimalStr = decimalStr.strip();
	if (decimalStr.length == 0)
		return "0";

	// Risultato in formato base62 (al contrario)
	auto result = appender!string();

	// Continua la divisione finché il numero non diventa zero
	while (decimalStr.length > 0 && decimalStr != "0") {
		int remainder = 0;
		string newDecimal = "";

		// Divisione per BASE cifra per cifra
		foreach (c; decimalStr) {
			int digit = c - '0';
			int current = remainder * 10 + digit;
			newDecimal ~= to!char(current / BASE + '0');
			remainder = current % BASE;
		}

		// Rimuovi gli zeri iniziali
		while (newDecimal.length > 1 && newDecimal[0] == '0')
			newDecimal = newDecimal[1..$];

		// Aggiungi il carattere corrispondente al resto
		result.put(BASE62_CHARS[remainder]);

		decimalStr = newDecimal;
	}

	// Inverti il risultato
	return result.data.dup.reverse();
}
