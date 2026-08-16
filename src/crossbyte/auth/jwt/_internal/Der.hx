package crossbyte.auth.jwt._internal;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * The sliver of DER needed to turn a JWK into a public key document.
 *
 * A JWK publishes a key as raw numbers — an RSA modulus and exponent, or
 * a pair of EC coordinates. mbedTLS, like every other library that parses
 * keys, wants a SubjectPublicKeyInfo. Nothing here is a general ASN.1
 * encoder; it emits exactly the structures `SubjectPublicKeyInfo`
 * requires and nothing else.
 */
class Der {
	/** OID 1.2.840.113549.1.1.1 — rsaEncryption. */
	public static final OID_RSA_ENCRYPTION:Array<Int> = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01];

	/** OID 1.2.840.10045.2.1 — id-ecPublicKey. */
	public static final OID_EC_PUBLIC_KEY:Array<Int> = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];

	/** OID 1.2.840.10045.3.1.7 — prime256v1, the curve `ES256` uses. */
	public static final OID_PRIME256V1:Array<Int> = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07];

	private static inline var TAG_INTEGER:Int = 0x02;
	private static inline var TAG_BIT_STRING:Int = 0x03;
	private static inline var TAG_NULL:Int = 0x05;
	private static inline var TAG_OID:Int = 0x06;
	private static inline var TAG_SEQUENCE:Int = 0x30;

	/**
	 * Wraps `content` in a tag and a definite length.
	 */
	public static function tagged(tag:Int, content:Bytes):Bytes {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(tag);
		__writeLength(out, content.length);
		out.addBytes(content, 0, content.length);
		return out.getBytes();
	}

	public static function sequence(parts:Array<Bytes>):Bytes {
		var body:BytesBuffer = new BytesBuffer();
		for (part in parts) {
			body.addBytes(part, 0, part.length);
		}
		return tagged(TAG_SEQUENCE, body.getBytes());
	}

	public static function oid(encoded:Array<Int>):Bytes {
		var body:BytesBuffer = new BytesBuffer();
		for (b in encoded) {
			body.addByte(b);
		}
		return tagged(TAG_OID, body.getBytes());
	}

	public static function nullValue():Bytes {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(TAG_NULL);
		out.addByte(0x00);
		return out.getBytes();
	}

	/**
	 * Encodes an unsigned big-endian magnitude as a DER INTEGER.
	 *
	 * DER integers are signed, so a magnitude whose top bit is set needs a
	 * leading zero byte or it reads as negative — which is why an RSA
	 * modulus almost always gains one. Leading zeros are otherwise
	 * stripped, since DER requires the shortest form.
	 */
	public static function unsignedInteger(magnitude:Bytes):Bytes {
		var start:Int = 0;
		while (start < magnitude.length - 1 && magnitude.get(start) == 0) {
			start++;
		}

		var body:BytesBuffer = new BytesBuffer();
		if (magnitude.length == 0) {
			body.addByte(0x00);
		} else {
			if ((magnitude.get(start) & 0x80) != 0) {
				body.addByte(0x00);
			}
			body.addBytes(magnitude, start, magnitude.length - start);
		}

		return tagged(TAG_INTEGER, body.getBytes());
	}

	/**
	 * Wraps `content` as a BIT STRING with no unused trailing bits, which
	 * is the only form a key document uses.
	 */
	public static function bitString(content:Bytes):Bytes {
		var body:BytesBuffer = new BytesBuffer();
		body.addByte(0x00);
		body.addBytes(content, 0, content.length);
		return tagged(TAG_BIT_STRING, body.getBytes());
	}

	/**
	 * Renders DER as a PEM document.
	 *
	 * @param label The BEGIN/END label, for example `PUBLIC KEY`.
	 */
	public static function toPem(der:Bytes, label:String):String {
		var body:String = haxe.crypto.Base64.encode(der);
		var out:StringBuf = new StringBuf();
		out.add('-----BEGIN $label-----\n');

		var offset:Int = 0;
		while (offset < body.length) {
			var take:Int = body.length - offset;
			if (take > 64) {
				take = 64;
			}
			out.add(body.substr(offset, take));
			out.add("\n");
			offset += take;
		}

		out.add('-----END $label-----\n');
		return out.toString();
	}

	/**
	 * Definite-length encoding: short form below 128, otherwise a leading
	 * count of the length bytes that follow.
	 */
	private static function __writeLength(out:BytesBuffer, length:Int):Void {
		if (length < 0x80) {
			out.addByte(length);
			return;
		}

		var sizeBytes:Array<Int> = [];
		var remaining:Int = length;
		while (remaining > 0) {
			sizeBytes.unshift(remaining & 0xFF);
			remaining >>>= 8;
		}

		out.addByte(0x80 | sizeBytes.length);
		for (b in sizeBytes) {
			out.addByte(b);
		}
	}
}
