package crossbyte.crypto;

import crossbyte.crypto.PublicKeySignature.PublicKeyType;
import haxe.io.Bytes;
import utest.Assert;
#if cpp
import crossbyte.auth.jwt.JWT;
import crossbyte.auth.jwt.PkKeyFixture;
import crossbyte.crypto._internal.NativePk;
import crossbyte.errors.ArgumentError;
import haxe.ds.StringMap;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
 * RSA and EC keys parsed once into mbedTLS and held natively.
 *
 * Every sign and verify used to parse its PEM afresh: a copy of the private
 * key in freed memory per signature, the EC comb table rebuilt per operation,
 * and, since the parse and the signature ran outside a GC-free zone, a
 * 4096-bit RSA signature on a worker held every collection for its 25 ms.
 * Keys come from `PkKeyFixture`, generated with the openssl CLI; the cases
 * pass without asserting when it is missing, as the JWT ones do.
 */
class SignatureKeyTest extends utest.Test {
	public function testTheBackendIsNativeOnly():Void {
		#if cpp
		Assert.isTrue(PublicKeySignature.isAvailable());
		#else
		Assert.isFalse(PublicKeySignature.isAvailable());
		Assert.raises(() -> SignatureKey.fromPublicPem("-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----"));
		Assert.equals(PublicKeyType.UNKNOWN, PublicKeySignature.keyType("-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----"));
		#end
	}

	#if cpp
	public function testAKeyIsParsedOnceForAnyNumberOfSignatures():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var before:Int = NativePk.parseCount();
		var signer:SignatureKey = SignatureKey.fromPrivatePem(keys.privatePem);
		var verifier:SignatureKey = SignatureKey.fromPublicPem(keys.publicPem);
		Assert.equals(PublicKeyType.EC, signer.type);
		Assert.equals(64, verifier.joseSignatureLength());

		for (i in 0...5) {
			var message:Bytes = Bytes.ofString("message " + i);
			var signature:Bytes = signer.sign(message, JOSE);
			Assert.equals(64, signature.length);
			Assert.isTrue(verifier.verify(message, signature, JOSE));
			Assert.isFalse(verifier.verify(Bytes.ofString("other " + i), signature, JOSE));
		}

