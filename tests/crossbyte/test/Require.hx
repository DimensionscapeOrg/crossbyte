package crossbyte.test;

import utest.Assert;

/**
	Assertions that stop the test when they fail.

	`utest`'s assertions record a result and carry on. That is right for most of
	them -- one wrong field should not hide the other nine -- but it is wrong for
	the assertion that a value arrived at all, because the lines after it read
	fields off that value. When the value is null they read fields off null, and
	on hxcpp release that is a SIGSEGV rather than a catchable error: the process
	dies, the surrounding try/catch never runs, and the run reports nothing at
	all about what went wrong.

	That is not hypothetical. It is what an intermittent segfault in this suite
	turned out to be: six sites where an async wait could time out, leaving

	    Assert.notNull(accepted, "...");
	    Assert.equals(Protocol.TCP, accepted.protocol);

	to dereference null on whichever run lost the race. Because the process died
	before reporting, the failure looked like heap corruption for a long time
	rather than like the timeout it was.

	`Require.notNull` records the same assertion `Assert.notNull` would, so
	counts and reports are unchanged on the passing path, and then throws so the
	test stops at the point the value was missing. utest turns that into an
	error naming this test, which is what the caller needed to be told.

	Use it wherever the next line dereferences the value. Where nothing is
	dereferenced, plain `Assert.notNull` is still the right call: there is
	nothing to protect, and stopping early would hide the assertions after it.
**/
class Require {
	/**
		Asserts the value is present, and stops the test if it is not.

		@return The value, non-null, so it can be bound if that reads better at
		the call site.
	**/
	public static function notNull<T>(value:Null<T>, ?message:String, ?pos:haxe.PosInfos):T {
		if (value == null) {
			// Thrown rather than returned, so the dereference below the call
			// site never happens. utest reports this as an error against the
			// test, and a `catch (e:Dynamic)` around the body turns it into a
			// failed assertion -- either way it is a report rather than a dead
			// process.
			//
			// Thrown *before* recording anything, so a missing value produces
			// one report rather than two. Asserting first logged a failure and
			// then raised an error for the same fact, which also made the
			// failure path impossible to test without the test itself failing.
			throw new RequirementFailed(message != null ? message : "expected a value, but it was null", pos);
		}

		// Recorded only on the way through, so a passing run counts exactly
		// what `Assert.notNull` would have counted.
		Assert.notNull(value, message, pos);
		return value;
	}
}

/**
	Why a `Require` stopped a test.

	Its own type rather than a bare string so a test that deliberately catches
	around the body can tell a missing value apart from whatever else it was
	expecting to catch.
**/
class RequirementFailed {
	public final message:String;
	public final pos:Null<haxe.PosInfos>;

	public function new(message:String, ?pos:haxe.PosInfos) {
		this.message = message;
		this.pos = pos;
	}

	public function toString():String {
		if (pos == null) {
			return message;
		}

		return message + " (" + pos.fileName + ":" + pos.lineNumber + ")";
	}
}
