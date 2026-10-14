package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import utest.Assert;

/**
 * `JWTRevocationList`: tokens refused by `jti` until their own `exp`, then
 * forgotten; swept as they expire; bounded, failing closed past the bound;
 * consulted by `JWT.verify` as `REVOKED`, and usable on its own. HS256 and
 * fixed times only, so this runs on every target, PHP included.
 */
class JWTRevocationTest extends utest.Test {
	static inline final SECRET:String = "0123456789abcdef0123456789abcdef";
	static inline final NOW:Float = 1800000000.0;

	public function testARevokedTokenIsRefusedUntilItsExpiryAndThenForgotten():Void {
		final jwt:JWT = JWT.make(HS256([{secret: SECRET}]), null, null, 60);
		final list = new JWTRevocationList();
		jwt.revocations = list;
		final token:String = jwt.generateToken({sub: "user-1", jti: "t-1", iat: NOW, exp: NOW + 600});
		final other:String = jwt.generateToken({sub: "user-2", jti: "t-2", iat: NOW, exp: NOW + 600});
		Assert.isTrue(jwt.verify(token, NOW).valid);

		Assert.isTrue(jwt.revoke(token, NOW), "a token that verifies was not listed");
		final refused:JWTVerification = jwt.verify(token, NOW + 1);
		Assert.equals(JWTRejection.REVOKED, refused.rejection);
		Assert.isNull(refused.payload, "a revoked token's claims were handed back");
		Assert.isNull(jwt.verifyToken(token, NOW + 1));
		Assert.isTrue(jwt.verify(other, NOW + 1).valid, "revoking one token refused another");

		// Up to its exp and the leeway it is refused as revoked; past them, as
		// expired, which it would have been anyway.
		Assert.equals(JWTRejection.REVOKED, jwt.verify(token, NOW + 660).rejection);
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(token, NOW + 661).rejection);

