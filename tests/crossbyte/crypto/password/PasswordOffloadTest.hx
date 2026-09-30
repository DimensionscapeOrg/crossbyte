package crossbyte.crypto.password;

import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import crossbyte.sys.TaskPool;
import utest.Assert;
import utest.Async;
#if cpp
import sys.thread.Lock;
import sys.thread.Thread;
#end

/**
 * Password hashing off the runtime's thread, and the pieces that make that safe.
 *
 * A hash at the recommended cost is 50-300 ms of one thread doing nothing else,
 * so a runtime hashing sign-ins serves nobody meanwhile. Moving it to a worker
 * is only half the fix on hxcpp: a collection waits for every thread to reach a
 * safe point, and neither libsodium nor BCrypt's allocation-free inner loop ever
 * reaches one, so the stall moved from one runtime to every thread in the
 * process. The native cases here time a collection while a worker hashes.
 */
@:access(crossbyte.core.CrossByte)
class PasswordOffloadTest extends utest.Test {
	/** A standard `$2b$` hash of "abc"; see BCryptVectorsTest. */
	static inline final STANDARD_ABC:String = "$2b$04$abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2";

	/**
	 * The Argon2id v1.3 vector from the reference implementation's test suite:
	 * "password", salt "somesalt", 64 MiB, two passes, one lane.
	 */
	static inline final ARGON_REFERENCE:String = "$argon2id$v=19$m=65536,t=2,p=1$c29tZXNhbHQ$CTFhFdXPJO1aFaMaO6Mm5c8y7cJHAph8ArZWb2GRPPc";

	/** "password" hashed by Node's crypto.argon2, which is OpenSSL's. */
	static inline final ARGON_FROM_NODE:String = "$argon2id$v=19$m=256,t=2,p=1$c29tZXNhbHQ$nf65EOgLrQMR/uIPnA4rEsF5h7TKyQwu9U1bMCHGi/4";

	/** "password" hashed by libsodium's crypto_pwhash_str, at the minimum limits. */
	static inline final ARGON_FROM_LIBSODIUM:String = "$argon2id$v=19$m=8,t=1,p=1$zQl1prQFPad8oOomaRKHiw$qx7RzkrnVeQEsi0yk5T0pjPqHLuFZju0/HIqmMDYCa0";

	// Three verifies and a hash at cost 4: a few milliseconds natively, and
	// about 50 ms a verify where BCrypt is pure Haxe on a slow target, neko.
	@:timeout(5000)
	public function testBCryptAsyncAgreesWithVerify(async:Async):Void {
		var good:Future<Bool> = BCrypt.verifyAsync("abc", STANDARD_ABC);
		var bad:Future<Bool> = BCrypt.verifyAsync("abcabc", STANDARD_ABC);
		var malformed:Future<Bool> = BCrypt.verifyAsync("abc", "$2b$04$not-a-hash");

		pumpUntil(() -> good.completed && bad.completed && malformed.completed, 30, finished -> {
			Assert.isTrue(finished, "every verification completed");
			Assert.isTrue(good.succeeded && good.result == true);
			Assert.isTrue(bad.succeeded && bad.result == false);
			// A malformed hash is a refusal, as verify has it, not a failure.
			Assert.isTrue(malformed.succeeded && malformed.result == false);

			var made:Future<String> = BCrypt.hashAsync("hunter2", 4);
			pumpUntil(() -> made.completed, 30, finished -> {
				Assert.isTrue(finished, "the hash completed");
				if (SecureRandom.isSupported) {
					Assert.isTrue(made.succeeded, made.error);
					Assert.isTrue(made.succeeded && BCrypt.verify("hunter2", made.result));
				} else {
					// No CSPRNG to salt it with: the failure hash() throws, in the future.
					Assert.isFalse(made.succeeded);
				}
				async.done();
			});
		});
	}

	public function testAShutDownPoolFailsTheFutureRatherThanThrowing():Void {
		var pool:TaskPool = new TaskPool(1);
		pool.shutdown();

		var result:Future<Bool> = BCrypt.verifyAsync("abc", STANDARD_ABC, pool);
		var reported:Null<String> = null;
		result.catchError(message -> reported = message);
		Assert.isTrue(result.completed);
		Assert.isFalse(result.succeeded);
		Assert.notNull(reported);
	}

