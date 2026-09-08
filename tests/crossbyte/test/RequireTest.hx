package crossbyte.test;

import crossbyte.test.Require.RequirementFailed;
import utest.Assert;

/**
	`Require`, which a hundred assertions in this suite now depend on.

	Worth its own test for one reason: if `Require.notNull` failed to throw,
	every one of those call sites would quietly go back to dereferencing null,
	and nothing would look wrong -- the suite would stay green right up until a
	timeout killed the process again. The mechanism has to be checked directly,
	because its failure mode is silence.
**/
class RequireTest extends utest.Test {
	/** The value comes back, so a call site can bind it. **/
	public function testAPresentValueIsReturnedUnchanged():Void {
		var subject = {name: "kept"};

		Assert.equals(subject, Require.notNull(subject));
		Assert.equals("kept", Require.notNull(subject).name);
		Assert.equals(0, Require.notNull(0));
		Assert.equals("", Require.notNull(""));
		Assert.isFalse(Require.notNull(false));
	}

	/**
		A missing value stops the test rather than being handed back.

		This is the whole point: the line after a `Require` reads a field off
		the value, and on hxcpp release reading a field off null is a SIGSEGV
		that no `catch` can see. Throwing turns that into something utest can
		report.
	**/
	public function testAMissingValueThrowsRatherThanReturningNull():Void {
		var absent:Null<{name:String}> = null;
		var threw:Bool = false;
		var reached:Bool = false;

		try {
			var value = Require.notNull(absent, "the thing never arrived");
			// Never runs. If it ever does, `Require` has stopped protecting
			// every call site that relies on it.
			reached = true;
			Assert.notNull(value);
		} catch (e:RequirementFailed) {
			threw = true;
			Assert.isTrue(e.toString().indexOf("the thing never arrived") >= 0,
				"the failure does not carry the caller's message: " + e.toString());
		}

		Assert.isTrue(threw, "Require.notNull returned instead of throwing");
		Assert.isFalse(reached, "execution continued past a failed Require");
	}

	/** Without a message it still says something useful. **/
	public function testTheDefaultMessageNamesTheProblem():Void {
		var absent:Null<String> = null;
		var reported:String = null;

		try {
			Require.notNull(absent);
		} catch (e:RequirementFailed) {
			reported = e.toString();
		}

		Assert.notNull(reported);
		Assert.isTrue(reported.indexOf("null") >= 0, "unhelpful message: " + reported);
	}
}
