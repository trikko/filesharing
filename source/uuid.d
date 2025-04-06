module uuid;

/// Generate a UUID v4 (random bytes) as string
string UUIDv4(T = string)() if(is(T==string)) { return formatUUID(UUIDv4!ubyte); }

/// Generate a UUID v4 (random bytes) as ubyte[16]
ubyte[16] UUIDv4(T)() if (is(T == ubyte))
{
	ubyte[16] value;
	randomBytes(value);

	value[6] = (value[6] & 0x0f) | 0x40;
	value[8] = (value[8] & 0x3f) | 0x80;

	return value;
}

/// Generate a UUIDv7 (timestamp based + counter + random bytes) as string
string UUIDv7(T = string)() if(is(T==string)) { return formatUUID(UUIDv7!ubyte); }

/// Generate a UUIDv7 (timestamp based + counter + random bytes) as ubyte[16]
ubyte[16] UUIDv7(T)() if (is(T == ubyte))
{
	import core.atomic 	: atomicFetchAdd;
	import std.datetime 	: DateTime, SysTime, Clock, UTC;

	shared static uint counter = 0;
	shared static immutable unixEpoch = SysTime(DateTime(1970, 1, 1, 0, 0, 0), UTC());

	ubyte[16] value;

	randomBytes(value);

	// Current timestamp in ms
	auto now = Clock.currTime(UTC());
	auto timestamp = (now - unixEpoch).total!"msecs";

	// Timestamp
	value[0] = cast(ubyte)((timestamp >> 40) & 0xff);
	value[1] = cast(ubyte)((timestamp >> 32) & 0xff);
	value[2] = cast(ubyte)((timestamp >> 24) & 0xff);
	value[3] = cast(ubyte)((timestamp >> 16) & 0xff);
	value[4] = cast(ubyte)((timestamp >> 8) & 0xff);
	value[5] = cast(ubyte)(timestamp & 0xff);

	// Counter
	auto localCounter = atomicFetchAdd(counter, 1);
	value[6] = (value[6] & 0xF0) | cast(ubyte)((localCounter >> 8) & 0x0F); // first 4 bits [52-55]
	value[7] = cast(ubyte)(localCounter & 0xFF); // last 8 bits [56-63]

	// Version & Variant
	value[6] = (value[6] & 0x0f) | 0x70;
	value[8] = (value[8] & 0x3f) | 0x80;

	return value;
}

private:

string formatUUID(ubyte[16] uuid)
{
	import std.string : toLower;
	import std.format : format;
	import std.digest : toHexString;

	char[32] tmp = uuid.toHexString.toLower;
	return format("%s-%s-%s-%s-%s", tmp[0..8], tmp[8..12], tmp[12..16], tmp[16..20], tmp[20..$]);
}

void randomBytes(ubyte[] buffer)
{
	// Random bytes
	version(Windows)
	{
		import core.sys.windows.windows;
		import core.sys.windows.wincrypt;

		HCRYPTPROV hProvider;

		CryptAcquireContext(&hProvider, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT);
		CryptGenRandom(hProvider, cast(uint)buffer.length, buffer.ptr);
		CryptReleaseContext(hProvider, 0);
	}
	else
	{
		import std.file : read;
		buffer[0..$] = cast(ubyte[])read("/dev/urandom", buffer.length);
	}
}