		// And then the list lets it go.
		Assert.equals(1, list.length);
		Assert.equals(0, list.sweep(NOW + 660), "a revocation went before its time");
		Assert.equals(1, list.sweep(NOW + 661), "a revocation past its time was kept");
		Assert.equals(0, list.length);
		Assert.isFalse(list.isRevoked("t-1", NOW + 600));
	}

	public function testAListOnItsOwnTakesTheClaimsItIsGiven():Void {
		final list = new JWTRevocationList(100, 0);
		Assert.isTrue(list.revoke("a", NOW + 10, NOW));
		Assert.isTrue(list.revoke("b", NOW + 20, NOW));
		Assert.isTrue(list.isRevoked("a", NOW + 10));
		Assert.isTrue(list.isRevoked("b", NOW + 20));
		Assert.isFalse(list.isRevoked("c", NOW + 10));
		Assert.isFalse(list.isRevoked(null, NOW + 10));

		// A token past its time is not listed: it is refused as expired anyway.
		Assert.isFalse(list.revoke("old", NOW - 1, NOW));
		Assert.isFalse(list.isRevoked("old", NOW - 1));

		// Revoked again, the later time is kept.
		Assert.isTrue(list.revoke("a", NOW + 30, NOW));
		Assert.isTrue(list.revoke("a", NOW + 5, NOW));
		// b's time has passed by then, a's later one has not.
		Assert.equals(1, list.sweep(NOW + 25));
		Assert.isTrue(list.isRevoked("a", NOW + 30));
		Assert.isFalse(list.isRevoked("b", NOW + 20));

		// Taken off by mistake's remedy.
		Assert.isTrue(list.remove("a"));
		Assert.isFalse(list.remove("a"));
		Assert.isFalse(list.isRevoked("a", NOW + 30));

		Assert.raises(() -> list.revoke(null, NOW, NOW), ArgumentError);
		Assert.raises(() -> list.revoke("x", Math.NaN, NOW), ArgumentError);
		Assert.raises(() -> list.revoke("x", Math.POSITIVE_INFINITY, NOW), ArgumentError);
		Assert.raises(() -> list.revoke("x", NOW, Math.NaN), ArgumentError);
		Assert.raises(() -> list.sweep(Math.NaN), ArgumentError);
		Assert.raises(() -> new JWTRevocationList(-1), ArgumentError);
		Assert.raises(() -> new JWTRevocationList(10, -1), ArgumentError);
	}

	public function testTheSweepDropsWhatHasPassedTheSoonestFirst():Void {
		final list = new JWTRevocationList(0, 0);
		// Revoked out of order, as tokens of several lifetimes are.
		final times:Array<Int> = [50, 10, 40, 20, 30, 60, 5];
		for (i in 0...times.length) {
			list.revoke("t" + times[i], NOW + times[i], NOW);
		}
		Assert.equals(7, list.length);
		Assert.equals(0, list.sweep(NOW + 5));
		Assert.equals(1, list.sweep(NOW + 6));
		Assert.equals(2, list.sweep(NOW + 21));
		Assert.isFalse(list.isRevoked("t10", NOW + 10));
		Assert.isFalse(list.isRevoked("t20", NOW + 20));
		Assert.isTrue(list.isRevoked("t30", NOW + 30));
		Assert.same([30.0, 40.0, 50.0, 60.0], [for (entry in list.entries()) entry.expiresAt - NOW]);

		// A revocation sweeps too.
		list.revoke("t100", NOW + 100, NOW + 45);
		Assert.same(["t50", "t60", "t100"], [for (entry in list.entries()) entry.tokenId]);
		Assert.equals(3, list.length);
	}

	public function testPastItsBoundTheListFailsClosed():Void {
		final list = new JWTRevocationList(3, 0);
		list.revoke("a", NOW + 100, NOW);
		list.revoke("b", NOW + 200, NOW);
		list.revoke("c", NOW + 300, NOW);
		// A fourth: the one expiring soonest, a, makes room.
		list.revoke("d", NOW + 400, NOW);
		Assert.equals(3, list.length, "the list grew past its bound");
		Assert.isFalse(Lambda.exists(list.entries(), entry -> entry.tokenId == "a"), "nothing made room");

		// a is still refused, and so is every token expiring no later than it,
		// revoked or not; one expiring later is not.
		Assert.isTrue(list.isRevoked("a", NOW + 100), "a revoked token was taken again once the list was full");
		Assert.isTrue(list.isRevoked("never-revoked", NOW + 90), "a full list did not fail closed");
		Assert.isFalse(list.isRevoked("never-revoked", NOW + 150), "a full list refused a token expiring after what it let go");
		// A token without a jti is never on the list.
		Assert.isFalse(list.isRevoked(null, NOW + 90));

		// Once that time has passed, so has the floor.
		list.sweep(NOW + 101);
		Assert.isFalse(list.isRevoked("never-revoked", NOW + 90));
		Assert.isTrue(list.isRevoked("b", NOW + 200));
	}

	public function testAStreamOfRevocationsStaysBounded():Void {
		final list = new JWTRevocationList(1000, 0);
		// Ten thousand revocations, each token living an hour, arriving a
		// second apart: never more than the bound held.
		var held:Int = 0;
		for (i in 0...10000) {
			list.revoke("t" + i, NOW + i + 3600, NOW + i);
			if (list.length > held) {
				held = list.length;
			}
		}
		Assert.equals(1000, held, "the list held more than its bound");
		// The newest are all refused, as is every token older than the oldest
		// it still holds; the newest's neighbours expiring after it are not.
		Assert.isTrue(list.isRevoked("t9999", NOW + 9999 + 3600));
		Assert.isTrue(list.isRevoked("t0", NOW + 3600));
		Assert.isTrue(list.isRevoked("t8999", NOW + 8999 + 3600), "a revoked token was taken again");
		Assert.isFalse(list.isRevoked("fresh", NOW + 10000 + 3600));
	}

	public function testOnlyATokenTheVerifierTakesIsListed():Void {
		final jwt:JWT = JWT.make(HS256([{secret: SECRET}]), "https://auth.example");
		jwt.revocations = new JWTRevocationList();
		final other:JWT = JWT.make(HS256([{secret: "fedcba9876543210fedcba9876543210"}]), "https://auth.example");

		// Signed by someone else, from another issuer, made up: none fills it.
		Assert.isFalse(jwt.revoke(other.generateToken({sub: "x", jti: "forged", exp: NOW + 600}), NOW));
		Assert.isFalse(jwt.revoke(jwt.generateToken({sub: "x", jti: "elsewhere", iss: "https://elsewhere.example", exp: NOW + 600}), NOW));
		Assert.isFalse(jwt.revoke("not.a.token", NOW));
		Assert.equals(0, jwt.revocations.length);

		// Without a jti, or an exp, there is nothing to list.
		Assert.isFalse(jwt.revoke(jwt.generateToken({sub: "x", iss: "https://auth.example", exp: NOW + 600}), NOW));
		Assert.isFalse(jwt.revoke(jwt.generateToken({sub: "x", jti: "no-exp", iss: "https://auth.example", exp: null}), NOW));
		// Past its time: refused as expired already.
		Assert.isFalse(jwt.revoke(jwt.generateToken({sub: "x", jti: "old", iss: "https://auth.example", exp: NOW - 600}), NOW));
		Assert.equals(0, jwt.revocations.length);

		// Revoked twice, it is listed once, and the second says so too.
		final token:String = jwt.generateToken({sub: "x", jti: "mine", iss: "https://auth.example", exp: NOW + 600});
		Assert.isTrue(jwt.revoke(token, NOW));
		Assert.isTrue(jwt.revoke(token, NOW));
		Assert.equals(1, jwt.revocations.length);
	}

	public function testRevokingNeedsAList():Void {
		final jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		final token:String = jwt.generateToken({sub: "x", jti: "j", exp: NOW + 600});
		Assert.raises(() -> jwt.revoke(token, NOW), IllegalOperationError);
		// And with none, nothing is consulted.
		Assert.isTrue(jwt.verify(token, NOW).valid);
		// A time of NaN, by which nothing would ever have passed, is refused.
		jwt.revocations = new JWTRevocationList();
		Assert.raises(() -> jwt.revoke(token, Math.NaN), ArgumentError);
		Assert.equals(0, jwt.revocations.length);
	}

	public function testAnEntryLastsAsLongAsTheVerifiersLeeway():Void {
		// A list kept 10 s past exp, given to a verifier forgiving 120: revoke
		// holds the entry for the verifier's.
		final jwt:JWT = JWT.make(HS256([{secret: SECRET}]), null, null, 120);
		jwt.revocations = new JWTRevocationList(100, 10);
		final token:String = jwt.generateToken({sub: "x", jti: "j", exp: NOW + 600});
		jwt.revoke(token, NOW);
		jwt.revocations.sweep(NOW + 700);
		Assert.equals(JWTRejection.REVOKED, jwt.verify(token, NOW + 700).rejection, "a revoked token was taken again within its verifier's leeway");
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(token, NOW + 721).rejection);
	}

	public function testVerifySignatureConsultsTheListToo():Void {
		final jwt:JWT = JWT.make(HS256([{secret: SECRET}]));
		jwt.revocations = new JWTRevocationList();
		final token:String = jwt.generateToken({sub: "x", jti: "j", exp: NOW + 600});
		Assert.isTrue(jwt.verifySignature(token).valid);
		jwt.revoke(token, NOW);
		Assert.equals(JWTRejection.REVOKED, jwt.verifySignature(token).rejection);
		// The list is checked last: a token failing another check says that one.
		Assert.equals(JWTRejection.EXPIRED, jwt.verify(token, NOW + 6000).rejection);
	}

	#if target.threaded
	/** As a `JWT` is, it is safe to use from several threads at once. **/
	public function testThreadsRevokingAndCheckingAtOnceLoseNothing():Void {
		final list = new JWTRevocationList(0, 0);
		final done = new sys.thread.Lock();
		final threads:Int = 4;
		final each:Int = 2000;
		// One slot a thread, each written by its own.
		final misses:Array<Int> = [for (_ in 0...threads) 0];
		for (t in 0...threads) {
			sys.thread.Thread.create(() -> {
				for (i in 0...each) {
					final id:String = 't$t-$i';
					list.revoke(id, NOW + 1000 + i, NOW);
					if (!list.isRevoked(id, NOW + 1000 + i)) {
						misses[t]++;
					}
				}
				done.release();
			});
		}
		for (_ in 0...threads) {
			done.wait();
		}
		Assert.equals(threads * each, list.length, "revocations made at once were lost");
		Assert.same([for (_ in 0...threads) 0], misses);
	}
	#end

	public function testWhatTheListHoldsCanBeKeptAndRestored():Void {
		final list = new JWTRevocationList(100, 30);
		list.revoke("a", NOW + 100, NOW);
		list.revoke("b", NOW + 50, NOW);
		final saved:Array<{tokenId:String, expiresAt:Float}> = list.entries();
		Assert.same(["b", "a"], [for (entry in saved) entry.tokenId]);
		Assert.same([NOW + 50, NOW + 100], [for (entry in saved) entry.expiresAt], "a snapshot did not keep each token's exp");

		final restored = new JWTRevocationList(100, 30);
		for (entry in saved) {
			restored.revoke(entry.tokenId, entry.expiresAt, NOW);
		}
		Assert.isTrue(restored.isRevoked("a", NOW + 100));
		Assert.isTrue(restored.isRevoked("b", NOW + 50));
		Assert.same(saved, restored.entries());

		list.clear();
		Assert.equals(0, list.length);
		Assert.isFalse(list.isRevoked("a", NOW + 100));
	}
}
