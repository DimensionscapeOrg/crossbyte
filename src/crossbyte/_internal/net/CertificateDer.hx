package crossbyte._internal.net;

import haxe.io.Bytes;

/**
	What `Certificate` reads out of an X.509 certificate's bytes itself, the
	same on every target: its DER from PEM text, PEM from its DER, and its
	subject's common name. A walk of the first elements of the DER, as
	`PublicKeyPins` walks to the key; the bytes may be a peer's, so every
	length is checked against what is there.
**/
@:noCompletion
class CertificateDer {
	/**
		The DER of the first certificate in `source`: PEM text, whose first
		`CERTIFICATE` block is decoded, or DER already. Null when it is
		neither.
	**/
	public static function firstOf(source:Bytes):Null<Bytes> {
		if (source == null || source.length == 0) {
			return null;
		}
		if (source.get(0) == 0x30) {
			return source;
		}
		var text:String = source.toString();
		var begin:String = "-----BEGIN CERTIFICATE-----";
		var start:Int = text.indexOf(begin);
		if (start < 0) {
			return null;
		}
		start += begin.length;
		var end:Int = text.indexOf("-----END CERTIFICATE-----", start);
		if (end < 0) {
			return null;
		}
		var body:String = ~/[^A-Za-z0-9+\/=]/g.replace(text.substring(start, end), "");
		try {
			return haxe.crypto.Base64.decode(body);
		} catch (_:Dynamic) {
			return null;
		}
	}

	/** `der` as PEM text, as a certificate file holds it. **/
	public static function pemOf(der:Bytes):String {
		var body:String = haxe.crypto.Base64.encode(der);
		var out:StringBuf = new StringBuf();
		out.add("-----BEGIN CERTIFICATE-----\n");
		var at:Int = 0;
		while (at < body.length) {
			out.add(body.substr(at, 64));
			out.add("\n");
			at += 64;
		}
		out.add("-----END CERTIFICATE-----\n");
		return out.toString();
	}

	/**
		The subject's common name (OID 2.5.4.3), the last if it has several,
		as RFC 6125 takes the most specific; null when it has none or `der`
		is not a certificate laid out as RFC 5280 has it.
	**/
	public static function commonNameOf(der:Bytes):Null<String> {
		if (der == null) {
			return null;
		}
		var certificate:Null<Element> = __element(der, 0, der.length);
		if (certificate == null || certificate.tag != 0x30) {
			return null;
		}
		var tbs:Null<Element> = __element(der, certificate.content, certificate.end);
		if (tbs == null || tbs.tag != 0x30) {
			return null;
		}
		var at:Int = tbs.content;
		var first:Null<Element> = __element(der, at, tbs.end);
		if (first == null) {
			return null;
		}
		if (first.tag == 0xA0) {
			at = first.end;
		}
		// serialNumber, signature, issuer, validity.
		for (_ in 0...4) {
			var skipped:Null<Element> = __element(der, at, tbs.end);
			if (skipped == null) {
				return null;
			}
			at = skipped.end;
		}
		var subject:Null<Element> = __element(der, at, tbs.end);
		if (subject == null || subject.tag != 0x30) {
			return null;
		}
		var found:Null<String> = null;
		var rdnAt:Int = subject.content;
		while (rdnAt < subject.end) {
			var rdn:Null<Element> = __element(der, rdnAt, subject.end);
			if (rdn == null || rdn.tag != 0x31) {
				return found;
			}
			var pairAt:Int = rdn.content;
			while (pairAt < rdn.end) {
				var pair:Null<Element> = __element(der, pairAt, rdn.end);
				if (pair == null || pair.tag != 0x30) {
					break;
				}
				var oid:Null<Element> = __element(der, pair.content, pair.end);
				if (oid != null && oid.tag == 0x06 && oid.end - oid.content == 3 && der.get(oid.content) == 0x55 && der.get(oid.content + 1) == 0x04
					&& der.get(oid.content + 2) == 0x03) {
					var value:Null<Element> = __element(der, oid.end, pair.end);
					if (value != null) {
						var text:Null<String> = __text(der, value);
						if (text != null) {
							found = text;
						}
					}
				}
				pairAt = pair.end;
			}
			rdnAt = rdn.end;
		}
		return found;
	}

	/** A directory string's text: UTF-8 and the ASCII kinds as they are, BMP as UTF-16BE. **/
	private static function __text(der:Bytes, value:Element):Null<String> {
		var length:Int = value.end - value.content;
		return switch (value.tag) {
			case 0x0C, 0x13, 0x16, 0x14:
				der.getString(value.content, length);
			case 0x1E:
				var out:StringBuf = new StringBuf();
				var i:Int = value.content;
				while (i + 1 < value.end) {
					out.addChar((der.get(i) << 8) | der.get(i + 1));
					i += 2;
				}
				out.toString();
			default:
				null;
		}
	}

	/** The element at `at`, ending by `limit`, or null when it runs past it. **/
	private static function __element(der:Bytes, at:Int, limit:Int):Null<Element> {
		if (at < 0 || at + 2 > limit) {
			return null;
		}
		var tag:Int = der.get(at);
		if ((tag & 0x1F) == 0x1F) {
			return null;
		}
		var first:Int = der.get(at + 1);
		var length:Int;
		var content:Int;
		if (first < 0x80) {
			length = first;
			content = at + 2;
		} else {
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

@:structInit
private final class Element {
	public final tag:Int;
	public final content:Int;
	public final end:Int;
}
