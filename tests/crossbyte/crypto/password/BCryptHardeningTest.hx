package crossbyte.crypto.password;

import crossbyte.crypto.password.BCrypt;
import utest.Assert;

/**
 * Hardening coverage for BCrypt: default cost factor, rehash signalling, and
 * empty-password rejection.
 *
 * Real `BCrypt.hash` calls require a CSPRNG salt from `SecureRandom`, which only
 * works on native targets, so the round-trip and default-cost-parsing assertions
 * are gated behind `#if cpp`. The pure string-parsing paths (`needsRehash`) and
 * the empty-password guards run on every target, including eval/interp.
 */
class BCryptHardeningTest extends utest.Test {
	// Canonical 60-char bcrypt strings of the form $2y$NN$<22 salt><31 hash>.
	static inline var COST_10_HASH:String = "$2y$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy";
	static inline var COST_12_HASH:String = "$2y$12$R9h/cIPz0gi.URNNX3kh2OPST9/PgBkqquzi.Ss7KIUgO2t0jWMUW";

	public function testNeedsRehashTracksCostFactor():Void {
		// A cost-10 hash should be flagged for rehash against the new default cost 12.
		Assert.isTrue(BCrypt.needsRehash(COST_10_HASH));
		Assert.isTrue(BCrypt.needsRehash(COST_10_HASH, 12));
		// A cost-12 hash already matches the default; no rehash needed.
		Assert.isFalse(BCrypt.needsRehash(COST_12_HASH));
		Assert.isFalse(BCrypt.needsRehash(COST_12_HASH, 12));
		// Targeting a different explicit cost still signals a rehash.
		Assert.isTrue(BCrypt.needsRehash(COST_12_HASH, 10));
	}

	public function testEmptyPasswordIsRejected():Void {
		// hash() throws on an empty/null password before touching the CSPRNG,
		// so this is exercisable on every target.
		Assert.raises(() -> BCrypt.hash(""), String);
		Assert.raises(() -> BCrypt.hash(null), String);

		// verify() never matches an empty/null password and returns false.
		Assert.isFalse(BCrypt.verify("", COST_12_HASH));
		Assert.isFalse(BCrypt.verify(null, COST_12_HASH));
	}

	public function testDefaultCostIsTwelveAndRoundTrips():Void {
		#if cpp
		// No explicit cost: the default must now be 12. Parse the cost out of the
		// $2y$NN$ prefix rather than trusting the constant.
		var defaultHash:String = BCrypt.hash("hunter2");
		Assert.equals("$2y$12$", defaultHash.substr(0, 7));
		var cost:Null<Int> = Std.parseInt(defaultHash.substr(4, 2));
		Assert.equals(12, cost);
		Assert.isFalse(BCrypt.needsRehash(defaultHash));

		// Round-trip verification against a freshly generated default-cost hash.
		Assert.isTrue(BCrypt.verify("hunter2", defaultHash));
		Assert.isFalse(BCrypt.verify("wrong-password", defaultHash));

		// Exercise a low explicit cost cheaply to confirm rehash signalling end to end.
		var cheapHash:String = BCrypt.hash("hunter2", 4);
		Assert.isTrue(BCrypt.verify("hunter2", cheapHash));
		Assert.isFalse(BCrypt.needsRehash(cheapHash, 4));
		Assert.isTrue(BCrypt.needsRehash(cheapHash, 12));
		#else
		// On non-native targets BCrypt.hash cannot run (no CSPRNG), but the cost
		// parsing the production default relies on is still verifiable here.
		Assert.equals("12", COST_12_HASH.substr(4, 2));
		Assert.isFalse(BCrypt.needsRehash(COST_12_HASH));
		#end
	}
}
