package crossbyte.db;

import crossbyte.db.mongodb.MongoConfig;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.db.mysql.IsolationLevel;
import crossbyte.db.postgres.PostgresIsolationLevel;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
 * Pure, DB-free coverage of the named-parameter substitution helper, the
 * isolation-level whitelist, and Mongo URI userinfo encoding. None of these
 * paths require a live database, so they run under `haxe --interp`.
 */
@:access(crossbyte.db.mongodb.MongoConnection)
class DBParameterBindingTest extends utest.Test {
	// Stub escape that wraps the value in markers so we can prove the value was
	// routed THROUGH escape rather than spliced in raw.
	private static function wrapEscape(value:Dynamic):String {
		return "<<" + Std.string(value) + ">>";
	}

	private static function lookupOf(map:Map<String, String>):String->Null<Dynamic> {
		return function(name:String):Null<Dynamic> {
			return map.exists(name) ? map.get(name) : null;
		};
	}

	public function testNamedParameterIsReplaced():Void {
		var lookup = lookupOf(["name" => "alpha"]);
		var result = ParamBinder.substitute("SELECT * FROM t WHERE n = :name", lookup, wrapEscape);
		Assert.equals("SELECT * FROM t WHERE n = <<alpha>>", result);
	}

	public function testTokenIsMatchedWholeNotByPrefix():Void {
		// `:user` must NOT match the `:user` prefix of `:username`.
		var lookup = lookupOf(["user" => "U", "username" => "N"]);
		var result = ParamBinder.substitute("a=:user b=:username", lookup, wrapEscape);
		Assert.equals("a=<<U>> b=<<N>>", result);

		// And a lone `:user` does not consume a following `name` run.
		var lookup2 = lookupOf(["user" => "U"]);
		var result2 = ParamBinder.substitute(":username", lookup2, wrapEscape);
		// `:username` has no value -> left verbatim, `:user` must not partial-match.
		Assert.equals(":username", result2);
	}

	public function testPlaceholderInsideStringLiteralIsUntouched():Void {
		var lookup = lookupOf(["name" => "alpha"]);
		// The `:name` inside the quoted literal must stay literal; the one outside
		// is substituted.
		var result = ParamBinder.substitute("WHERE label = ':name' AND n = :name", lookup, wrapEscape);
		Assert.equals("WHERE label = ':name' AND n = <<alpha>>", result);
	}

	public function testEscapedQuoteInLiteralIsHonored():Void {
		var lookup = lookupOf(["name" => "alpha"]);
		// `''` is an escaped quote inside the literal, so the string does not end
		// there and the `:name` after it is still inside the literal.
		var result = ParamBinder.substitute("x = 'it''s :name' AND y = :name", lookup, wrapEscape);
		Assert.equals("x = 'it''s :name' AND y = <<alpha>>", result);
	}

	public function testInjectionValueIsRoutedThroughEscape():Void {
		// A value that itself looks like SQL must be handed to escape(), not
		// spliced raw into the output.
		var malicious = "x'; DROP TABLE users; --";
		var lookup = lookupOf(["name" => malicious]);
		var result = ParamBinder.substitute("DELETE FROM t WHERE n = :name", lookup, wrapEscape);

		// The escaped form is present...
		Assert.equals("DELETE FROM t WHERE n = <<" + malicious + ">>", result);
		// ...and the raw payload was never spliced in unescaped.
		Assert.equals(-1, result.indexOf("= " + malicious));
	}

	public function testUnknownPlaceholderIsLeftVerbatim():Void {
		var lookup = lookupOf(["known" => "K"]);
		var result = ParamBinder.substitute("a=:known b=:missing", lookup, wrapEscape);
		Assert.equals("a=<<K>> b=:missing", result);
	}

	public function testPlaceholderInALineCommentIsUntouched():Void {
		// The sharpest case, and the reason the scanner tracks comments at all.
		// Quoting means nothing inside a comment: escape() can wrap a value
		// perfectly and it still ends the comment at its first newline, putting
		// everything after it back into statement text. Measured before the
		// scanner knew about comments, "-- audit :note" with a newline in the
		// value produced a second line the server executed.
		var params = lookupOf(["note" => "x" + String.fromCharCode(10) + "OR 1=1 --"]);
		var sql = "SELECT * FROM t" + String.fromCharCode(10) + "-- audit :note" + String.fromCharCode(10) + "WHERE id = 1";

		var result = ParamBinder.substitute(sql, params, wrapEscape);

		Assert.equals(sql, result);
		Assert.isFalse(result.indexOf("<<") >= 0);
	}

