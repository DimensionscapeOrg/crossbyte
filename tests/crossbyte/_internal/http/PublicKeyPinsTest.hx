package crossbyte._internal.http;

import haxe.io.Bytes;
import utest.Assert;

/**
 * Reading a certificate's public key for a pin, which every target does the
 * same way from the certificate DER its TLS stack hands back.
 *
 * The expected pin was made by openssl from the certificate below: `x509
 * -pubkey -noout | pkey -pubin -outform der | dgst -sha256 -binary | base64`.
 */
class PublicKeyPinsTest extends utest.Test {
	// A self-signed P-256 certificate for pin.example, valid until 2126. Only
	// the public half: nothing here needs the key.
	static final PEM:Array<String> = [
		"MIIBhDCCASmgAwIBAgIUdLFAd8sHt9dBUeYrQssB/92gZZgwCgYIKoZIzj0EAwIw",
		"FjEUMBIGA1UEAwwLcGluLmV4YW1wbGUwIBcNMjYwOTMwMDcyMDQzWhgPMjEyNjA5",
		"MDYwNzIwNDNaMBYxFDASBgNVBAMMC3Bpbi5leGFtcGxlMFkwEwYHKoZIzj0CAQYI",
		"KoZIzj0DAQcDQgAEX/S7nJnfcH1LJB4oylpWfLnQ+gdN1sq82nbfeh1d+dPRzAQO",
		"ANzac/ll/jSvpiOdYg9jtXWde2zeA0Ql/wvmn6NTMFEwHQYDVR0OBBYEFF8B0hi/",
		"bB9mhGVfCd1lLQKuIdObMB8GA1UdIwQYMBaAFF8B0hi/bB9mhGVfCd1lLQKuIdOb",
		"MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAJssPPACkZ6As/tt",
		"bI5UvMzRka7oprKz9k2p92T67BVQAiEAry5OArj9UfRj3ponswhx9+/WkQDl41sx",
		"EF45AC7/DeA="
	];

	static inline final PIN:String = "sha256/DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw=";

	public function testTheKeyIsReadAsOpensslReadsIt():Void {
		var der:Bytes = haxe.crypto.Base64.decode(PEM.join(""));
		var spki:Null<Bytes> = PublicKeyPins.subjectPublicKeyInfo(der);
		crossbyte.test.Require.notNull(spki);
		// A P-256 SubjectPublicKeyInfo is 91 bytes: the algorithm sequence and
		// the 65-byte uncompressed point.
		Assert.equals(91, spki.length);
		Assert.equals(PIN, PublicKeyPins.pinOf(der));
	}

	public function testAPinIsComparedWithOrWithoutItsPrefix():Void {
		Assert.equals("DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw=", PublicKeyPins.normalize(PIN));
		Assert.equals("DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw=", PublicKeyPins.normalize(" SHA256/DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw= "));
		Assert.equals("DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw=", PublicKeyPins.normalize("DlROaqFREqJGy54IDzFBPo2BtnuArYPfuaN8gAyh5Uw="));
	}

	public function testWhatIsNotACertificateHasNoKey():Void {
		// Truncated anywhere, or lying about a length, the walk stops rather
		// than reading past the end: these bytes are the peer's.
		var der:Bytes = haxe.crypto.Base64.decode(PEM.join(""));
		for (cut in [0, 1, 2, 4, 10, 60, 150, 180]) {
			Assert.isNull(PublicKeyPins.subjectPublicKeyInfo(der.sub(0, cut)), "a certificate cut at " + cut + " bytes gave a key");
		}
		var lying:Bytes = Bytes.alloc(der.length);
		lying.blit(0, der, 0, der.length);
		lying.set(1, 0x84);
		Assert.isNull(PublicKeyPins.subjectPublicKeyInfo(lying));
		Assert.isNull(PublicKeyPins.subjectPublicKeyInfo(Bytes.ofString("not a certificate at all")));
		Assert.isNull(PublicKeyPins.subjectPublicKeyInfo(null));
		Assert.isNull(PublicKeyPins.pinOf(Bytes.alloc(0)));
	}
}
