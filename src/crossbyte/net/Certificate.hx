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
 * It is CrossByte's own type rather than `sys.ssl.Certificate` because
 * naming that type in a signature decides which targets can implement it.
 * Node terminates TLS perfectly well (`tls.createServer` takes a key and a
 * certificate as PEM) but has no `sys.ssl`, so a method naming that type
 * could not be compiled there at all.
 *
 * So what a caller names is certificate *material*, and each target takes it
 * the way it wants: parsed into mbedtls on a native build, kept as PEM text on
 * Node. Nothing here is a wrapper for the sake of one: it is the difference
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
	@:allow(crossbyte._internal.websocket)
	@:noCompletion private var __pem:String;
	#else
	@:allow(crossbyte.net)
	@:allow(crossbyte.http)
	@:allow(crossbyte._internal.socket)
	@:allow(crossbyte._internal.websocket)
	@:noCompletion private var __native:NativeCertificate;
	#end

	// What it was made from: a file's bytes or PEM text, or the DER a peer
	// presented; and the DER of its first certificate, read from it once.
	@:noCompletion private var __source:Null<haxe.io.Bytes> = null;
	@:noCompletion private var __der:Null<haxe.io.Bytes> = null;

	private function new() {}

	/**
		The DER encoding of the certificate (the first, for a chain), the
		bytes its fingerprint is taken over:
		`haxe.crypto.Sha256.make(certificate.der).toHex()` is the SHA-256
		fingerprint `openssl x509 -fingerprint -sha256` prints, without the
		colons. Null for material that is not a certificate CrossByte can
		read.
	**/
	public var der(get, never):Null<haxe.io.Bytes>;

	@:noCompletion private function get_der():Null<haxe.io.Bytes> {
		if (__der == null && __source != null) {
			__der = crossbyte._internal.net.CertificateDer.firstOf(__source);
		}
		return __der;
	}

	/**
		The common name (CN) in the certificate's subject, or null if it has
		none: what names a client presenting it, for a server that asked for
		client certificates. For a chain, the first certificate's.
	**/
	public var commonName(get, never):Null<String>;

	@:noCompletion private function get_commonName():Null<String> {
		return crossbyte._internal.net.CertificateDer.commonNameOf(der);
	}

	/** The certificate a peer presented, from its DER. **/
	@:noCompletion private static function __fromDer(der:haxe.io.Bytes):Certificate {
		var certificate:Certificate = fromPem(crossbyte._internal.net.CertificateDer.pemOf(der));
		certificate.__der = der;
		return certificate;
	}

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
		certificate.__source = haxe.io.Bytes.ofString(certificate.__pem);
		#else
		certificate.__native = NativeCertificate.loadFile(path);
		try {
			certificate.__source = sys.io.File.getBytes(path);
		} catch (_:Dynamic) {}
		#end

		return certificate;
	}

	/**
	 * Takes a PEM certificate that is already in hand (read from a secret
	 * store, fetched at startup, or held in configuration) rather than one
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
		certificate.__source = haxe.io.Bytes.ofString(pem);

		return certificate;
	}
}
#end
