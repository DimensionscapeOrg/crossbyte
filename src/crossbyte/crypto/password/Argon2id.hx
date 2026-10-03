package crossbyte.crypto.password;

import haxe.io.Bytes;
import crossbyte.Future;
import crossbyte.crypto.password._internal.PasswordWork;
import crossbyte.sys.TaskPool;
import crossbyte.errors.IllegalOperationError;
#if !(cpp || nodejs)
import crossbyte.crypto._internal.NativeOnly;
#end
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end
#if nodejs
import haxe.crypto.BaseCode;
import crossbyte.Completer;
import crossbyte.crypto.ConstantTime;
import crossbyte.crypto.SecureRandom;
import crossbyte.utils.IntParse;
#end

/**
 * Argon2id password hashing and password-based key derivation (libsodium
 * `crypto_pwhash`, algorithm fixed to Argon2id v1.3).
 *
 * `hash`/`verify` operate on the self-describing PHC string format
 * (`$argon2id$...`), which embeds the salt and cost parameters. `derive`
 * produces raw key material for a caller-managed salt.
 *
 * Prefer this over `BCrypt` for new designs. Available on native `cpp` targets
 * through the statically linked libsodium, and on Node 24.7 and later through
 * Node's own `crypto.argon2`, with hashes interchangeable between the two. Every
 * method throws an `IllegalOperationError` where neither exists, naming the
 * target, or on Node the version; check `isAvailable` first.
 *
 * A hash at the interactive limits holds 64 MiB and a core for tens of
 * milliseconds, and the moderate and sensitive limits for far longer. On a
 * server, use `hashAsync` and `verifyAsync`, which keep the calling thread
 * serving, and `dummyHash` for sign-ins naming a user that does not exist.
 */
class Argon2id {
	/**
	 * Length in bytes of a `derive` salt.
	 */
	public static inline final SALT_BYTES:Int = 16;

	/**
	 * Minimum length in bytes of raw derived output.
	 */
	public static inline final BYTES_MIN:Int = 16;

	/**
	 * Maximum length in bytes of a PHC hash string, including terminator.
	 */
	public static inline final STR_BYTES:Int = 128;

	/**
	 * Minimum operations limit.
	 */
	public static inline final OPSLIMIT_MIN:Int = 1;

	/**
	 * Operations limit for interactive logins.
	 */
	public static inline final OPSLIMIT_INTERACTIVE:Int = 2;

	/**
	 * Operations limit for moderate offline resistance.
	 */
	public static inline final OPSLIMIT_MODERATE:Int = 3;

	/**
	 * Operations limit for highly sensitive material.
	 */
	public static inline final OPSLIMIT_SENSITIVE:Int = 4;

	/**
	 * Minimum memory limit in bytes (8 KiB).
	 */
	public static inline final MEMLIMIT_MIN:Int = 8192;

	/**
	 * Memory limit for interactive logins (64 MiB).
	 */
	public static inline final MEMLIMIT_INTERACTIVE:Int = 67108864;

	/**
	 * Memory limit for moderate offline resistance (256 MiB).
	 */
	public static inline final MEMLIMIT_MODERATE:Int = 268435456;

	/**
	 * Memory limit for highly sensitive material (1 GiB).
	 */
	public static inline final MEMLIMIT_SENSITIVE:Int = 1073741824;

	/** What every member throws where there is no backend: which target this is, or which Node. */
	@:noCompletion private static function __unavailable():IllegalOperationError {
		#if nodejs
		return new IllegalOperationError("Argon2id on Node needs crypto.argon2, which arrived in Node 24.7; this is " + js.Node.process.version + ".");
		#elseif cpp
		return new IllegalOperationError("Argon2id needs libsodium, which could not be started.");
		#else
		return new IllegalOperationError("Argon2id is only available natively (cpp) and on Node 24.7 or later, not on " + NativeOnly.TARGET + ".");
		#end
	}

	// The last dummy hash made, replaced when other limits are asked for. One
	// reference, written and read whole, so racing threads leave a valid hash.
	@:noCompletion private static var __dummy:Null<String> = null;

