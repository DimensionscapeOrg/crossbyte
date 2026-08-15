package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * Raw Curve25519 scalar multiplication (X25519, RFC 7748).
 *
 * This is a low-level building block. For a ready-made session-key handshake
 * prefer `KeyExchange`, which derives directional keys and never exposes the
 * raw shared point.
 *
 * Available on supported native `cpp` targets via the statically linked
 * libsodium backend.
 */
class X25519 {
	/**
	 * Length in bytes of a scalar (secret key).
	 */
	public static inline final SCALAR_BYTES:Int = 32;

	/**
	 * Length in bytes of a group element (public key).
	 */
	public static inline final POINT_BYTES:Int = 32;

	/**
	 * Returns `true` when the native X25519 backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Computes the public point for `scalar` against the curve base point.
	 */
	public static function scalarmultBase(scalar:Bytes):Bytes {
		if (scalar == null || scalar.length != SCALAR_BYTES) {
			throw "scalar must be " + SCALAR_BYTES + " bytes";
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		var point = Bytes.alloc(POINT_BYTES);
		var rc = NativeSodium.scalarmultBase(SodiumGlue.ptr(point), SodiumGlue.cptr(scalar));
		if (rc != 0) {
			throw "libsodium crypto_scalarmult_curve25519_base failed: " + rc;
		}
		return point;
		#else
		throw "X25519 is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Computes the shared point `scalar * peerPoint`.
	 *
	 * Throws when the peer point is a small-order element (libsodium rejects
	 * all-zero shared secrets); callers must treat that as a hostile peer,
	 * not a recoverable condition.
	 */
	public static function scalarmult(scalar:Bytes, peerPoint:Bytes):Bytes {
		if (scalar == null || scalar.length != SCALAR_BYTES) {
			throw "scalar must be " + SCALAR_BYTES + " bytes";
		}
		if (peerPoint == null || peerPoint.length != POINT_BYTES) {
			throw "peerPoint must be " + POINT_BYTES + " bytes";
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		var point = Bytes.alloc(POINT_BYTES);
		var rc = NativeSodium.scalarmult(SodiumGlue.ptr(point), SodiumGlue.cptr(scalar), SodiumGlue.cptr(peerPoint));
		if (rc != 0) {
			throw "libsodium crypto_scalarmult_curve25519 rejected the peer point (small-order element): " + rc;
		}
		return point;
		#else
		throw "X25519 is only available on supported native cpp targets.";
		#end
	}
}
