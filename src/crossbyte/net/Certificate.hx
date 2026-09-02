package crossbyte.net;

// Not built for the browser, for the same reason as ServerSocket: a page has
// nothing to present a certificate to.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
#if nodejs
import sys.io.File;
#elseif (java || jvm)
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslCertificate as NativeCertificate;
#else
import sys.ssl.Certificate as NativeCertificate;
#end

/**
 * An X.509 certificate a server presents, or a certificate authority it
 * verifies clients against.
 *
 * This exists because the API used to be `sys.ssl.Certificate`, and saying so
 * in a signature is a decision about which targets can implement it. Node
 * terminates TLS perfectly well -- `tls.createServer` takes a key and a
 * certificate as PEM -- but it has no `sys.ssl`, so a method naming that type
 * could not be compiled there at all. The refusal read as "Node cannot serve
 * TLS", which was never true and which two documents and three error messages
 * repeated before anyone checked.
 *
 * So what a caller names is certificate *material*, and each target takes it
 * the way it wants: parsed into mbedtls on a native build, kept as PEM text on
 * Node. Nothing here is a wrapper for the sake of one -- it is the difference
 * between an API that describes what it needs and one that describes how one
 * target happens to supply it.
 *
 * Only what CrossByte and its callers actually use is here. `sys.ssl` also
 * offers a directory load and the system trust store, and neither is wrapped
 * until something wants them: an abstraction with unused members is a guess
 * about the second target, and the second target has arrived.
 */
final class Certificate {
	#if nodejs
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:noCompletion private var __pem:String;
	#else
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:allow(crossbyte._internal.socket)
	@:noCompletion private var __native:NativeCertificate;
	#end

	private function new() {}


	/**
	 * Reads a PEM certificate from disk.
	 *
	 * @param path Path to the certificate file.
	 * @throws ArgumentError If `path` is null or empty.
	 */
	public static function fromFile(path:String):Certificate {
		if (path == null || path == "") {
			throw new ArgumentError("A certificate needs a path to load from.");
		}

		var certificate = new Certificate();

		#if nodejs
		certificate.__pem = File.getContent(path);
		#else
		certificate.__native = NativeCertificate.loadFile(path);
		#end

		return certificate;
	}

	/**
	 * Takes a PEM certificate that is already in hand -- read from a secret
	 * store, fetched at startup, or held in configuration -- rather than one
	 * on disk.
	 *
	 * @param pem The certificate in PEM form.
	 * @throws ArgumentError If `pem` is null or empty.
	 */
	public static function fromPem(pem:String):Certificate {
		if (pem == null || pem == "") {
			throw new ArgumentError("A certificate needs PEM text to read from.");
		}

		var certificate = new Certificate();

		#if nodejs
		certificate.__pem = pem;
		#else
		certificate.__native = NativeCertificate.fromString(pem);
		#end

		return certificate;
	}
}
#end
