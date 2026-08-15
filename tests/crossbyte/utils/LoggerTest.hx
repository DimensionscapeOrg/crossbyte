package crossbyte.utils;

import utest.Assert;

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
		Logger.level = LogLevel.INFO;
		Logger.json = false;
		Logger.timestamps = false;
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
		Assert.isTrue(~/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} \[INFO\] stamped$/.match(captured[0]));
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
