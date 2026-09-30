package crossbyte.http;

// Not built for the browser, which does its own TLS and takes no settings for
// it; and a Certificate and a Key are not built there either.
#if !(js && !nodejs)
import crossbyte.net.Certificate;
import crossbyte.net.Key;
import crossbyte._internal.http.PublicKeyPins;
import haxe.io.Bytes;
#if !js
import crossbyte._internal.socket.FlexSocket;
#end

/**
	The TLS an `https` request asks for: whether the server is checked, which
	authority it is checked against, the certificate the request presents,
	and the public keys it pins.

	`URLLoader` builds one from the request's `verifyCert`, `certAuthority`,
	`clientCertificate`, `clientKey` and `pinnedPublicKeys`, and hands it to
	the client, or to a backend as `HTTPRequestContext.tls`. A connection
	opened under one set of options is reused only for a request whose options
	are the same -- the same settings and the same certificate and key objects
	-- so a request that checks its server is never sent down a connection
	opened without checking.

	There used to be no way to say any of this per request: trusting a private
	authority meant setting a process-wide static through `@:privateAccess`,
	and a client certificate could not be presented at all.
**/
final class HTTPTLSOptions {
	/** The options every request has unless it says otherwise. */
	public static final DEFAULT:HTTPTLSOptions = new HTTPTLSOptions();

	/**
		Whether the server's certificate is checked: that it chains to a
		trusted authority and names the host. `false` leaves the connection
		encrypted but lets anyone able to sit in the middle read it.
	**/
	public final verifyCert:Bool;

	/** The authority trusted in place of the system's, or null for the system's. */
	public final certAuthority:Null<Certificate>;

	/** The certificate presented to a server that asks for one, with `key`. */
	public final certificate:Null<Certificate>;

	/** The private key belonging to `certificate`. */
	public final key:Null<Key>;

	/**
		Pins, as base64 SHA-256 digests of SubjectPublicKeyInfo, without the
		`sha256/` they may be written with; null or empty pins nothing.
	**/
	public final pinnedPublicKeys:Null<Array<String>>;

	public function new(verifyCert:Bool = true, ?certAuthority:Certificate, ?certificate:Certificate, ?key:Key, ?pinnedPublicKeys:Array<String>) {
		this.verifyCert = verifyCert;
		this.certAuthority = certAuthority;
		this.certificate = certificate;
		this.key = key;
		var pins:Null<Array<String>> = null;
		if (pinnedPublicKeys != null && pinnedPublicKeys.length > 0) {
			pins = [];
			for (pin in pinnedPublicKeys) {
				if (pin != null && StringTools.trim(pin).length > 0) {
					pins.push(PublicKeyPins.normalize(pin));
				}
			}
		}
		this.pinnedPublicKeys = pins;
	}

	/** Whether these are the defaults: checked, the system's authorities, nothing presented or pinned. */
	public function isDefault():Bool {
		return verifyCert && certAuthority == null && certificate == null && key == null && (pinnedPublicKeys == null || pinnedPublicKeys.length == 0);
	}

	/**
		These options without the client certificate, for a redirect that has
		left the request's origin: the certificate was meant for the server the
		caller named, as its `Authorization` was.
	**/
	public function withoutClientCertificate():HTTPTLSOptions {
		return certificate == null && key == null ? this : new HTTPTLSOptions(verifyCert, certAuthority, null, null, pinnedPublicKeys);
	}

	/**
		Whether a connection opened under `a` may carry a request made under
		`b`. `null` is the defaults. Certificates and keys are compared as
		objects: two loaded from one file are two, and do not share.
	**/
	public static function same(a:Null<HTTPTLSOptions>, b:Null<HTTPTLSOptions>):Bool {
		var x:HTTPTLSOptions = a != null ? a : DEFAULT;
		var y:HTTPTLSOptions = b != null ? b : DEFAULT;
		if (x == y) {
			return true;
		}
		if (x.verifyCert != y.verifyCert || x.certAuthority != y.certAuthority || x.certificate != y.certificate || x.key != y.key) {
			return false;
		}
		var xPins:Int = x.pinnedPublicKeys == null ? 0 : x.pinnedPublicKeys.length;
		var yPins:Int = y.pinnedPublicKeys == null ? 0 : y.pinnedPublicKeys.length;
		if (xPins != yPins) {
			return false;
		}
		for (i in 0...xPins) {
			if (x.pinnedPublicKeys[i] != y.pinnedPublicKeys[i]) {
				return false;
			}
		}
		return true;
	}

	#if !js
	/** Applies these to `socket`, a secure one not yet connected. */
	@:noCompletion public function configure(socket:FlexSocket):Void {
		if (!verifyCert) {
			socket.verifyCert = false;
		}
		if (certAuthority != null) {
			socket.setCA(certAuthority.__native);
		}
		if (certificate != null && key != null) {
			socket.setCertificate(certificate.__native, key.__native);
		}
	}

	/**
		Why the server `socket` is connected to fails these options' pins, or
		null when it passes or nothing is pinned. Called once the handshake is
		done, before anything is sent.
	**/
	@:noCompletion public function checkPins(socket:FlexSocket):Null<String> {
		if (pinnedPublicKeys == null || pinnedPublicKeys.length == 0) {
			return null;
		}
		var der:Null<Bytes> = __peerCertificate(socket);
		if (der == null) {
			return #if (cpp || java || jvm) "The server presented no certificate to check its pinned public key against" #else "Public key pinning is not available on this target: its TLS gives no access to the server's certificate" #end;
		}
		var pin:Null<String> = PublicKeyPins.pinOf(der);
		if (pin == null) {
			return "The server's certificate could not be read for its public key";
		}
		if (pinnedPublicKeys.indexOf(PublicKeyPins.normalize(pin)) >= 0) {
			return null;
		}
		return "The server's public key, " + pin + ", is not one this request pins";
	}

	/** The DER of the certificate the server presented, where the target can say. */
	private static function __peerCertificate(socket:FlexSocket):Null<Bytes> {
		try {
			#if cpp
			var context:Dynamic = @:privateAccess (cast socket : sys.ssl.Socket).ssl;
			var der:Null<Array<cpp.UInt8>> = crossbyte._internal.http.NativeTlsPeer.der(context);
			return der == null ? null : Bytes.ofData(der);
			#elseif (java || jvm)
			var certificate = (cast socket : crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket).peerCertificate();
			return certificate == null ? null : Bytes.ofData(certificate.native.getEncoded());
			#else
			return null;
			#end
		} catch (_:Dynamic) {
			return null;
		}
	}
	#end
}
#end
