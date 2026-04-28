package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import cpp.ConstPointer;
import cpp.Pointer;
import cpp.RawPointer;
import cpp.UInt8;
import crossbyte.crypto._internal.NativeBlake3;
#end

/**
 * Native BLAKE3 hashing helpers.
 *
 * This surface is intentionally small and aimed at artifact identity,
 * replication checks, chunk verification, and other content-addressed
 * workflows where a fast cryptographic digest is useful.
 */
class Blake3 {
	/**
	 * The recommended default output length in bytes for most callers.
	 */
	public static inline final DEFAULT_OUTPUT_BYTES:Int = 32;

	#if cpp
	@:noCompletion
	private static final __emptyBytes:Bytes = Bytes.alloc(1);
	#end

	/**
	 * Returns `true` when the native BLAKE3 backend is available on this target.
	 */
	public static inline function isAvailable():Bool {
		#if cpp
		return true;
		#else
		return false;
		#end
	}

	/**
	 * Returns the SIMD width currently selected by the native BLAKE3 backend.
	 *
	 * Typical values are:
	 * - `1` for the portable fallback
	 * - `4` for SSE2 or SSE4.1
	 * - `8` for AVX2
	 * - `16` for AVX-512
	 */
	public static inline function simdDegree():Int {
		#if cpp
		return NativeBlake3.simdDegree();
		#else
		return 0;
		#end
	}

	/**
	 * Hashes a byte buffer with BLAKE3.
	 *
	 * @param input The byte buffer to hash.
	 * @param outputLength The requested digest length in bytes. Defaults to 32.
	 * @return The BLAKE3 digest bytes.
	 */
	public static function hash(input:Bytes, outputLength:Int = DEFAULT_OUTPUT_BYTES):Bytes {
		if (outputLength < 0) {
			throw "outputLength must be >= 0";
		}

		var output = Bytes.alloc(outputLength);
		if (outputLength == 0) {
			return output;
		}

		#if cpp
		var rc = NativeBlake3.hash(__cptrOrNull(input), __length(input), __ptr(output), outputLength);
		if (rc != 0) {
			throw "BLAKE3 hashing failed: " + rc;
		}
		return output;
		#else
		throw "BLAKE3 hashing is only available on native cpp targets.";
		#end
	}

	/**
	 * Hashes a UTF-8 string with BLAKE3.
	 *
	 * @param value The string to hash.
	 * @param outputLength The requested digest length in bytes. Defaults to 32.
	 * @return The BLAKE3 digest bytes.
	 */
	public static inline function hashString(value:String, outputLength:Int = DEFAULT_OUTPUT_BYTES):Bytes {
		return hash(Bytes.ofString(value == null ? "" : value), outputLength);
	}

	/**
	 * Hashes a byte buffer with BLAKE3 and returns the digest as lowercase hex.
	 *
	 * @param input The byte buffer to hash.
	 * @param outputLength The requested digest length in bytes. Defaults to 32.
	 * @return The lowercase hexadecimal digest string.
	 */
	public static inline function hashHex(input:Bytes, outputLength:Int = DEFAULT_OUTPUT_BYTES):String {
		return hash(input, outputLength).toHex();
	}

	/**
	 * Hashes a UTF-8 string with BLAKE3 and returns the digest as lowercase hex.
	 *
	 * @param value The string to hash.
	 * @param outputLength The requested digest length in bytes. Defaults to 32.
	 * @return The lowercase hexadecimal digest string.
	 */
	public static inline function hashStringHex(value:String, outputLength:Int = DEFAULT_OUTPUT_BYTES):String {
		return hashString(value, outputLength).toHex();
	}

	#if cpp
	@:noCompletion
	private static inline function __ptr(bytes:Bytes):RawPointer<UInt8> {
		return cast Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion
	private static inline function __cptrOrNull(bytes:Bytes):ConstPointer<UInt8> {
		return (bytes == null || bytes.length == 0) ? Pointer.arrayElem(__emptyBytes.getData(), 0) : Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion
	private static inline function __length(bytes:Bytes):Int {
		return bytes == null ? 0 : bytes.length;
	}
	#end
}
