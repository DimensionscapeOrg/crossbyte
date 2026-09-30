package crossbyte.db.mongodb._internal;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import haxe.crypto.Base64;
import haxe.io.Bytes;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	The client's side of one SCRAM-SHA-1 or SCRAM-SHA-256 exchange (RFC 5802,
	RFC 7677), as MongoDB runs it.

	`clientFirst`, then `clientFinal` with the server's first message, then
	`verifyServer` with its last. The server proves it knows the password too,
	and a server that cannot is refused: a man in the middle cannot finish the
	exchange by answering "done".

	MongoDB's SCRAM-SHA-1 hashes the password first, as
	`MD5(username + ":mongo:" + password)` in hexadecimal, and does not
	SASLprep it; SCRAM-SHA-256 SASLpreps the password itself.
**/
class Scram {
	public static inline var SHA1:String = "SCRAM-SHA-1";
	public static inline var SHA256:String = "SCRAM-SHA-256";

	/** Fewer rounds than this is a server weakening the password hash, and is refused. **/
	public static inline var MIN_ITERATIONS:Int = 4096;

	public var mechanism(default, null):String;

	@:noCompletion private var __digest:ScramDigest;
	@:noCompletion private var __user:String;
	@:noCompletion private var __password:Bytes;
	@:noCompletion private var __clientNonce:String;
	@:noCompletion private var __clientFirstBare:String;
	@:noCompletion private var __serverSignature:Bytes;

	// Salted passwords already derived, by mechanism, salt, rounds and a hash
	// of the password: PBKDF2 at MongoDB's 15,000 rounds is the whole cost of
	// signing in, and a pool signs in once per connection it opens with the
	// same credentials. The same cache the MongoDB drivers keep.
	@:noCompletion private static var __salted:Map<String, Bytes> = new Map();
	#if target.threaded
	@:noCompletion private static var __saltedLock:Mutex = new Mutex();
	#end

	/**
		@param clientNonce For tests only: the nonce to send instead of a fresh
		random one.
	**/
	public function new(mechanism:String, username:String, password:String, ?clientNonce:String) {
		if (mechanism != SHA1 && mechanism != SHA256) {
			throw new ArgumentError('Not a SCRAM mechanism: $mechanism.');
		}

		if (username == null || username == "") {
			throw new ArgumentError("SCRAM needs a user name.");
		}

		this.mechanism = mechanism;
		__digest = new ScramDigest(mechanism == SHA256);
		__user = username;
		__password = mechanism == SHA256 ? SaslPrep.prepare(password) : Bytes.ofString(haxe.crypto.Md5.encode(username + ":mongo:" + (password == null ? "" : password)));
		__clientNonce = clientNonce != null ? clientNonce : Base64.encode(__nonceBytes());
	}

	/** The first message: `n,,n=<user>,r=<nonce>`. **/
	public function clientFirst():Bytes {
		__clientFirstBare = "n=" + escapeName(__user) + ",r=" + __clientNonce;
		return Bytes.ofString("n,," + __clientFirstBare);
	}

	/**
		The final message, with the proof, for the server's first message.

		@throws IOError When the server's message is malformed, does not
		extend the client's nonce, or asks for fewer than 4096 rounds.
	**/
	public function clientFinal(serverFirstBytes:Bytes):Bytes {
		var serverFirst:String = serverFirstBytes.toString();
		var fields:Map<String, String> = parseFields(serverFirst);
		var nonce:String = fields.get("r");
		var salt:String = fields.get("s");
		var rounds:String = fields.get("i");

		if (fields.exists("m")) {
			throw new IOError("The server asked for a SCRAM extension this client does not support.");
		}

		if (nonce == null || salt == null || rounds == null) {
			throw new IOError('The server\'s first SCRAM message is malformed: "$serverFirst".');
		}

		if (!StringTools.startsWith(nonce, __clientNonce) || nonce.length <= __clientNonce.length) {
			throw new IOError("The server's SCRAM nonce does not extend the client's, so the exchange is not this one.");
		}

		var iterations:Int = crossbyte.utils.IntParse.decimal(rounds, 0x7FFFFFFF);

		if (iterations < MIN_ITERATIONS) {
			throw new IOError('The server asked for $rounds PBKDF2 rounds; fewer than $MIN_ITERATIONS is refused.');
		}

		var saltBytes:Bytes;

		try {
			saltBytes = Base64.decode(salt);
		} catch (_:Dynamic) {
			throw new IOError("The server's SCRAM salt is not base64.");
		}

		var withoutProof:String = "c=biws,r=" + nonce;
		var authMessage:Bytes = Bytes.ofString(__clientFirstBare + "," + serverFirst + "," + withoutProof);
		var salted:Bytes = __saltedPassword(saltBytes, salt, iterations);

		var clientKey:Bytes = __digest.hmac(salted, Bytes.ofString("Client Key"));
		var storedKey:Bytes = __digest.hash(clientKey);
		var signature:Bytes = __digest.hmac(storedKey, authMessage);
		var proof:Bytes = Bytes.alloc(clientKey.length);

		for (i in 0...clientKey.length) {
			proof.set(i, clientKey.get(i) ^ signature.get(i));
		}

		var serverKey:Bytes = __digest.hmac(salted, Bytes.ofString("Server Key"));
		__serverSignature = __digest.hmac(serverKey, authMessage);
		return Bytes.ofString(withoutProof + ",p=" + Base64.encode(proof));
	}