		Assert.equals(2, NativePk.parseCount() - before, "one parse per key, not per operation");
	}

	public function testAJwtSignerParsesItsKeysOnceNotPerToken():Void {
		var keys = PkKeyFixture.rsa();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var publicKeys = new StringMap<String>();
		publicKeys.set("k1", keys.publicPem);

		var before:Int = NativePk.parseCount();
		var jwt:JWT = JWT.make(RS256(publicKeys, keys.privatePem, "k1"));
		var constructed:Int = NativePk.parseCount();
		Assert.equals(2, constructed - before, "the public and the private key");

		var now:Int = Std.int(Date.now().getTime() / 1000);
		for (i in 0...5) {
			var token:String = jwt.generateToken({sub: "user-" + i, iat: now, exp: now + 60});
			Assert.notNull(jwt.verifyToken(token));
		}

		Assert.equals(constructed, NativePk.parseCount(), "no parse per token signed or checked");
	}

	public function testADisposedKeyIsGoneForGood():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var message:Bytes = Bytes.ofString("m");
		var signer:SignatureKey = SignatureKey.fromPrivatePem(keys.privatePem);
		var signature:Bytes = signer.sign(message, JOSE);
		var verifier:SignatureKey = SignatureKey.fromPublicPem(keys.publicPem);
		Assert.isTrue(verifier.verify(message, signature, JOSE));

		signer.dispose();
		verifier.dispose();
		Assert.equals(PublicKeyType.UNKNOWN, signer.type);
		Assert.raises(() -> signer.sign(message, JOSE));
		Assert.isFalse(verifier.verify(message, signature, JOSE));
		Assert.equals(-1, verifier.joseSignatureLength());
		// Disposing twice is harmless.
		signer.dispose();
	}

	public function testUnreadableAndMisusedKeysAreRefused():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		Assert.raises(() -> SignatureKey.fromPublicPem(""), ArgumentError);
		Assert.raises(() -> SignatureKey.fromPrivatePem(null), ArgumentError);
		Assert.raises(() -> SignatureKey.fromPrivatePem("-----BEGIN PRIVATE KEY-----\nbm9wZQ==\n-----END PRIVATE KEY-----"), String);
		// A public key is not a private one.
		Assert.raises(() -> SignatureKey.fromPrivatePem(keys.publicPem), String);
		Assert.raises(() -> SignatureKey.fromPublicPem(keys.publicPem).sign(Bytes.ofString("m")), ArgumentError);
		// A signature too long for any key is refused, not read past.
		Assert.isFalse(SignatureKey.fromPublicPem(keys.publicPem).verify(Bytes.ofString("m"), Bytes.alloc(4096), JOSE));
	}

	public function testOneKeySharedByThreadsSignsAndVerifiesCorrectly():Void {
		var keys = PkKeyFixture.ec();
		if (keys == null) {
			Assert.pass();
			return;
		}

		// Fresh keys, so the threads race on mbedTLS's first use of them: that
		// is when it builds the comb table inside the key.
		var signer:SignatureKey = SignatureKey.fromPrivatePem(keys.privatePem);
		var verifier:SignatureKey = SignatureKey.fromPublicPem(keys.publicPem);
		var threads:Int = 4;
		var rounds:Int = 25;
		var done:Lock = new Lock();
		var tally:Mutex = new Mutex();
		var good:Int = 0;
		var bad:Int = 0;

		for (t in 0...threads) {
			Thread.create(() -> {
				var mine:Int = 0;
				for (i in 0...rounds) {
					try {
						var message:Bytes = Bytes.ofString('thread $t message $i');
						if (verifier.verify(message, signer.sign(message, JOSE), JOSE)) {
							mine++;
						}
					} catch (_:Dynamic) {}
				}
				tally.acquire();
				good += mine;
				bad += rounds - mine;
				tally.release();
				done.release();
			});
		}

		for (t in 0...threads) {
			Assert.isTrue(done.wait(60.0), "a signing thread finished");
		}
		Assert.equals(threads * rounds, good);
		Assert.equals(0, bad);
	}

	public function testRsaSigningOnAWorkerDoesNotHoldUpCollections():Void {
		var keys = PkKeyFixture.rsa4096();
		if (keys == null) {
			Assert.pass();
			return;
		}

		var key:SignatureKey = SignatureKey.fromPrivatePem(keys.privatePem);
		var message:Bytes = Bytes.ofString("m");
		var s0:Float = haxe.Timer.stamp();
		key.sign(message);
		var signMs:Float = (haxe.Timer.stamp() - s0) * 1000;

		var idle:Array<Float> = [for (i in 0...5) timedCollection()];

		// A worker signs back to back, so a collection lands mid-signature.
		var stop:Deque<Bool> = new Deque<Bool>();
		var stopped:Lock = new Lock();
		Thread.create(() -> {
			while (stop.pop(false) == null) {
				key.sign(message);
			}
			stopped.release();
		});

		crossbyte.sys.System.sleep(0.05);
		var busy:Array<Float> = [];
		for (i in 0...15) {
			// Out of step with the signatures, so the samples fall at different
			// points in one.
			crossbyte.sys.System.sleep(0.011 + (i % 5) * 0.003);
			busy.push(timedCollection());
		}
		stop.add(true);
		Assert.isTrue(stopped.wait(30.0));

		// Held up, a collection waits out the rest of the signature it lands
		// in: half of one on the median, and under a quarter for 15 samples'
		// median less than 2% of the time.
		var idleMs:Float = median(idle);
		var busyMs:Float = median(busy);
		Assert.isTrue(busyMs < idleMs + signMs / 4, 'median collection ${busyMs} ms (${idleMs} ms idle) while ${signMs} ms signatures ran');
	}

	static function timedCollection():Float {
		var t0:Float = haxe.Timer.stamp();
		cpp.vm.Gc.run(true);
		return Math.round((haxe.Timer.stamp() - t0) * 10000) / 10;
	}

	static function median(values:Array<Float>):Float {
		var sorted:Array<Float> = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}
	#end
}
