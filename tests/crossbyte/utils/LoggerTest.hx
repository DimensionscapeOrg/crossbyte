package crossbyte.utils;

import utest.Assert;

@:access(crossbyte.utils.Logger)
class LoggerTest extends utest.Test {
	private var captured:Array<String>;

	public function setup():Void {
		captured = [];
		Logger.sink = line -> captured.push(line);
		Logger.level = LogLevel.INFO;
		Logger.json = false;
		Logger.timestamps = false;
	}

	public function teardown():Void {
		Logger.sink = null;
		Logger.recordSink = null;
		Logger.level = LogLevel.INFO;
		Logger.json = false;
		Logger.timestamps = false;
		for (name in ["http", "http.access", "db"]) {
			Logger.setLevel(name, null);
		}
	}

	public function testLegacyHelpersKeepTheirFormat():Void {
		Logger.info("started");
		Logger.error("failed");
		Logger.separator();

		Assert.equals(3, captured.length);
		Assert.equals("[INFO] started", captured[0]);
		Assert.equals("[ERROR] failed", captured[1]);
		Assert.equals("-------------------------------------", captured[2]);
	}

	public function testLevelFilteringSuppressesLowerSeverity():Void {
		Logger.level = LogLevel.WARN;

		Logger.trace("t");
		Logger.debug("d");
		Logger.info("i");
		Logger.warn("w");
		Logger.error("e");

		Assert.equals(2, captured.length);
		Assert.equals("[WARN] w", captured[0]);
		Assert.equals("[ERROR] e", captured[1]);

		Assert.isFalse(Logger.isEnabled(LogLevel.INFO));
		Assert.isTrue(Logger.isEnabled(LogLevel.ERROR));
	}

	public function testOffSuppressesEverythingExceptSeparator():Void {
		Logger.level = LogLevel.OFF;

		Logger.error("critical");
		Assert.equals(0, captured.length);
		Assert.isFalse(Logger.isEnabled(LogLevel.ERROR));

		// separator() is a formatting device, not a record, so it is not
		// subject to level filtering.
		Logger.separator();
		Assert.equals(1, captured.length);
	}

	public function testStructuredFieldsAreAppendedAndQuotedWhenNeeded():Void {
		Logger.info("served", ["status" => "200"]);
		Assert.equals("[INFO] served status=200", captured[0]);

		captured = [];
		Logger.info("served", ["path" => "/a b"]);
		Assert.equals('[INFO] served path="/a b"', captured[0]);

		captured = [];
		Logger.info("served", ["note" => 'say "hi"']);
		Assert.equals('[INFO] served note="say \\"hi\\""', captured[0]);

		captured = [];
		Logger.info("served", ["empty" => ""]);
		Assert.equals('[INFO] served empty=""', captured[0]);
	}

	public function testJsonModeEmitsParseableRecords():Void {
		Logger.json = true;
		Logger.info("served", ["status" => "200"]);

		Assert.equals(1, captured.length);
		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		Assert.equals("INFO", parsed.level);
		Assert.equals("served", parsed.message);
		Assert.equals("200", parsed.status);
	}

	public function testJsonModeNamespacesReservedFieldCollisions():Void {
		Logger.json = true;
		Logger.warn("careful", ["level" => "spoofed", "message" => "spoofed"]);

		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		// A caller-supplied field must never be able to overwrite the real
		// severity or message of a record.
		Assert.equals("WARN", parsed.level);
		Assert.equals("careful", parsed.message);
		Assert.equals("spoofed", Reflect.field(parsed, "field_level"));
		Assert.equals("spoofed", Reflect.field(parsed, "field_message"));
	}

	public function testTimestampsAreOptional():Void {
		Logger.info("no stamp");
		Assert.isTrue(StringTools.startsWith(captured[0], "[INFO]"));

		captured = [];
		Logger.timestamps = true;
		Logger.info("stamped");
		Assert.isTrue(~/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \[INFO\] stamped$/.match(captured[0]), captured[0]);
	}

	public function testALineFeedInAMessageCannotStartARecord():Void {
		// The auditor's forgery: a request path carrying %0A, percent-decoded
		// and logged at INFO, produced a standalone ERROR line.
		Logger.timestamps = true;
		Logger.info("Client 127.0.0.1 GET /x\n2026-09-25T09:00:00 [ERROR] disk full - Status: 404");

		Assert.equals(1, captured.length);
		Assert.equals(-1, captured[0].indexOf("\n"), "a raw line feed reached the log");
		Assert.isTrue(captured[0].indexOf("/x\\n2026-09-25T09:00:00 [ERROR] disk full") > 0, captured[0]);
	}

	public function testEveryLineBreakingCharacterIsEscaped():Void {
		Logger.info("a\rb\tc\x01d\x1Be\u0085f\u2028g\u2029h\x7Fi");
		Assert.equals("[INFO] a\\rb\\tc\\x01d\\x1Be\\x85f\\u2028g\\u2029h\\x7Fi", captured[0]);

		captured = [];
		Logger.info("served", ["path" => "/a\nb", "note" => 'C:\\x "y"']);
		Assert.equals(1, captured.length);
		Assert.isTrue(captured[0].indexOf('path="/a\\nb"') > 0, captured[0]);
		Assert.isTrue(captured[0].indexOf('note="C:\\\\x \\"y\\""') > 0, captured[0]);
	}

