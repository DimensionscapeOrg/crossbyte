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
 * It is never read back out, never logged, and never converted to a string --
 * the only thing that can be done with one is hand it to a server that is
 * about to present it.
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

	private function new() {}

	#if (java || jvm)
	// The jvm target has no TLS backend at all -- JvmSslCertificate and
	// JvmSslKey are empty placeholders, and a secure ServerSocket or
	// ServerWebSocket refuses there outright. So nothing on jvm can reach a
	// point where a key is useful, and constructing one would hand back
	// an object that looks like credentials and is not.
	private static function refuse():Void {
		throw new crossbyte.errors.IllegalOperationError("TLS is not implemented on the jvm target, so a key cannot be loaded there. A secure ServerSocket already refuses for the same reason.");
	}
	#end

	/**
	 * Reads a PEM private key from disk.
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
		refuse();
		#else
		key.__native = NativeKey.loadFile(path, false, password);
		#end

		return key;
	}

	/**
	 * Takes a PEM private key that is already in hand rather than one on disk
	 * -- which is how a key arrives from a secret manager, and is the reason
	 * not to force every deployment to write one to a file first.
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
		refuse();
		#else
		key.__native = NativeKey.readPEM(pem, false, password);
		#end

		return key;
	}
}
#end
