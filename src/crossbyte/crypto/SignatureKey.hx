package crossbyte.crypto;

import crossbyte.crypto.PublicKeySignature.PublicKeyType;
import crossbyte.crypto.PublicKeySignature.SignatureFormat;
import crossbyte.errors.ArgumentError;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
#if cpp
import cpp.Pointer;
import crossbyte.crypto._internal.NativePk;
import crossbyte.crypto._internal.SodiumGlue;
#else
import crossbyte.crypto._internal.NativeOnly;
#end

/**
 * An RSA or EC key parsed once and held by mbedTLS, for signing or verifying
 * many messages with it.
 *
 * `PublicKeySignature.sign` and `verify` take PEM text and parse it on every
 * call, which is right for a key used once. A key used for every token a
 * service issues or checks belongs here: parsing it each time left another
 * copy of a private key in freed memory per signature, and rebuilt an EC key's
 * precomputed tables per operation.
 *
 * ```haxe
 * var key = SignatureKey.fromPrivatePem(pem);
 * var signature = key.sign(message, JOSE);
 * ```
 *
 * The parsed key lives in native memory. It is wiped and freed when this
 * object is collected, or at once by `dispose`, which is worth calling when
 * a key is retired. The PEM text passed in is a `String` and cannot be wiped;
 * holding this instead of the text is what lets the text go.
 *
 * Signing and verifying run outside the collector's reach, so a slow RSA
 * signature on one thread does not hold up collections on the others. One
 * key's operations take turns, since mbedTLS keeps state inside the key; give
 * threads that sign heavily a key each.
 *
 * Available on native `cpp` targets; elsewhere `fromPrivatePem` and
 * `fromPublicPem` throw an `IllegalOperationError` naming the target, so no
 * key exists there to call the rest on.
 */
class SignatureKey {
	/** The kind of key: `RSA` or `EC`, or `UNKNOWN` once disposed of. */
	public var type(default, null):PublicKeyType;

	/** Whether this is a private key, which can sign as well as verify. */
	public var isPrivate(default, null):Bool;

	@:noCompletion private var __handle:Dynamic;

	@:noCompletion private function new(handle:Dynamic, isPrivate:Bool, type:PublicKeyType) {
		__handle = handle;
		this.isPrivate = isPrivate;
		this.type = type;
	}

	/**
	 * Parses a PEM private key: PKCS#8, or PKCS#1 RSA, or SEC1 EC; unencrypted.
	 *
	 * @throws ArgumentError When `pem` is empty.
	 * @throws String When mbedTLS cannot read it, with mbedTLS's reason.
	 * @throws IllegalOperationError On a target other than native cpp.
	 */
	public static function fromPrivatePem(pem:String):SignatureKey {
		return __load(pem, true, true);
	}

	/**
	 * Parses a PEM public key (`SubjectPublicKeyInfo`, as `JWK.toPem` produces).
	 *
	 * @throws ArgumentError When `pem` is empty.
	 * @throws String When mbedTLS cannot read it.
	 * @throws IllegalOperationError On a target other than native cpp.
	 */
	public static function fromPublicPem(pem:String):SignatureKey {
		return __load(pem, false, true);
	}

	/**
	 * Signs `message` with SHA-256.
	 *
	 * @param format Encoding to produce. Use `JOSE` for `ES256` JWTs.
	 * @throws ArgumentError When `message` is null or this is a public key.
	 * @throws String When the key has been disposed of, or mbedTLS fails.
	 */
	public function sign(message:Bytes, format:SignatureFormat = NATIVE):Bytes {
		if (message == null) {
			throw new ArgumentError("A message is required to sign.");
		}
		if (!isPrivate) {
			throw new ArgumentError("A public key cannot sign.");
		}

		#if cpp
		var hash:Bytes = Sha256.make(message);
		// Comfortably above the largest signature mbedTLS will emit for the key
		// sizes this API handles.
		var scratch:Bytes = Bytes.alloc(1024);
		var produced:Array<Int> = [0];

		var rc:Int = NativePk.signSha256(__handle, SodiumGlue.cptr(hash), SodiumGlue.ptr(scratch), scratch.length, Pointer.arrayElem(produced, 0).raw,
			format);
		if (rc != 0) {
			throw 'Signing failed: ' + NativePk.errorMessage(rc) + ' (code $rc)';
		}
		if (produced[0] <= 0) {
			throw "mbedTLS signing produced an empty signature.";
		}
		return scratch.sub(0, produced[0]);
		#else
		throw NativeOnly.error("Public-key signing");
		#end
	}

	/**
	 * Verifies a SHA-256 signature over `message`.
	 *
	 * @param format Encoding of `signature`. Use `JOSE` for `ES256` JWTs.
	 * @return `true` only when the signature is valid. A malformed signature or
	 *         a disposed key is `false`, never a throw, so a hostile token
	 *         cannot raise out of a verification path.
	 */
	public function verify(message:Bytes, signature:Bytes, format:SignatureFormat = NATIVE):Bool {
		if (message == null || signature == null || signature.length == 0) {
			return false;
		}

		#if cpp
		var hash:Bytes = Sha256.make(message);
		return NativePk.verifySha256(__handle, SodiumGlue.cptr(hash), SodiumGlue.cptr(signature), signature.length, format) == 0;
		#else
		return false;
		#end
	}

	/**
	 * Length in bytes of a JOSE-format ECDSA signature for this key: twice the
	 * curve's coordinate size, so 64 for P-256.
	 *
	 * @return The length, or `-1` when this is not a live EC key.
	 */
	public function joseSignatureLength():Int {
		#if cpp
		var coordinate:Int = NativePk.coordinateSize(__handle);
		return coordinate < 0 ? -1 : coordinate * 2;
		#else
		return -1;
		#end
	}

	/**
	 * Wipes and frees the parsed key now, rather than when this is collected.
	 * Signing afterwards throws and verifying is `false`.
	 */
	public function dispose():Void {
		#if cpp
		NativePk.dispose(__handle);
		#end
		type = UNKNOWN;
	}

	/**
	 * Parses `pem`, or returns null when it cannot be read and `throws` is false.
	 */
	@:noCompletion private static function __load(pem:String, isPrivate:Bool, throws:Bool):Null<SignatureKey> {
		#if cpp
		if (pem == null || pem == "") {
			if (throws) {
				throw new ArgumentError("A PEM key is required.");
			}
			return null;
		}

		if (!NativePk.isAvailable()) {
			if (throws) {
				throw PublicKeySignature.UNAVAILABLE;
			}
			return null;
		}

		var text:Bytes = Bytes.ofString(pem);
		var error:Array<Int> = [0];
		var handle:Dynamic = NativePk.load(SodiumGlue.cptr(text), text.length, isPrivate, Pointer.arrayElem(error, 0).raw);
		// A copy of the key like any other, and nothing else wipes it.
		text.fill(0, text.length, 0);

		if (handle == null) {
			if (throws) {
				throw 'Not a PEM ' + (isPrivate ? "private" : "public") + ' key mbedTLS can read: ' + NativePk.errorMessage(error[0]);
			}
			return null;
		}
		return new SignatureKey(handle, isPrivate, NativePk.keyType(handle));
		#else
		throw NativeOnly.error("Public-key signing");
		#end
	}
}