	/**
	 * Returns `true` when an Argon2id backend is available: libsodium on native
	 * targets, `crypto.argon2` on Node.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#elseif nodejs
		return __nodeHasArgon2();
		#else
		return false;
		#end
	}

	/**
	 * Hashes `password` into a self-describing PHC string.
	 *
	 * @throws IllegalOperationError When no backend is available.
	 * @throws String When the limits are below the minimums.
	 */
	public static function hash(password:String, opslimit:Int = OPSLIMIT_INTERACTIVE, memlimit:Int = MEMLIMIT_INTERACTIVE):String {
		if (password == null) {
			throw "password must not be null";
		}
		__validateLimits(opslimit, memlimit);

		#if cpp
		SodiumGlue.ensureAvailable();

		var passwordBytes = Bytes.ofString(password);
		var out = Bytes.alloc(STR_BYTES);
		var rc = NativeSodium.pwhashStr(SodiumGlue.ptr(out), SodiumGlue.cptrOrEmpty(passwordBytes), passwordBytes.length, opslimit, memlimit);
		passwordBytes.fill(0, passwordBytes.length, 0);
		if (rc != 0) {
			throw "libsodium crypto_pwhash_str failed (out of memory?): " + rc;
		}

		var terminator = 0;
		while (terminator < STR_BYTES && out.get(terminator) != 0) {
			terminator++;
		}
		return out.getString(0, terminator);
		#elseif nodejs
		__requireNode();
		var salt:Bytes = SecureRandom.getSecureRandomBytes(SALT_BYTES);
		var passwordBytes = Bytes.ofString(password);
		var tag:Bytes = __nodeCompute(passwordBytes, salt, STR_HASH_BYTES, opslimit, memlimit >> 10, 1);
		passwordBytes.fill(0, passwordBytes.length, 0);
		return __encode(memlimit >> 10, opslimit, 1, salt, tag);
		#else
		throw __unavailable();
		#end
	}

	/**
	 * Verifies `password` against a PHC hash string.
	 *
	 * @return `true` only when the string parses and the password matches;
	 *         `false` for malformed strings and mismatches.
	 * @throws IllegalOperationError When no backend is available, as `hash` does. This used to
	 *         return `false` there instead, which refused every password on those
	 *         targets while looking like a working check.
	 */
	public static function verify(hashStr:String, password:String):Bool {
		#if cpp
		SodiumGlue.ensureAvailable();
		if (hashStr == null || password == null || hashStr.length >= STR_BYTES) {
			return false;
		}

		var passwordBytes = Bytes.ofString(password);
		var matched:Bool = NativeSodium.pwhashStrVerify(SodiumGlue.cptr(__nulTerminated(hashStr)), SodiumGlue.cptrOrEmpty(passwordBytes),
			passwordBytes.length) == 0;
		passwordBytes.fill(0, passwordBytes.length, 0);
		return matched;
		#elseif nodejs
		__requireNode();
		if (hashStr == null || password == null || hashStr.length >= STR_BYTES) {
			return false;
		}

		var parsed:Null<PhcHash> = __decode(hashStr);
		if (parsed == null) {
			return false;
		}

		var passwordBytes = Bytes.ofString(password);
		var tag:Null<Bytes> = null;
		try {
			tag = __nodeCompute(passwordBytes, parsed.salt, parsed.hash.length, parsed.passes, parsed.memoryKiB, parsed.lanes);
		} catch (_:Dynamic) {
			// Parameters Node refuses, such as memory it cannot allocate: a
			// hash libsodium would refuse to verify as well.
		}
		passwordBytes.fill(0, passwordBytes.length, 0);
		return tag != null && ConstantTime.equals(tag, parsed.hash);
		#else
		throw __unavailable();
		#end
	}

