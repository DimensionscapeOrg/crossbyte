package crossbyte._internal.http;

import haxe.io.Bytes;

/**
	Public-key pins as RFC 7469 writes them: the SHA-256 of a certificate's
	SubjectPublicKeyInfo, in base64. What `URLRequest.pinnedPublicKeys` lists,
	with or without a `sha256/` in front.

	A pin names the key, not the certificate, so it survives the certificate
	being renewed over the same key, the reason HPKP and every pinning
	library since pin keys. Reading the key's bytes out of a certificate is a
	walk of the first few elements of its DER, done here so every target reads
	them the same way from the certificate its TLS stack hands back.
**/
@:noCompletion
class PublicKeyPins {
	/** The `sha256/` pin of the certificate whose DER is `der`, or null when it cannot be read. */
	public static function pinOf(der:Bytes):Null<String> {
		var spki:Null<Bytes> = subjectPublicKeyInfo(der);
		return spki == null ? null : "sha256/" + haxe.crypto.Base64.encode(haxe.crypto.Sha256.make(spki));
	}

	/** A pin as compared: its base64 alone, trimmed, without a `sha256/` prefix. */
	public static function normalize(pin:String):String {
		var text:String = StringTools.trim(pin);
		return StringTools.startsWith(text.toLowerCase(), "sha256/") ? StringTools.trim(text.substr(7)) : text;
	}

	/**
		The DER of the SubjectPublicKeyInfo inside the certificate `der`, or
		null when `der` is not an X.509 certificate laid out as RFC 5280 has
		it: a sequence holding a TBSCertificate, whose seventh element,
		sixth without the optional version, is the key.
	**/
	public static function subjectPublicKeyInfo(der:Bytes):Null<Bytes> {
		if (der == null) {
			return null;
		}
		var certificate:Null<DerElement> = __element(der, 0, der.length);
		if (certificate == null || certificate.tag != 0x30) {
			return null;
		}
		var tbs:Null<DerElement> = __element(der, certificate.content, certificate.end);
		if (tbs == null || tbs.tag != 0x30) {
			return null;
		}

		var at:Int = tbs.content;
		var first:Null<DerElement> = __element(der, at, tbs.end);
		if (first == null) {
			return null;
		}
		if (first.tag == 0xA0) {
			// [0] EXPLICIT version, present in every v3 certificate.
			at = first.end;
		}
		// serialNumber, signature, issuer, validity, subject.
		for (_ in 0...5) {
			var skipped:Null<DerElement> = __element(der, at, tbs.end);
			if (skipped == null) {
				return null;
			}
			at = skipped.end;
		}

		var key:Null<DerElement> = __element(der, at, tbs.end);
		if (key == null || key.tag != 0x30) {
			return null;
		}
		return der.sub(at, key.end - at);
	}

	/**
		The element starting at `at` and ending by `limit`, or null when its
		header or its length runs past `limit`, the bytes are the peer's.
	**/
	private static function __element(der:Bytes, at:Int, limit:Int):Null<DerElement> {
		if (at < 0 || at + 2 > limit) {
			return null;
		}
		var tag:Int = der.get(at);
		if ((tag & 0x1F) == 0x1F) {
			// A multi-byte tag, which nothing in a certificate's outline uses.
			return null;
		}

		var first:Int = der.get(at + 1);
		var length:Int;
		var content:Int;
		if (first < 0x80) {
			length = first;
			content = at + 2;
		} else {
			// Long form. Indefinite (0x80) is not DER, and more than three
			// bytes of length is more than any certificate has.
			var count:Int = first & 0x7F;
			if (count == 0 || count > 3 || at + 2 + count > limit) {
				return null;
			}
			length = 0;
			for (i in 0...count) {
				length = (length << 8) | der.get(at + 2 + i);
			}
			content = at + 2 + count;
		}

		var end:Int = content + length;
		if (end > limit) {
			return null;
		}
		return {tag: tag, content: content, end: end};
	}
}

private typedef DerElement = {
	var tag:Int;
	var content:Int;
	var end:Int;
}
