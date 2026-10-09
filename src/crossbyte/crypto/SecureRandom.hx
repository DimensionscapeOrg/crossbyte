package crossbyte.crypto;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#if php
import php.Global;
import php.Syntax;
#end
#if nodejs
import js.node.Crypto;
#end
#if !(cpp || php || java || jvm || js)
import crossbyte.crypto._internal.NativeOnly;
import crossbyte.errors.IllegalOperationError;
#end

#if cpp
@:cppFileCode('
#ifdef HX_WINDOWS
#include <Windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#else
#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#endif
#include <string.h>

namespace {
	// Each thread keeps the random bytes it has drawn from the system and not
	// yet handed out, and asks for more 4 KB at a time. One system call per
	// draw cost more than everything else a small draw does: a 4-byte draw,
	// a WebSocket client frame mask, took about 170 ns through BCryptGenRandom
	// on Windows, and a mutex and a read of /dev/urandom elsewhere.
	const int kRandomPoolSize = 4096;

	// A draw this large goes straight to the system: through the pool it would
	// only be copied once more.
	const int kRandomDirect = 1024;

	thread_local unsigned char tRandomPool[kRandomPoolSize];
	thread_local int tRandomLeft = 0;

#ifdef HX_WINDOWS
	bool randomFromSystem(unsigned char *out, int length) {
		return ::BCryptGenRandom(NULL, (PUCHAR)out, (ULONG)length, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
	}

	const char *randomFailure() {
		return "BCryptGenRandom failed";
	}
#else
	// Opened once for the process and shared: concurrent reads of one
	// descriptor are safe, and /dev/urandom has no position to keep.
	std::atomic<int> gUrandom(-1);

	int urandom() {
		int fd = gUrandom.load(std::memory_order_acquire);
		if (fd >= 0) {
			return fd;
		}
		int opened = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
		if (opened < 0) {
			return -1;
		}
		int expected = -1;
		if (!gUrandom.compare_exchange_strong(expected, opened)) {
			// Another thread opened it first.
			::close(opened);
			return expected;
		}
		return opened;
	}

	bool randomFromSystem(unsigned char *out, int length) {
		int fd = urandom();
		if (fd < 0) {
			return false;
		}
		int filled = 0;
		while (filled < length) {
			ssize_t n = ::read(fd, out + filled, (size_t)(length - filled));
			if (n < 0 && errno == EINTR) {
				continue;
			}
			if (n <= 0) {
				return false;
			}
			filled += (int)n;
		}
		return true;
	}

	const char *randomFailure() {
		return "Failed to read from /dev/urandom";
	}

	// A forked child starts with a copy of its parent: the bytes this thread
	// had not handed out would be handed out by both. The child drops them.
	void randomForked() {
		memset(tRandomPool, 0, sizeof(tRandomPool));
		tRandomLeft = 0;
	}
#endif

	// Fills out with length secure random bytes; false when the system
	// refused. Each range handed out is zeroed in the pool behind it, so what
	// became a key is not left lying in memory a second time.
	bool secureRandom(unsigned char *out, int length) {
		if (length >= kRandomDirect) {
			return randomFromSystem(out, length);
		}
#ifndef HX_WINDOWS
		static int atfork = pthread_atfork(NULL, NULL, randomForked);
		(void)atfork;
#endif
		int left = tRandomLeft;
		while (length > 0) {
			if (left == 0) {
				if (!randomFromSystem(tRandomPool, kRandomPoolSize)) {
					tRandomLeft = 0;
					return false;
				}
				left = kRandomPoolSize;
			}
			int take = length < left ? length : left;
			unsigned char *from = tRandomPool + (kRandomPoolSize - left);
			memcpy(out, from, (size_t)take);
			memset(from, 0, (size_t)take);
			out += take;
			length -= take;
			left -= take;
		}
		tRandomLeft = left;
		return true;
	}
}
')
#end
/**
 * Provides cryptographically secure random bytes using the strongest native
 * source available on the current target.
 */
final class SecureRandom {
	/**
	 * Whether this target has a CSPRNG to draw from.
	 *
	 * `getSecureRandomBytes` throws where it does not, on purpose; this lets a
	 * caller that would rather take a different path ask first, and anything
	 * built on this pass the question on. The condition is the same one the
	 * branches below use, kept beside them so the two cannot drift.
	 *
	 * True natively (cpp), on the jvm, on Node, in a browser and on PHP. False on
	 * the interpreter, on neko and on HashLink, which have no such source here,
	 * and so everything that needs one refuses there, saying so: `BCrypt.hash`,
	 * PKCE, WebSocket clients, STUN, TURN, ICE and WebRTC.
	 */
	public static var isSupported(default, null):Bool = #if (cpp || php || java || jvm || nodejs || js) true #else false #end;

	/**
	 * Returns `length` bytes from the platform CSPRNG.
	 *
	 * @throws IllegalOperationError On a target without one (the
	 *         interpreter, neko, HashLink), naming it, rather than falling
	 *         back to a generator that only looks random.
	 */
	public static function getSecureRandomBytes(length:Int):ByteArray {
		#if cpp
		if (length <= 0) {
			return Bytes.alloc((length < 0) ? 0 : length);
		}
		return __getSecureRandomBytesNative(length);
		#elseif php
		return __getSecureRandomBytesPHP(length);
		#elseif (java || jvm)
		return __getSecureRandomBytesJava(length);
		#elseif nodejs
		return __getSecureRandomBytesNode(length);
		#elseif js
		return __getSecureRandomBytesBrowser(length);
		#else
		throw new IllegalOperationError("Secure random bytes are not available on " + NativeOnly.TARGET
			+ ", and this will not fall back to a generator that only looks random.");
		#end
	}

	/**
	 * Fills `length` bytes of `bytes` from `offset` with bytes from the
	 * platform CSPRNG, the same source as `getSecureRandomBytes`, without
	 * making a buffer for them: for a caller that draws often into storage of
	 * its own, such as a WebSocket client's pool of frame masks. `length` -1
	 * (the default) fills from `offset` to the end. `bytes` keeps its length
	 * and position.
	 *
	 * Natively and on Node nothing is allocated. On the jvm a fill of a
	 * whole `ByteArray` whose storage is exactly its length (as
	 * `ByteArray.fromBytes(Bytes.alloc(n))` makes) allocates nothing; any
	 * other range is drawn into an array of its own first, since Java's
	 * `SecureRandom` fills whole arrays only.
	 *
	 * ```haxe
	 * var masks = ByteArray.fromBytes(haxe.io.Bytes.alloc(8192));
	 * SecureRandom.fill(masks);           // all of it
	 * SecureRandom.fill(masks, 4096, 64); // 64 bytes from 4096
	 * ```
	 *
	 * @throws RangeError If `offset` or `length` reach outside `bytes`.
	 * @throws ArgumentError If `bytes` is null.
	 * @throws IllegalOperationError On a target without a CSPRNG (the
	 *         interpreter, neko, HashLink), as `getSecureRandomBytes` does.
	 */
	public static function fill(bytes:ByteArray, offset:Int = 0, length:Int = -1):Void {
		if (bytes == null) {
			throw new crossbyte.errors.ArgumentError("SecureRandom.fill: bytes is null");
		}
		var size:Int = bytes.length;
		if (length == -1) {
			length = size - offset;
		}
		if (offset < 0 || length < 0 || offset > size || length > size - offset) {
			throw new crossbyte.errors.RangeError('SecureRandom.fill: $length bytes from $offset reach outside the $size there are');
		}
		if (length == 0) {
			return;
		}
		#if cpp
		var data:Bytes = bytes;
		var ok:Bool = untyped __cpp__('secureRandom((unsigned char *)&{0}->b[{1}], {2})', data, offset, length);
		if (!ok) {
			var failure:String = untyped __cpp__('::String(randomFailure())');
			throw failure;
		}
		#elseif (java || jvm)
		if (__jrng == null) {
			__jrng = new JavaSecureRandom();
		}
		var data:haxe.io.BytesData = (bytes : Bytes).getData();
		if (offset == 0 && length == data.length) {
			__jrng.nextBytes(data);
		} else {
			var drawn:haxe.io.BytesData = new java.NativeArray(length);
			__jrng.nextBytes(drawn);
			java.lang.System.arraycopy(drawn, 0, data, offset, length);
		}
		#elseif nodejs
		// A view of the bytes' own view, wherever that sits in its buffer.
		var view:js.lib.Uint8Array = @:privateAccess (bytes : Bytes).b.subarray(offset, offset + length);
		js.Syntax.code("{0}.randomFillSync({1})", Crypto, view);
		#else
		(bytes : Bytes).blit(offset, getSecureRandomBytes(length), 0, length);
		#end
	}

	#if nodejs
	/**
	 * Node's `crypto.randomBytes`, which is the platform CSPRNG (OpenSSL's,
	 * seeded from the operating system), not `Math.random`.
	 */
	@:noCompletion private static function __getSecureRandomBytesNode(length:Int):ByteArray {
		if (length <= 0) {
			return Bytes.alloc(0);
		}

		var buffer = Crypto.randomBytes(length);
		// Sliced by its own region: a Node Buffer can be a window onto a
		// larger pooled allocation, and taking .buffer whole would carry bytes
		// belonging to something else.
		return Bytes.ofData(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength));
	}
	#end

	#if (js && !nodejs)
	// getRandomValues refuses more than this in one call, by specification.
	@:noCompletion private static inline var WEB_CRYPTO_QUOTA:Int = 65536;

	/**
	 * Web Crypto's `getRandomValues`, which browsers are required to back with
	 * a cryptographically secure generator.
	 *
	 * A page has it whether or not it is a secure context: only `crypto.subtle`
	 * and `randomUUID` need one. A browser too old to have it throws here
	 * rather than falling back to `Math.random`, which would hand back
	 * something that passes every test a caller could write and is predictable
	 * to anyone who wants it.
	 */
	@:noCompletion private static function __getSecureRandomBytesBrowser(length:Int):ByteArray {
		if (length <= 0) {
			return Bytes.alloc(0);
		}

		var webCrypto:js.html.Crypto = js.Browser.window.crypto;

		if (webCrypto == null) {
			throw "Secure random bytes need the Web Crypto API's crypto.getRandomValues, which this browser does not have.";
		}

		var out = new js.lib.Uint8Array(length);
		var offset:Int = 0;

		// Filled a quota at a time, because one call for more than 65536 bytes
		// is a QuotaExceededError rather than a short read, so a caller asking
		// for a large key would get an exception, not fewer bytes.
		while (offset < length) {
			var span:Int = length - offset;

			if (span > WEB_CRYPTO_QUOTA) {
				span = WEB_CRYPTO_QUOTA;
			}

			webCrypto.getRandomValues(new js.lib.Uint8Array(out.buffer, offset, span));
			offset += span;
		}

		return Bytes.ofData(out.buffer);
	}
	#end

	#if cpp
	/**
		BCryptGenRandom on Windows, /dev/urandom elsewhere, through the calling
		thread's pool (the native code above). Which system source is chosen
		by the preprocessor, not at run time: bcrypt.h exists only on Windows,
		and a call into it compiled on Linux would stop the build.
	**/
	private static function __getSecureRandomBytesNative(length:Int):Bytes {
		var out:Bytes = Bytes.alloc(length);
		var ok:Bool = untyped __cpp__('secureRandom((unsigned char *)&{0}->b[0], {1})', out, length);
		if (!ok) {
			var failure:String = untyped __cpp__('::String(randomFailure())');
			throw failure;
		}
		return out;
	}
	#end
	#if php
	private static function __getSecureRandomBytesPHP(length:Int):ByteArray {
		if (length < 0) {
			throw "length must be >= 0";
		}
		if (length == 0) {
			return Bytes.alloc(0);
		}

		try {
			var raw:String = Global.random_bytes(length);
			return Bytes.ofData(raw);
		} catch (e:Dynamic) {
			throw "Error generating random bytes: " + e;
		}
	}
	#end

	#if (java || jvm)
	@:noCompletion static var __jrng:JavaSecureRandom = null;

	private static function __getSecureRandomBytesJava(length:Int):ByteArray {
		if (length <= 0) {
			return Bytes.alloc(length < 0 ? 0 : length);
		}
		if (__jrng == null) {
			__jrng = new JavaSecureRandom();
		}
		var out:Bytes = Bytes.alloc(length);
		__jrng.nextBytes(out.getData());
		return out;
	}
	#end
}

#if (java || jvm)
@:native("java.security.SecureRandom")
private extern class JavaSecureRandom {
	function new():Void;
	function nextBytes(bytes:haxe.io.BytesData):Void;
}
#end