	/**
	 * Returns `true` when `hashStr` should be recomputed because it does not
	 * match the supplied cost parameters (or cannot be parsed).
	 */
	public static function needsRehash(hashStr:String, opslimit:Int, memlimit:Int):Bool {
		__validateLimits(opslimit, memlimit);
		if (hashStr == null || hashStr.length >= STR_BYTES) {
			return true;
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		return NativeSodium.pwhashStrNeedsRehash(SodiumGlue.cptr(__nulTerminated(hashStr)), opslimit, memlimit) != 0;
		#elseif nodejs
		__requireNode();
		// What libsodium compares: the passes and the memory in KiB.
		var parsed:Null<PhcHash> = __decode(hashStr);
		return parsed == null || parsed.passes != opslimit || parsed.memoryKiB != (memlimit >> 10);
		#else
		throw __unavailable();
		#end
	}

	/**
	 * Derives `length` bytes of raw key material from a password and a
	 * caller-managed `SALT_BYTES` salt. Deterministic for identical inputs.
	 */
	public static function derive(password:String, salt:Bytes, length:Int, opslimit:Int, memlimit:Int):Bytes {
		if (password == null) {
			throw "password must not be null";
		}
		if (salt == null || salt.length != SALT_BYTES) {
			throw "salt must be " + SALT_BYTES + " bytes";
		}
		if (length < BYTES_MIN) {
			throw "derived length must be at least " + BYTES_MIN + " bytes";
		}
		__validateLimits(opslimit, memlimit);

		#if cpp
		SodiumGlue.ensureAvailable();

		var passwordBytes = Bytes.ofString(password);
		var out = Bytes.alloc(length);
		var rc = NativeSodium.pwhashDerive(SodiumGlue.ptr(out), length, SodiumGlue.cptrOrEmpty(passwordBytes), passwordBytes.length,
			SodiumGlue.cptr(salt), opslimit, memlimit);
		passwordBytes.fill(0, passwordBytes.length, 0);
		if (rc != 0) {
			throw "libsodium crypto_pwhash failed (out of memory?): " + rc;
		}
		return out;
		#elseif nodejs
		__requireNode();
		var passwordBytes = Bytes.ofString(password);
		var out:Bytes = __nodeCompute(passwordBytes, salt, length, opslimit, memlimit >> 10, 1);
		passwordBytes.fill(0, passwordBytes.length, 0);
		return out;
		#else
		throw __unavailable();
		#end
	}

	/**
	 * `hash`, off the calling thread.
	 *
	 * On native targets it runs on a `TaskPool` worker, the pool given, or a
	 * small one the password hashers share, and the future completes on the
	 * calling runtime's thread at its next tick (on the worker when the caller runs
	 * no runtime). On Node it runs on libuv's thread pool through
	 * `crypto.argon2`, and `pool` is not used. Anywhere else the future fails as
	 * `hash` throws.
	 */
	public static function hashAsync(password:String, opslimit:Int = OPSLIMIT_INTERACTIVE, memlimit:Int = MEMLIMIT_INTERACTIVE,
			?pool:TaskPool):Future<String> {
		#if nodejs
		var completer:Completer<String> = new Completer<String>();
		try {
			if (password == null) {
				throw "password must not be null";
			}
			__validateLimits(opslimit, memlimit);
			__requireNode();

			var salt:Bytes = SecureRandom.getSecureRandomBytes(SALT_BYTES);
			__nodeComputeAsync(Bytes.ofString(password), salt, STR_HASH_BYTES, opslimit, memlimit >> 10, 1, (error, tag) -> {
				if (error != null) {
					completer.fail(error);
				} else {
					completer.complete(__encode(memlimit >> 10, opslimit, 1, salt, tag));
				}
			});
		} catch (error:Dynamic) {
			completer.fail(error);
		}
		return completer.future;
		#else
		return PasswordWork.run(() -> hash(password, opslimit, memlimit), pool);
		#end
	}

	/**
	 * `verify`, off the calling thread; see `hashAsync` for where it runs.
	 *
	 * @return Whether the password matches, `false` for a malformed hash, or a
	 *         failure where no backend is available.
	 */
	public static function verifyAsync(hashStr:String, password:String, ?pool:TaskPool):Future<Bool> {
		#if nodejs
		var completer:Completer<Bool> = new Completer<Bool>();
		try {
			__requireNode();
			var parsed:Null<PhcHash> = (hashStr == null || password == null || hashStr.length >= STR_BYTES) ? null : __decode(hashStr);
			if (parsed == null) {
				completer.complete(false);
				return completer.future;
			}

			__nodeComputeAsync(Bytes.ofString(password), parsed.salt, parsed.hash.length, parsed.passes, parsed.memoryKiB, parsed.lanes,
				(error, tag) -> completer.complete(error == null && ConstantTime.equals(tag, parsed.hash)));
		} catch (error:Dynamic) {
			completer.fail(error);
		}
		return completer.future;
		#else
		return PasswordWork.run(() -> verify(hashStr, password), pool);
		#end
	}

	/**
	 * A hash of a random password, to verify against when a sign-in names a user
	 * that does not exist, so the answer takes as long as a real user's wrong
	 * password does:
	 *
	 * ```haxe
	 * var stored:String = user != null ? user.passwordHash : Argon2id.dummyHash();
	 * var ok:Bool = Argon2id.verify(stored, password) && user != null;
	 * ```
	 *
	 * Made once per pair of limits and kept. Pass the limits real hashes use.
	 */
	public static function dummyHash(opslimit:Int = OPSLIMIT_INTERACTIVE, memlimit:Int = MEMLIMIT_INTERACTIVE):String {
		var cached:Null<String> = __dummy;
		if (cached != null && !needsRehash(cached, opslimit, memlimit)) {
			return cached;
		}

		var made:String = hash(haxe.crypto.Base64.encode(crossbyte.crypto.SecureRandom.getSecureRandomBytes(SALT_BYTES)), opslimit, memlimit);
		__dummy = made;
		return made;
	}

	@:noCompletion
	private static function __validateLimits(opslimit:Int, memlimit:Int):Void {
		if (opslimit < OPSLIMIT_MIN) {
			throw "opslimit must be at least " + OPSLIMIT_MIN;
		}
		if (memlimit < MEMLIMIT_MIN) {
			throw "memlimit must be at least " + MEMLIMIT_MIN + " bytes";
		}
	}

	#if cpp
	@:noCompletion
	private static function __nulTerminated(value:String):Bytes {
		var raw = Bytes.ofString(value);
		var terminated = Bytes.alloc(raw.length + 1);
		terminated.blit(0, raw, 0, raw.length);
		terminated.set(raw.length, 0);
		return terminated;
	}
	#end

	#if nodejs
	// libsodium's crypto_pwhash_str writes a 32-byte hash.
	@:noCompletion private static inline final STR_HASH_BYTES:Int = 32;
	// ARGON2_MIN_SALT_LENGTH and ARGON2_MIN_OUTLEN, the least libsodium accepts.
	@:noCompletion private static inline final MIN_SALT_BYTES:Int = 8;
	@:noCompletion private static inline final MIN_HASH_BYTES:Int = 16;
	@:noCompletion private static inline final PHC_PREFIX:String = "$argon2id$v=19$m=";
	@:noCompletion private static final __base64:BaseCode = new BaseCode(Bytes.ofString("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"));

	@:noCompletion private static function __nodeCrypto():Dynamic {
		return js.Lib.require("crypto");
	}

	/**
	 * Whether this Node has `crypto.argon2`, added in 24.7. Checked rather than
	 * assumed, so an older Node answers `isAvailable` truthfully.
	 */
	@:noCompletion private static function __nodeHasArgon2():Bool {
		var crypto:Dynamic = __nodeCrypto();
		return js.Syntax.typeof(crypto.argon2Sync) == "function" && js.Syntax.typeof(crypto.argon2) == "function";
	}

	@:noCompletion private static function __requireNode():Void {
		if (!__nodeHasArgon2()) {
			throw __unavailable();
		}
	}

	@:noCompletion private static function __nodeParameters(password:Bytes, salt:Bytes, length:Int, passes:Int, memoryKiB:Int, lanes:Int):Dynamic {
		return {
			message: js.node.Buffer.hxFromBytes(password),
			nonce: js.node.Buffer.hxFromBytes(salt),
			parallelism: lanes,
			tagLength: length,
			memory: memoryKiB,
			passes: passes
		};
	}

	@:noCompletion private static function __bytesOf(buffer:js.node.Buffer):Bytes {
		// Copied out by its own region: a small Buffer can be a window onto a
		// larger pooled allocation.
		return Bytes.ofData(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength));
	}

