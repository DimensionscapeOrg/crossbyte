package crossbyte.crypto;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#if cpp
import sys.io.File;
import sys.thread.Mutex;
#end
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
#endif
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
	 * `getSecureRandomBytes` throws where it does not, on purpose -- but a
	 * caller that would rather take a different path than catch an exception
	 * has no way to ask, and anything built on this inherits the same problem.
	 * The condition is the same one the branches below use, kept beside them so
	 * the two cannot drift.
	 *
	 * True natively (cpp), on the jvm, on Node, in a browser and on PHP. False on
	 * the interpreter, on neko and on HashLink, which have no such source here --
	 * and so everything that needs one refuses there, saying so: `BCrypt.hash`,
	 * PKCE, WebSocket clients, STUN, TURN, ICE and WebRTC.
	 */
	public static var isSupported(default, null):Bool = #if (cpp || php || java || jvm || nodejs || js) true #else false #end;

	/**
	 * Returns `length` bytes from the platform CSPRNG.
	 *
	 * @throws IllegalOperationError On a target without one -- the
	 *         interpreter, neko, HashLink -- naming it, rather than falling
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

	#if nodejs
	/**
	 * Node's `crypto.randomBytes`, which is the platform CSPRNG -- OpenSSL's,
	 * seeded from the operating system -- and not `Math.random`.
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
		// is a QuotaExceededError rather than a short read -- so a caller
		// asking for a large key would get an exception, not fewer bytes.
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
	@:noCompletion static var __urandom:sys.io.FileInput = null;
	// Made up front rather than on first use: two threads drawing their first
	// bytes at once each made one and locked their own, and then shared the
	// file between them unguarded. Password hashing runs on worker threads, so
	// two first draws at once is an ordinary start-up.
	@:noCompletion static final __lock:Mutex = new Mutex();

	private static inline function __getSecureRandomBytesNative(length:Int):Bytes {
		return __isWindows() ? __getSecureRandomBytesWindows(length) : __getSecureRandomBytesUnix(length);
	}

	private static inline function __isWindows():Bool {
		return Sys.systemName() == "Windows";
	}

	private static inline function __getSecureRandomBytesWindows(length:Int):Bytes {
		var out = Bytes.alloc(length);
		if (length == 0)
			return out;

		// Chosen at runtime by `__isWindows`, but compiled everywhere -- and
		// bcrypt.h is only included under HX_WINDOWS, so on Linux the call
		// named symbols that did not exist and the build stopped at
		// "BCRYPT_USE_SYSTEM_PREFERRED_RNG was not declared". A runtime check
		// picks which code runs; only the preprocessor decides what has to
		// compile. Unreachable off Windows, so the other half is never used.
		var ok:Bool = untyped __cpp__('
#ifdef HX_WINDOWS
        (::BCryptGenRandom(
            (void*)0,
            (PUCHAR)&{0}->b[0],
            (unsigned long){1},
            BCRYPT_USE_SYSTEM_PREFERRED_RNG
        ) == 0)
#else
        false
#endif
    ', out, length);

		if (!ok)
			throw "BCryptGenRandom failed";
		return out;
	}

	private static function __getSecureRandomBytesUnix(length:Int):Bytes {
		if (length <= 0) {
			return Bytes.alloc(length < 0 ? 0 : length);
		}

		var out:Bytes = Bytes.alloc(length);

		__lock.acquire();
		try {
			if (__urandom == null) {
				__urandom = sys.io.File.read("/dev/urandom", true);
			}

			var filled:Int = 0;
			while (filled < length) {
				var n:Int = __urandom.readBytes(out, filled, length - filled);
				if (n <= 0) {
					throw "Short read from /dev/urandom";
				}
				filled += n;
			}
		} catch (e:Dynamic) {
			try {
				__urandom.close();
			} catch (_:Dynamic) {}
			__urandom = null;
			__lock.release();
			throw "Failed to read from /dev/urandom: " + e;
		}

		__lock.release();
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
