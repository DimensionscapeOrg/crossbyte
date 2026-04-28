package crossbyte.errors;

import utest.Assert;

class ErrorsTest extends utest.Test {
	public function testBaseErrorDefaultsAndMessageOverride():Void {
		var err = new Error();
		Assert.equals("Error", err.name);
		Assert.equals(0, err.errorID);
		Assert.equals("Error", err.toString());
		Assert.notNull(err.getStackTrace());

		var withMessage = new Error("boom", 7);
		Assert.equals("boom", withMessage.toString());
		Assert.equals(7, withMessage.errorID);
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