	@:noCompletion private static function __nodeCompute(password:Bytes, salt:Bytes, length:Int, passes:Int, memoryKiB:Int, lanes:Int):Bytes {
		var tag:js.node.Buffer = __nodeCrypto().argon2Sync("argon2id", __nodeParameters(password, salt, length, passes, memoryKiB, lanes));
		return __bytesOf(tag);
	}

	@:noCompletion private static function __nodeComputeAsync(password:Bytes, salt:Bytes, length:Int, passes:Int, memoryKiB:Int, lanes:Int,
			done:(Dynamic, Null<Bytes>) -> Void):Void {
		__nodeCrypto().argon2("argon2id", __nodeParameters(password, salt, length, passes, memoryKiB, lanes), function(error:Dynamic, tag:js.node.Buffer) {
			password.fill(0, password.length, 0);
			if (error != null) {
				done(error, null);
			} else {
				done(null, __bytesOf(tag));
			}
		});
	}

	/**
	 * The PHC string libsodium writes: `$argon2id$v=19$m=<KiB>,t=<passes>,p=<lanes>$`
	 * and the salt and hash in standard base64 without padding.
	 */
	@:noCompletion private static function __encode(memoryKiB:Int, passes:Int, lanes:Int, salt:Bytes, tag:Bytes):String {
		return PHC_PREFIX + memoryKiB + ",t=" + passes + ",p=" + lanes + "$" + __base64.encodeBytes(salt).toString() + "$"
			+ __base64.encodeBytes(tag).toString();
	}

