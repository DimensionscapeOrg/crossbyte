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
		// the value came from CallStack.exceptionStack(), global state, and
		// not from the error at all.
		Assert.equals(atConstruction, never.getCallStack());
		Assert.isFalse(__names(never.getCallStack(), "__throwFromHere", __throwLine),
			"an unrelated exception leaked into this error's stack");

		// How much stack a build records is the build's business: a release cpp
		// build has none without -D HXCPP_STACK_TRACE, and there every stack
		// here is legitimately empty. Where there are frames at all, check that
		// each error names its own site.
		if (atThrow.length > 0 && __recordsTheMakingFrame()) {
			Assert.isTrue(__names(atThrow, "__throwFromHere", __throwLine),
				"expected the throw site in the stack, got: " + atThrow);
			// Never thrown, and it still knows where it was made. This was
			// empty before, for every error, until one was thrown and caught.
			Assert.isTrue(__names(atConstruction, "__makeUnthrownError", __constructionLine),
				"expected the construction site in the stack, got: " + atConstruction);
		}
	}

	// The lines the two errors below are made on, as the frames of a target
	// that records no method names give them.
	private var __constructionLine:Int = -1;
	private var __throwLine:Int = -1;

	private function __makeUnthrownError():Error {
		__constructionLine = __nextLine();
		return new Error("never thrown", 1);
	}

	private function __throwFromHere():Void {
		__throwLine = __nextLine();
		throw new Error("thrown", 2);
	}

	private static function __nextLine(?pos:haxe.PosInfos):Int {
		return pos.lineNumber + 1;
	}

	/**
		Whether this runtime puts the frame that makes an exception in its
		stack. The HashLink 1.14.0 release CI used to install leaves it out of every
		`haxe.Exception`'s, CrossByte's or not, so there no error can name its
		own site; other builds of the same version keep it.
	**/
	private static function __recordsTheMakingFrame():Bool {
		#if hl
		return __makeProbe().stack.toString().indexOf("__makeProbe") >= 0;
		#else
		return true;
		#end
	}

	#if hl
	private static function __makeProbe():haxe.Exception {
		return new haxe.Exception("probe");
	}
	#end

	/**
		Whether `stack` names a site: by its method, or where frames carry no
		method name, neko's are a file and a line, since its bytecode keeps
		no more, by its line in this file.
	**/
	private static function __names(stack:String, method:String, line:Int):Bool {
		return stack.indexOf(method) >= 0 || new EReg("ErrorsTest\\.hx line " + line + "\\b", "").match(stack);
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
