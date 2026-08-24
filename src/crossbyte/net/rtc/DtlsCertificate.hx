package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
#if cpp
import crossbyte.net.rtc._internal.NativeDtls;
#end

/**
	The certificate a peer proves itself with, and the fingerprint it publishes.

	WebRTC has no certificate authority in it. Each peer generates a
	certificate, signs it itself, and sends a hash of it over the signalling
	channel that already brought the two together; the handshake then checks
	that the certificate presented hashes to what was signalled. The trust comes
	from the signalling channel, and the certificate only has to be stable for
	the length of a session -- which is why generating one per connection is
	normal here rather than negligent.

	```haxe
	var certificate = DtlsCertificate.generate();
	trace("a=fingerprint:sha-256 " + certificate.fingerprint);
	```

	## What the fingerprint is over

	The DER the certificate encodes to, not the PEM text that carries it. Two
	encodings of one certificate are one certificate, and the peer at the other
	end is hashing bytes it received on the wire rather than a file.

	## Native only

	mbedTLS is what hxcpp links for `sys.ssl`, and it has everything this needs
	compiled in already. Nothing equivalent exists on the other targets: Node
	has no DTLS in core at all, and a browser generates its certificates inside
	`RTCPeerConnection`, where they are deliberately out of reach -- a page that
	could read its own DTLS private key could impersonate itself elsewhere.

	`isSupported` says so rather than leaving a caller to find out from a
	failure.
**/
class DtlsCertificate {
	/** How long a generated certificate lasts, in days. **/
	public static inline var DEFAULT_LIFETIME_DAYS:Int = 30;

	private static inline var SECONDS_PER_DAY:Float = 86400;

	/**
		Whether certificates can be made here.

		False everywhere but native. A caller on another target has to be given
		a certificate rather than make one -- or, in a browser, let
		`RTCPeerConnection` deal with it.
	**/
	public static var isSupported(default, null):Bool = #if cpp true #else false #end;

	/** The certificate, PEM encoded. Public: it is sent to the peer. **/
	public var certificatePem(default, null):String;

	/**
		The private key, PEM encoded.

		Never sent anywhere. It is deliberately absent from `toString` for the
		same reason an ICE password is: a key that reaches a log has been
		published.
	**/
	public var privateKeyPem(default, null):String;

	/**
		The SHA-256 fingerprint, colon separated uppercase hex.

		This is the form SDP writes after `a=fingerprint:sha-256`, so it can be
		signalled as it stands.
	**/
	public var fingerprint(default, null):String;

	/**
		Adopts a certificate and key that already exist.

		For a deployment that would rather present a certificate it manages than
		one made on the spot -- and for tests, which need the same certificate
		twice.

		@throws ArgumentError if either half is missing, or if the certificate
		will not parse.
	**/
	public function new(certificatePem:String, privateKeyPem:String) {
		if (certificatePem == null || certificatePem.length == 0) {
			throw new ArgumentError("A certificate is required.");
		}

		if (privateKeyPem == null || privateKeyPem.length == 0) {
			throw new ArgumentError("A private key is required: a certificate nothing can sign with proves nothing.");
		}

		var digest = fingerprintOf(certificatePem);

		if (digest == null) {
			throw new ArgumentError("That certificate could not be read, so it has no fingerprint to publish.");
		}

		this.certificatePem = certificatePem;
		this.privateKeyPem = privateKeyPem;
		this.fingerprint = digest;
	}

	/**
		A fresh self-signed certificate on a P-256 key.

		P-256 rather than RSA because it is what every WebRTC implementation
		defaults to, and because the keys are orders of magnitude faster to
		generate -- which is what makes a certificate per session reasonable.

		@param commonName Appears in the subject and issuer. It is not checked
		by anything: the fingerprint is what identifies this peer, and a name in
		a self-signed certificate vouches for nothing.
		@param lifetimeDays How long it stays valid. Days rather than years
		because it is meant to outlive a session and not much more.
		@throws String on a target that cannot generate one. Check
		`isSupported`.
	**/
	public static function generate(commonName:String = "CrossByte", lifetimeDays:Int = DEFAULT_LIFETIME_DAYS):DtlsCertificate {
		#if cpp
		if (lifetimeDays <= 0) {
			throw new ArgumentError("A certificate that has already expired cannot be used.");
		}

		var now = Date.now().getTime() / 1000;

		// Backdated by a day. Two peers rarely agree on the time to the second,
		// and a certificate that is not valid yet is refused exactly as firmly
		// as one that has expired.
		var notBefore = __stamp(now - SECONDS_PER_DAY);
		var notAfter = __stamp(now + lifetimeDays * SECONDS_PER_DAY);

		var made = NativeDtls.generate(commonName, notBefore, notAfter);

		if (made == null || made.length < 2) {
			// The mbedtls code, because a failure here is not reproducible on
			// demand and "it did not work" is the least useful thing this could
			// say about one.
			throw "A certificate could not be generated: mbedTLS returned " + NativeDtls.lastError() + ".";
		}

		return new DtlsCertificate(made[0], made[1]);
		#else
		throw "Certificates can only be generated on native targets, where mbedTLS is linked. Check DtlsCertificate.isSupported, and on a browser let RTCPeerConnection make its own.";
		#end
	}

	/**
		The fingerprint of a certificate this peer did not make.

		Used to check what a peer signalled against what it then presented, so
		it takes PEM rather than a `DtlsCertificate` -- the far side's private
		key is not ours to have.
	**/
	public static function fingerprintOf(certificatePem:String):Null<String> {
		#if cpp
		return NativeDtls.fingerprint(certificatePem);
		#else
		return null;
		#end
	}

	/**
		Whether `certificatePem` is the certificate `expected` names.

		Compared without case sensitivity because the separator-and-case form is
		a display convention, and a peer that writes it in lowercase is naming
		the same certificate.
	**/
	public static function matches(certificatePem:String, expected:String):Bool {
		if (certificatePem == null || expected == null) {
			return false;
		}

		var actual = fingerprintOf(certificatePem);

		return actual != null && actual.toUpperCase() == expected.toUpperCase();
	}

	public function toString():String {
		// The key is deliberately absent.
		return "DtlsCertificate(" + fingerprint + ")";
	}

	@:noCompletion private static function __stamp(seconds:Float):String {
		var at = Date.fromTime(seconds * 1000);

		return __pad(at.getUTCFullYear(), 4)
			+ __pad(at.getUTCMonth() + 1, 2)
			+ __pad(at.getUTCDate(), 2)
			+ __pad(at.getUTCHours(), 2)
			+ __pad(at.getUTCMinutes(), 2)
			+ __pad(at.getUTCSeconds(), 2);
	}

	@:noCompletion private static function __pad(value:Int, width:Int):String {
		var text = Std.string(value);

		while (text.length < width) {
			text = "0" + text;
		}

		return text;
	}
}