	public function testBCryptDummyHashRefusesEveryPasswordAtTheRequestedCost():Void {
		if (!SecureRandom.isSupported) {
			Assert.raises(() -> BCrypt.dummyHash(4));
			return;
		}

		var dummy:String = BCrypt.dummyHash(4);
		Assert.equals("$2b$04$", dummy.substr(0, 7));
		Assert.isFalse(BCrypt.needsRehash(dummy, 4));
		Assert.isFalse(BCrypt.verify("", dummy));
		Assert.isFalse(BCrypt.verify("password", dummy));
		// Kept: made once per cost, so only the first sign-in pays to make it.
		Assert.equals(dummy, BCrypt.dummyHash(4));

		var dearer:String = BCrypt.dummyHash(5);
		Assert.equals("$2b$05$", dearer.substr(0, 7));
	}

	public function testArgon2idIsAvailableOnNativeAndNodeAndThrowsElsewhere():Void {
		#if cpp
		Assert.isTrue(Argon2id.isAvailable());
		#elseif nodejs
		// Node has had crypto.argon2 only since 24.7, and an older one has to
		// say so rather than claim it: the answer is checked against Node's
		// own module, not assumed. CI's Windows image runs an older Node.
		var present:Bool = js.Syntax.code("typeof require('crypto').argon2 === 'function'");
		Assert.equals(present, Argon2id.isAvailable());
		if (!present) {
			__assertArgon2idThrows();
		}
		#else
		Assert.isFalse(Argon2id.isAvailable());
		__assertArgon2idThrows();
		#end
	}

	private function __assertArgon2idThrows():Void {
		// It returned false for every password where it could not run, which
		// looked like a working check refusing everyone.
		Assert.raises(() -> Argon2id.verify(ARGON_REFERENCE, "password"));
		Assert.raises(() -> Argon2id.hash("password"));
		Assert.raises(() -> Argon2id.needsRehash(ARGON_REFERENCE, 2, Argon2id.MEMLIMIT_INTERACTIVE));
	}