	/**
	 * Parses a PHC string as libsodium's `decode_string` does for Argon2id v1.3,
	 * or returns null. Base64 must be canonical, as libsodium's decoder requires.
	 */
	@:noCompletion private static function __decode(encoded:String):Null<PhcHash> {
		if (!StringTools.startsWith(encoded, PHC_PREFIX)) {
			return null;
		}

		var fields:Array<String> = encoded.substr(PHC_PREFIX.length).split("$");
		if (fields.length != 3) {
			return null;
		}

		var costs:Array<String> = fields[0].split(",");
		if (costs.length != 3 || !StringTools.startsWith(costs[1], "t=") || !StringTools.startsWith(costs[2], "p=")) {
			return null;
		}

		var memoryKiB:Int = IntParse.decimal(costs[0]);
		var passes:Int = IntParse.decimal(costs[1].substr(2));
		var lanes:Int = IntParse.decimal(costs[2].substr(2), 0xFFFFFF);
		if (passes < 1 || lanes < 1 || memoryKiB < 8 * lanes) {
			return null;
		}

		var salt:Null<Bytes> = __decodeCanonical(fields[1]);
		var hash:Null<Bytes> = __decodeCanonical(fields[2]);
		if (salt == null || hash == null || salt.length < MIN_SALT_BYTES || hash.length < MIN_HASH_BYTES) {
			return null;
		}

		return {
			memoryKiB: memoryKiB,
			passes: passes,
			lanes: lanes,
			salt: salt,
			hash: hash
		};
	}

	@:noCompletion private static function __decodeCanonical(text:String):Null<Bytes> {
		if (text.length == 0) {
			return null;
		}

		var decoded:Bytes;
		try {
			decoded = __base64.decodeBytes(Bytes.ofString(text));
		} catch (_:Dynamic) {
			return null;
		}
		// Stray low bits in the last character decode to the same bytes, and
		// libsodium refuses them; so does this.
		return __base64.encodeBytes(decoded).toString() == text ? decoded : null;
	}
	#end
}

#if nodejs
/** A PHC string's parts, as `__decode` reads them. **/
@:structInit
private final class PhcHash {
	public final memoryKiB:Int;
	public final passes:Int;
	public final lanes:Int;
	public final salt:Bytes;
	public final hash:Bytes;
}
#end
