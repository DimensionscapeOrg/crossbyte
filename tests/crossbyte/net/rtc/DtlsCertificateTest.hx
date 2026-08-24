package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	Certificates, and the fingerprints that stand in for a certificate
	authority.

	Native only, because mbedTLS is. The cases still run everywhere: on a target
	that cannot generate one they assert that it says so rather than failing
	somewhere further along, which is the same thing every other support flag
	here is held to.
**/
class DtlsCertificateTest extends utest.Test {
	private function unsupported():Bool {
		if (!DtlsCertificate.isSupported) {
			Assert.isFalse(DtlsCertificate.isSupported);
			return true;
		}

		return false;
	}

	/**
		The flag and the behaviour agree.

		The same case `LocalAddress` and `IceAgent` carry, and for the same
		reason: a support flag that lies is worse than no flag, because a caller
		checked it before taking the path it said was safe.
	**/
	public function testSupportIsReportedHonestly():Void {
		var made = true;

		try {
			DtlsCertificate.generate("crossbyte-test", 30);
		} catch (_:Dynamic) {
			made = false;
		}

		Assert.equals(DtlsCertificate.isSupported, made, "generating a certificate did not match what isSupported promised");
	}

	public function testAGeneratedCertificateCarriesBothHalves():Void {
		if (unsupported()) return;

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.isTrue(certificate.certificatePem.indexOf("-----BEGIN CERTIFICATE-----") == 0);
		Assert.isTrue(certificate.certificatePem.indexOf("-----END CERTIFICATE-----") > 0);
		Assert.isTrue(certificate.privateKeyPem.indexOf("PRIVATE KEY") > 0, "no private key came back with the certificate");
	}

	/**
		The shape SDP expects after `a=fingerprint:sha-256`.

		Thirty-two bytes as colon separated uppercase hex, which is what a peer
		reads off the wire and compares against. A fingerprint of any other
		shape is one no other implementation will match.
	**/
	public function testTheFingerprintIsTheShapeSdpExpects():Void {
		if (unsupported()) return;

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);
		var parts = certificate.fingerprint.split(":");

		Assert.equals(32, parts.length, "a SHA-256 fingerprint is thirty-two bytes");

		for (part in parts) {
			Assert.equals(2, part.length);
			Assert.isTrue(~/^[0-9A-F]{2}$/.match(part), "fingerprint byte " + part + " is not uppercase hex");
		}
	}

	/**
		The fingerprint follows from the certificate and nothing else.

		A peer receives the certificate in the handshake and hashes it itself,
		so a fingerprint that could not be recomputed from the PEM alone would
		be a number only this implementation agrees with.
	**/
	public function testTheFingerprintFollowsFromTheCertificateAlone():Void {
		if (unsupported()) return;

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.equals(certificate.fingerprint, DtlsCertificate.fingerprintOf(certificate.certificatePem));

		// And adopting the same PEM again arrives at the same answer, which is
		// what a peer that stored one and reloaded it depends on.
		var adopted = new DtlsCertificate(certificate.certificatePem, certificate.privateKeyPem);
		Assert.equals(certificate.fingerprint, adopted.fingerprint);
	}

	public function testEveryCertificateIsItsOwn():Void {
		if (unsupported()) return;

		var first = DtlsCertificate.generate("crossbyte-test", 30);
		var second = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.notEquals(first.fingerprint, second.fingerprint, "two certificates generated in a row were identical");
		Assert.notEquals(first.privateKeyPem, second.privateKeyPem);
	}

	/**
		What a peer actually does with a signalled fingerprint.

		Case is a display convention -- a peer writing it in lowercase is naming
		the same certificate -- but the certificate itself is not negotiable.
	**/
	public function testMatchingAcceptsTheRightCertificateAndNothingElse():Void {
		if (unsupported()) return;

		var mine = DtlsCertificate.generate("crossbyte-test", 30);
		var theirs = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.isTrue(DtlsCertificate.matches(mine.certificatePem, mine.fingerprint));
		Assert.isTrue(DtlsCertificate.matches(mine.certificatePem, mine.fingerprint.toLowerCase()),
			"a fingerprint written in lowercase named the same certificate and was refused");
		Assert.isFalse(DtlsCertificate.matches(theirs.certificatePem, mine.fingerprint),
			"another peer's certificate matched this one's fingerprint");
		Assert.isFalse(DtlsCertificate.matches(null, mine.fingerprint));
		Assert.isFalse(DtlsCertificate.matches(mine.certificatePem, null));
	}

	/**
		The private key stays out of anything that might be logged.

		`toString` is what gets interpolated into a log line by accident, and a
		key that reaches a log has been published.
	**/
	public function testTheKeyIsNotInTheStringForm():Void {
		if (unsupported()) return;

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);
		var printed = Std.string(certificate);

		Assert.isFalse(printed.indexOf("PRIVATE") >= 0, "the private key appeared in toString");
		Assert.isTrue(printed.indexOf(certificate.fingerprint) >= 0);
	}

	public function testAnUnusableCertificateIsRefused():Void {
		Assert.raises(() -> new DtlsCertificate(null, "key"), ArgumentError);
		Assert.raises(() -> new DtlsCertificate("cert", null), ArgumentError);
		Assert.raises(() -> new DtlsCertificate("", ""), ArgumentError);

		if (unsupported()) return;

		// Parseable-looking and not a certificate. Refused at construction, so
		// nothing ends up holding one with no fingerprint to publish.
		Assert.raises(() -> new DtlsCertificate("-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydA==\n-----END CERTIFICATE-----\n", "key"),
			ArgumentError);
	}

	/**
		Fast enough to make one per session, which is the point of P-256.

		Generous by two orders of magnitude against what this measures -- a few
		milliseconds -- so it fails only if something has gone badly wrong, such
		as a switch to RSA.
	**/
	public function testGeneratingOneIsCheapEnoughToDoPerSession():Void {
		if (unsupported()) return;

		var start = haxe.Timer.stamp();
		DtlsCertificate.generate("crossbyte-test", 30);
		var elapsed = haxe.Timer.stamp() - start;

		Assert.isTrue(elapsed < 2.0, "generating a certificate took " + elapsed + "s, which is too slow to do per connection");
	}
}
