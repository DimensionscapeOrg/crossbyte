package crossbyte.net;

// Not built for the browser, for the same reason as ServerSocket: a page has
// no server key to hold.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
#if nodejs
import sys.io.File;
#elseif (java || jvm)
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslKey as NativeKey;
#else
import sys.ssl.Key as NativeKey;
#end

/**
 * The private key belonging to a `Certificate`.
 *
 * Kept separate from the certificate because that is how the material itself
 * is kept: two files, with different permissions, and often from different
 * places. See `Certificate` for why neither names a `sys.ssl` type.
 *
 * A key is the one piece of TLS material worth being careful about in an API.
 * It is never read back out, never logged, and never converted to a string:
 * the only thing that can be done with one is hand it to a server that is
 * about to present it. Printed (traced, logged, put in a string or, on
 * Node, given to `JSON.stringify` or `console.log`), it shows that it is a
 * key and nothing of it.
 */
final class Key {
	#if nodejs
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:noCompletion private var __pem:String;
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:noCompletion private var __passphrase:String;
	#else
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:allow(crossbyte._internal.socket)
	@:noCompletion private var __native:NativeKey;
	#end

	private function new() {
		#if nodejs
		// Kept out of what Node lists of an object. On Node a key holds its
		// PEM text and passphrase as they are, in two plain fields, which
		// JSON.stringify, console.log and a for-in (Std.string's fallback)
		// would each list, putting the key and the password protecting it
		// in a log. Not enumerable, none of them sees either.
		js.lib.Object.defineProperty(this, "__pem", {value: null, writable: true, enumerable: false});
		js.lib.Object.defineProperty(this, "__passphrase", {value: null, writable: true, enumerable: false});
		#end
	}

	/** That this is a key, and nothing of it. **/
	public function toString():String {
		return "[Key: redacted]";
	}

	#if nodejs
	/** What `JSON.stringify` writes for a key: the same as `toString`. **/
	public function toJSON():String {
		return toString();
	}
	#end


	/**
	 * Reads a PEM private key from disk.
	 *
	 * Every target takes every form a key file comes in: PKCS#8 (`BEGIN
	 * PRIVATE KEY`), PKCS#8 encrypted (`BEGIN ENCRYPTED PRIVATE KEY`), and
	 * the older PKCS#1 (`BEGIN RSA PRIVATE KEY`) and SEC1 (`BEGIN EC PRIVATE
	 * KEY`), plain or encrypted by OpenSSL. On Node the key is read, and an
	 * encrypted one decrypted, when a server or client first uses it, so a
	 * wrong password is reported there rather than here.
	 *
	 * @param path Path to the key file.
	 * @param password The passphrase, for a key that is encrypted. Omit for
	 *        one that is not.
	 * @throws ArgumentError If `path` is null or empty.
	 */
	public static function fromFile(path:String, ?password:String):Key {
		if (path == null || path == "") {
			throw new ArgumentError("A key needs a path to load from.");
		}

		var key = new Key();

		#if nodejs
		// Node decrypts an encrypted key itself, at the point it is used, so
		// the passphrase travels with it rather than being applied here.
		key.__pem = File.getContent(path);
		key.__passphrase = password;
		#elseif (java || jvm)
		key.__native = NativeKey.loadFile(path, false, password);
		#else
		var decrypted:Null<String> = password == null ? null : __decryptForMbedtls(sys.io.File.getContent(path), password);
		key.__native = decrypted != null ? NativeKey.readPEM(decrypted, false, null) : NativeKey.loadFile(path, false, password);
		#end

		return key;
	}

	/**
	 * Takes a PEM private key that is already in hand rather than one on disk
	 * (which is how a key arrives from a secret manager, and is the reason
	 * not to force every deployment to write one to a file first).
	 *
	 * It takes the forms `fromFile` does.
	 *
	 * @param pem The private key in PEM form.
	 * @param password The passphrase, for a key that is encrypted.
	 * @throws ArgumentError If `pem` is null or empty.
	 */
	public static function fromPem(pem:String, ?password:String):Key {
		if (pem == null || pem == "") {
			throw new ArgumentError("A key needs PEM text to read from.");
		}

		var key = new Key();

		#if nodejs
		key.__pem = pem;
		key.__passphrase = password;
		#elseif (java || jvm)
		key.__native = NativeKey.readPEM(pem, false, password);
		#else
		var decrypted:Null<String> = password == null ? null : __decryptForMbedtls(pem, password);
		if (decrypted != null) {
			key.__native = NativeKey.readPEM(decrypted, false, null);
		} else {
			#if eval
			key.__native = __evalReadPem(pem, password);
			#else
			key.__native = NativeKey.readPEM(pem, false, password);
			#end
		}
		#end

		return key;
	}

	#if !(nodejs || java || jvm)
	/**
		An encrypted PKCS#8 key the way OpenSSL encrypts one (PBES2 with
		AES), decrypted, since mbedTLS 2, which upstream hxcpp, hl, neko and
		eval carry, decrypts PBES2 with DES alone; null for any other key,
		which mbedTLS reads itself. See `EncryptedKey`.
	**/
	private static function __decryptForMbedtls(pem:String, password:String):Null<String> {
		return crossbyte._internal.socket.EncryptedKey.decryptPem(pem, password);
	}
	#end

	#if eval
	/**
		eval's own `readPEM` hands mbedTLS no password whatever it is given
		(its `loadFile` passes one, its `readPEM` passes `null`), so an
		encrypted key could not be read from text there at all, and the
		error would blame the password. This is that call with the password
		in it.
	**/
	private static function __evalReadPem(pem:String, password:Null<String>):NativeKey {
		var native:NativeKey = @:privateAccess new NativeKey();
		var code:Int = @:privateAccess native.native.parse_key(haxe.io.Bytes.ofString(pem), password, sys.ssl.Mbedtls.getDefaultCtrDrbg());
		if (code != 0) {
			throw mbedtls.Error.strerror(code);
		}
		return native;
	}
	#end
}
#end