	/**
		Checks the server's final message: its signature, which only a server
		holding this user's keys can make.

		@throws IOError When the server reports an error, or its signature is
		not the one expected.
	**/
	public function verifyServer(serverFinalBytes:Bytes):Void {
		var serverFinal:String = serverFinalBytes.toString();
		var fields:Map<String, String> = parseFields(serverFinal);

		if (fields.exists("e")) {
			throw new IOError("The server ended the SCRAM exchange: " + fields.get("e"));
		}

		var verifier:String = fields.get("v");

		if (verifier == null || __serverSignature == null) {
			throw new IOError('The server\'s final SCRAM message is malformed: "$serverFinal".');
		}

		var claimed:Bytes;

		try {
			claimed = Base64.decode(verifier);
		} catch (_:Dynamic) {
			throw new IOError("The server's SCRAM signature is not base64.");
		}

		var difference:Int = claimed.length ^ __serverSignature.length;

		for (i in 0...(claimed.length < __serverSignature.length ? claimed.length : __serverSignature.length)) {
			difference |= claimed.get(i) ^ __serverSignature.get(i);
		}

		if (difference != 0) {
			throw new IOError("The server's SCRAM signature is wrong: it does not hold this user's keys.");
		}
	}

	/** `=` and `,` in a SCRAM name, as `=3D` and `=2C`. **/
	public static function escapeName(name:String):String {
		return StringTools.replace(StringTools.replace(name, "=", "=3D"), ",", "=2C");
	}

	/** A SCRAM message's `k=value` attributes. **/
	public static function parseFields(message:String):Map<String, String> {
		var out:Map<String, String> = new Map();

		for (part in message.split(",")) {
			var at:Int = part.indexOf("=");

			if (at == 1) {
				out.set(part.substr(0, 1), part.substr(2));
			}
		}

		return out;
	}

	@:noCompletion private function __saltedPassword(salt:Bytes, saltText:String, iterations:Int):Bytes {
		var key:String = mechanism + "\x01" + saltText + "\x01" + iterations + "\x01" + __digest.hash(__password).toHex();
		#if target.threaded
		__saltedLock.acquire();
		#end
		var known:Bytes = __salted.get(key);
		#if target.threaded
		__saltedLock.release();
		#end

		if (known != null) {
			return known;
		}

		var made:Bytes = __digest.pbkdf2(__password, salt, iterations);
		#if target.threaded
		__saltedLock.acquire();
		#end
		// Bounded: a process talks to few servers as few users, and anything
		// past that is not the pattern the cache is for.
		if (Lambda.count(__salted) >= 64) {
			__salted.clear();
		}

		__salted.set(key, made);
		#if target.threaded
		__saltedLock.release();
		#end
		return made;
	}

	/**
		24 bytes for the nonce, from the platform's secure generator where
		there is one. Where there is not -- the interpreter, neko, hl -- they
		come from the clock and `Math.random`: the nonce only has to be fresh
		for the exchange to be sound, since the server's half of it is what
		stops a replay, and nothing about the password depends on it.
	**/
	@:noCompletion private static function __nonceBytes():Bytes {
		if (crossbyte.crypto.SecureRandom.isSupported) {
			try {
				return crossbyte.crypto.SecureRandom.getSecureRandomBytes(24);
			} catch (_:Dynamic) {}
		}

		var out:Bytes = Bytes.alloc(24);
		var stamp:Int = Std.int((haxe.Timer.stamp() * 1000000.0) % 2147483647.0);

		for (i in 0...24) {
			out.set(i, (Std.random(256) ^ (stamp >> ((i % 4) * 8))) & 0xFF);
		}

		return out;
	}
}