	public function testPlaceholderInABlockCommentIsUntouched():Void {
		var params = lookupOf(["id" => "7"]);
		var sql = "SELECT 1 /* filter :id */ FROM t WHERE x = :id";

		var result = ParamBinder.substitute(sql, params, wrapEscape);

		Assert.equals("SELECT 1 /* filter :id */ FROM t WHERE x = <<7>>", result);
	}

	public function testNestedBlockCommentDoesNotEndEarly():Void {
		// Postgres nests block comments. Ending at the first close would drop
		// the scanner back into statement context while the server is still
		// inside the comment.
		var params = lookupOf(["id" => "7"]);
		var sql = "SELECT 1 /* outer /* inner :id */ still :id */ WHERE x = :id";

		var result = ParamBinder.substitute(sql, params, wrapEscape);

		Assert.equals("SELECT 1 /* outer /* inner :id */ still :id */ WHERE x = <<7>>", result);
	}

	public function testPlaceholderInAQuotedIdentifierIsUntouched():Void {
		// "..." is an identifier in Postgres and SQLite and a string in MySQL's
		// default mode; backticks are MySQL identifiers. It is not statement
		// text under any of them, so nothing is substituted there.
		var params = lookupOf(["id" => "7"]);

		Assert.equals('SELECT "col:id" FROM t WHERE x = <<7>>', ParamBinder.substitute('SELECT "col:id" FROM t WHERE x = :id', params, wrapEscape));

		var tick = String.fromCharCode(96);
		Assert.equals("SELECT " + tick + "col:id" + tick + " FROM t WHERE x = <<7>>",
			ParamBinder.substitute("SELECT " + tick + "col:id" + tick + " FROM t WHERE x = :id", params, wrapEscape));
	}

	public function testDoubledQuoteInsideAnIdentifierDoesNotEndIt():Void {
		// The same doubling rule the single-quote path already honoured; an
		// identifier that ends early would drop the scanner into statement
		// context inside a name.
		var params = lookupOf(["id" => "7"]);
		var sql = 'SELECT "we""ird:id" FROM t WHERE x = :id';

		Assert.equals('SELECT "we""ird:id" FROM t WHERE x = <<7>>', ParamBinder.substitute(sql, params, wrapEscape));
	}

	public function testIsolationWhitelistAcceptsCanonicalValues():Void {
		Assert.equals("READ COMMITTED", IsolationLevel.ofString("read committed"));
		Assert.equals("SERIALIZABLE", IsolationLevel.ofString("SERIALIZABLE"));
		// Server-reported form with a hyphen still normalizes.
		Assert.equals("REPEATABLE READ", IsolationLevel.ofString("REPEATABLE-READ"));
		Assert.equals("READ COMMITTED", PostgresIsolationLevel.ofString("read committed"));
	}

	public function testIsolationWhitelistRejectsUnknownString():Void {
		Assert.raises(() -> IsolationLevel.ofString("SERIALIZABLE; DROP TABLE users"), ArgumentError);
		Assert.raises(() -> PostgresIsolationLevel.ofString("garbage"), ArgumentError);
	}

	public function testMongoUriPercentEncodesUserinfo():Void {
		var connection = new MongoConnection();
		var cfg:MongoConfig = {
			host: "db.example.com",
			port: 27017,
			username: "ad@min",
			password: "p@ss:w/rd"
		};
		var uri = connection.__buildUri(cfg);

		// Reserved characters in the userinfo are percent-encoded so they cannot
		// break out of the userinfo segment.
		Assert.isTrue(uri.indexOf("ad%40min") != -1);
		Assert.isTrue(uri.indexOf("p%40ss%3Aw%2Frd") != -1);
		// The authority remains the configured host, not anything smuggled in via
		// the password's `@`.
		Assert.isTrue(uri.indexOf("@db.example.com:27017") != -1);
		Assert.equals(-1, uri.indexOf("p@ss"));
	}
}