	public function testArgon2idVerifiesHashesFromEveryImplementation():Void {
		if (!Argon2id.isAvailable()) {
			Assert.raises(() -> Argon2id.verify(ARGON_FROM_NODE, "password"));
			return;
		}

		Assert.isTrue(Argon2id.verify(ARGON_REFERENCE, "password"));
		Assert.isTrue(Argon2id.verify(ARGON_FROM_NODE, "password"));
		Assert.isTrue(Argon2id.verify(ARGON_FROM_LIBSODIUM, "password"));
		Assert.isFalse(Argon2id.verify(ARGON_FROM_LIBSODIUM, "passwore"));

		// Malformed strings are refused, not thrown.
		for (bad in [
			"",
			"$argon2i$v=19$m=8,t=1,p=1$zQl1prQFPad8oOomaRKHiw$qx7RzkrnVeQEsi0yk5T0pjPqHLuFZju0/HIqmMDYCa0",
			"$argon2id$v=19$m=8,t=1,p=1$zQl1prQFPad8oOomaRKHiw",
			"$argon2id$v=19$m=8,t=1,p=1$zQl1prQFPad8oOomaRKHiw$qx7RzkrnVeQEsi0yk5T0pjPqHLuFZju0/HIqmMDYCa0$",
			"$argon2id$v=19$m=x,t=1,p=1$zQl1prQFPad8oOomaRKHiw$qx7RzkrnVeQEsi0yk5T0pjPqHLuFZju0/HIqmMDYCa0",
			"$argon2id$v=19$m=8,t=1,p=1$zQl1prQFPad8oOomaRKHiw$qx7RzkrnVeQEsi0yk5T0pjPqHLuFZju0/HIqmMDYCa0="
		]) {
			Assert.isFalse(Argon2id.verify(bad, "password"), bad);
		}

		var made:String = Argon2id.hash("correct horse", Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		Assert.isTrue(StringTools.startsWith(made, "$argon2id$v=19$m=8,t=1,p=1$"), made);
		Assert.isTrue(Argon2id.verify(made, "correct horse"));
		Assert.isFalse(Argon2id.needsRehash(made, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN));
		Assert.isTrue(Argon2id.needsRehash(made, Argon2id.OPSLIMIT_MIN + 1, Argon2id.MEMLIMIT_MIN));

		var dummy:String = Argon2id.dummyHash(Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);
		Assert.isFalse(Argon2id.needsRehash(dummy, Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN));
		Assert.isFalse(Argon2id.verify(dummy, "password"));
		Assert.equals(dummy, Argon2id.dummyHash(Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN));
	}

	public function testArgon2idAsyncAgreesWithVerify(async:Async):Void {
		var good:Future<Bool> = Argon2id.verifyAsync(ARGON_FROM_LIBSODIUM, "password");
		var bad:Future<Bool> = Argon2id.verifyAsync(ARGON_FROM_LIBSODIUM, "passwore");
		var made:Future<String> = Argon2id.hashAsync("correct horse", Argon2id.OPSLIMIT_MIN, Argon2id.MEMLIMIT_MIN);

		pumpUntil(() -> good.completed && bad.completed && made.completed, 30, finished -> {
			Assert.isTrue(finished, "every future completed");
			if (Argon2id.isAvailable()) {
				Assert.isTrue(good.succeeded && good.result == true);
				Assert.isTrue(bad.succeeded && bad.result == false);
				Assert.isTrue(made.succeeded, made.error);
				Assert.isTrue(made.succeeded && Argon2id.verify(made.result, "correct horse"));
			} else {
				Assert.isFalse(good.succeeded);
				Assert.isFalse(made.succeeded);
			}
			async.done();
		});
	}

	#if cpp
	public function testAsyncResultsArriveOnTheCallingRuntimesThread(async:Async):Void {
		var caller:Thread = Thread.current();
		var ranOn:Null<Thread> = null;
		var result:Future<Bool> = BCrypt.verifyAsync("abc", STANDARD_ABC);
		result.then(_ -> ranOn = Thread.current());

		pumpUntil(() -> result.completed, 30, finished -> {
			Assert.isTrue(finished);
			// Not the worker's: handlers touch the runtime's state.
			Assert.isTrue(ranOn == caller);
			async.done();
		});
	}

	public function testArgon2idOnAWorkerDoesNotHoldUpCollections():Void {
		// Enough passes over 64 MiB for a few hundred milliseconds.
		var timing = collectWhileAWorkerHashes(() -> Argon2id.hash("password", 24, Argon2id.MEMLIMIT_INTERACTIVE));
		// Held up, the collection waited out the rest of the hash.
		Assert.isTrue(timing.collectionMs < timing.baselineMs + timing.hashMs / 4,
			'collection ${timing.collectionMs} ms (${timing.baselineMs} ms idle) during a ${timing.hashMs} ms hash');
	}

	public function testBCryptOnAWorkerDoesNotHoldUpCollections():Void {
		var timing = collectWhileAWorkerHashes(() -> BCrypt.hash("password", 13));
		Assert.isTrue(timing.collectionMs < timing.baselineMs + timing.hashMs / 4,
			'collection ${timing.collectionMs} ms (${timing.baselineMs} ms idle) during a ${timing.hashMs} ms hash');
	}

	/**
	 * Starts `hash` on a thread of its own, waits until it is well inside, and
	 * times a full collection on this thread, against one with no worker.
	 */
	static function collectWhileAWorkerHashes(hash:Void->Void):{baselineMs:Float, collectionMs:Float, hashMs:Float} {
		var b0:Float = haxe.Timer.stamp();
		cpp.vm.Gc.run(true);
		var baselineMs:Float = (haxe.Timer.stamp() - b0) * 1000;

		var inside:Lock = new Lock();
		var finished:Lock = new Lock();
		var hashMs:Float = 0;
		Thread.create(() -> {
			inside.release();
			var t0:Float = haxe.Timer.stamp();
			hash();
			hashMs = (haxe.Timer.stamp() - t0) * 1000;
			finished.release();
		});

		inside.wait();
		crossbyte.sys.System.sleep(0.03);
		var c0:Float = haxe.Timer.stamp();
		cpp.vm.Gc.run(true);
		var collectionMs:Float = (haxe.Timer.stamp() - c0) * 1000;
		finished.wait();

		return {baselineMs: Math.round(baselineMs * 10) / 10, collectionMs: Math.round(collectionMs * 10) / 10, hashMs: Math.round(hashMs)};
	}
	#end

	/**
	 * Pumps the runtime until `done`, then calls `then` with whether it got there
	 * inside `timeout` seconds. On JavaScript the waiting spans event loop turns,
	 * since that is where Node's own argon2 reports.
	 *
	 * Elsewhere each pump moves the runtime on by the time that really passed.
	 * It moved it a sixtieth of a second a pump, with a millisecond's sleep
	 * between, so the runtime's clock, which utest's timeouts run on, went
	 * some sixteen times faster than the wall, and neko's pure-Haxe BCrypt,
	 * about 50 ms a verify, ran out a 250 ms timeout in some 20 ms of work.
	 */
	static function pumpUntil(done:Void->Bool, timeout:Float, then:Bool->Void):Void {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + timeout;

		#if js
		function turn():Void {
			runtime.pump(1 / 60, 0);
			if (done()) {
				then(true);
			} else if (haxe.Timer.stamp() >= deadline) {
				then(false);
			} else {
				js.Syntax.code("setTimeout({0}, 1)", turn);
			}
		}
		turn();
		#else
		var last:Float = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			crossbyte.sys.System.sleep(0.001);
		}
		then(done());
		#end
	}
}