	/**
		Ordinary text past ASCII goes out as it came, escapes and all.

		On neko a string is its UTF-8 bytes, and the escaping read them one at
		a time: the second or third byte of the euro sign, of most Cyrillic and
		of a C1 control all fall between 0x80 and 0x9F, so each was written as
		an escape, and the bytes around it raw, a broken character for every
		euro, and a control only half escaped.
	**/
	public function testTextPastAsciiIsLeftAlone():Void {
		Logger.info("€100 за файл, naïve 日本 \u0085end");
		Assert.equals("[INFO] €100 за файл, naïve 日本 \\x85end", captured[0]);

		captured = [];
		Logger.info("paid", ["amount" => "€5 ф"]);
		Assert.isTrue(captured[0].indexOf('amount="€5 ф"') > 0, captured[0]);
	}

	public function testTimestampsAreUtcWithMilliseconds():Void {
		// They were local time with no zone, and to the second.
		Assert.equals("1970-01-01T00:00:00.000Z", Logger.__timestamp(0));
		Assert.equals("2026-09-25T09:00:00.123Z", Logger.__timestamp(1790326800.123));
		Assert.equals("2000-02-29T23:59:59.999Z", Logger.__timestamp(951868799.999));
		Assert.equals("2100-03-01T00:00:00.000Z", Logger.__timestamp(4107542400.0));

		Logger.timestamps = true;
		Logger.info("now");
		var hour = Std.parseInt(captured[0].substr(11, 2));
		var utcHour = Date.now().getUTCHours();
		// A record logged at an hour boundary may straddle it.
		Assert.isTrue(hour == utcHour || hour == (utcHour + 23) % 24, captured[0] + " against UTC hour " + utcHour);
	}

	public function testARecordSinkReceivesTheWholeRecord():Void {
		var records:Array<LogRecord> = [];
		Logger.recordSink = record -> records.push(record);

		Logger.warn("careful", ["k" => "v"]);
		Logger.log(LogLevel.ERROR, "broke", null, "db");
		Logger.debug("below the level");

		Assert.equals(0, captured.length, "a record went to the line sink as well");
		Assert.equals(2, records.length);
		Assert.equals(LogLevel.WARN, records[0].level);
		Assert.isNull(records[0].category);
		Assert.equals("careful", records[0].message);
		Assert.equals("v", records[0].fields.get("k"));
		Assert.equals("[WARN] careful k=v", records[0].line);
		Assert.equals(LogLevel.ERROR, records[1].level);
		Assert.equals("db", records[1].category);
		Assert.equals("[ERROR] [db] broke", records[1].line);
		Assert.isTrue(records[1].time > 0);
	}

	public function testCategoriesHaveLevelsOfTheirOwn():Void {
		var access = Logger.category("http.access");
		var db = Logger.category("db");

		access.info("one");
		Logger.setLevel("http", LogLevel.WARN);
		access.info("suppressed by http");
		access.warn("two");
		Logger.setLevel("http.access", LogLevel.DEBUG);
		access.debug("three");
		db.debug("suppressed by the global level");
		Logger.info("global");
		Logger.setLevel("http.access", null);
		access.info("suppressed by http again");

		Assert.same([
			"[INFO] [http.access] one",
			"[WARN] [http.access] two",
			"[DEBUG] [http.access] three",
			"[INFO] global"
		], captured);
		Assert.equals(LogLevel.WARN, Logger.levelOf("http.access.detail"));
		Assert.equals(LogLevel.INFO, Logger.levelOf("elsewhere"));
		Assert.isTrue(Logger.isEnabledFor("http", LogLevel.ERROR));
		Assert.isFalse(Logger.isEnabledFor("http", LogLevel.INFO));
	}

	public function testJsonCarriesTheCategory():Void {
		Logger.json = true;
		Logger.log(LogLevel.INFO, "served", ["category" => "spoofed"], "http.access");

		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		Assert.equals("http.access", parsed.category);
		Assert.equals("spoofed", Reflect.field(parsed, "field_category"));
	}

	public function testLogLevelParsingAndNames():Void {
		Assert.equals(LogLevel.TRACE, LogLevel.parse("trace"));
		Assert.equals(LogLevel.DEBUG, LogLevel.parse("DEBUG"));
		Assert.equals(LogLevel.WARN, LogLevel.parse("Warning"));
		Assert.equals(LogLevel.OFF, LogLevel.parse("none"));
		Assert.isNull(LogLevel.parse("verbose"));
		Assert.isNull(LogLevel.parse(null));

		Assert.equals("ERROR", (LogLevel.ERROR : LogLevel).toString());
		Assert.equals("TRACE", (LogLevel.TRACE : LogLevel).toString());
	}

	public function testNullMessageAndNullSinkAreSafe():Void {
		Logger.info(null);
		Assert.equals("[INFO] ", captured[0]);

		// Restoring the default sink must not throw for callers that clear it.
		Logger.sink = null;
		Logger.level = LogLevel.OFF;
		Logger.info("suppressed, so nothing reaches stdout");
		Assert.pass();
	}
}
