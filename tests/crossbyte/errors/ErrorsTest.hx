package crossbyte.errors;

import utest.Assert;

class ErrorsTest extends utest.Test {
	public function testBaseErrorDefaultsAndMessageOverride():Void {
		var err = new Error();
		Assert.equals("Error", err.name);
		Assert.equals(0, err.errorID);
		Assert.equals("Error", err.toString());

		var withMessage = new Error("boom", 7);
		Assert.equals("boom", withMessage.toString());
		Assert.equals(7, withMessage.errorID);
	}

	public function testAnErrorCarriesItsOwnCallStack():Void {
		// Constructed in a named function so the frame has something to say.
		var never = __makeUnthrownError();
		var atConstruction = never.getCallStack();
		Assert.notNull(atConstruction);

		var atThrow = "";
		try {
			__throwFromHere();
			Assert.fail("__throwFromHere did not throw");
		} catch (thrown:Error) {
			atThrow = thrown.getCallStack();
		}

		// The error's stack is its own. Reading it after an unrelated exception
		// has been caught used to hand back *that* exception's stack, because
		// the value came from CallStack.exceptionStack() -- global state -- and
		// not from the error at all.
		Assert.equals(atConstruction, never.getCallStack());
		Assert.isTrue(never.getCallStack().indexOf("__throwFromHere") < 0,
			"an unrelated exception leaked into this error's stack");

		// How much stack a build records is the build's business: a release cpp
		// build has none without -D HXCPP_STACK_TRACE, and there every stack
		// here is legitimately empty. Where there are frames at all, check that
		// each error names its own site.
		if (atThrow.length > 0) {
			Assert.isTrue(atThrow.indexOf("__throwFromHere") >= 0,
				"expected the throw site in the stack, got: " + atThrow);
			// Never thrown, and it still knows where it was made. This was
			// empty before, for every error, until one was thrown and caught.
			Assert.isTrue(atConstruction.indexOf("__makeUnthrownError") >= 0,
				"expected the construction site in the stack, got: " + atConstruction);
		}
	}

	private function __makeUnthrownError():Error {
		return new Error("never thrown", 1);
	}

	private function __throwFromHere():Void {
		throw new Error("thrown", 2);
	}

	public function testNamedErrorSubclassesPreserveIdentity():Void {
		var argument = new ArgumentError();
		var range = new RangeError();
		var security = new SecurityError();
		var illegal = new IllegalOperationError();
		var io = new IOError();

		Assert.equals("ArgumentError", argument.name);
		Assert.equals("ArgumentError", argument.toString());
		Assert.equals("RangeError", range.name);
		Assert.equals("RangeError", range.toString());
		Assert.equals("SecurityError", security.name);
		Assert.equals("SecurityError", security.toString());
		Assert.equals("IllegalOperationError", illegal.name);
		Assert.equals("IllegalOperationError", illegal.toString());
		Assert.equals("IOError", io.name);
		Assert.equals("IOError", io.toString());
	}

	public function testEOFErrorUsesFixedFlashStyleSemantics():Void {
		var eof = new EOFError("ignored", 99);
		Assert.equals("EOFError", eof.name);
		Assert.equals(2030, eof.errorID);
		Assert.equals("End of file was encountered", eof.message);
		Assert.equals("End of file was encountered", eof.toString());
	}

	public function testSQLErrorExposesMetadataAndDetails():Void {
		var sql = new SQLError("execute", "constraint failed", "Database exploded", 42, 9, ["users", "email"]);

		Assert.equals("SQLError", sql.name);
		Assert.equals("execute", sql.operation);
		Assert.equals(9, sql.detailID);
		Assert.same(["users", "email"], sql.detailArguments);
		Assert.equals("constraint failed", sql.details());
		Assert.equals("Database exploded", sql.toString());
	}
}
