package crossbyte.core;

import crossbyte.errors.ArgumentError;
import utest.Assert;

class ConfigTest extends utest.Test {
	public function testKeyNormalizationTreatsSeparatorsAndCaseAlike():Void {
		var config = new Config(["LOG_LEVEL" => "debug"]);

		Assert.equals("debug", config.getString("log.level"));
		Assert.equals("debug", config.getString("LOG-LEVEL"));
		Assert.equals("debug", config.getString("Log_Level"));
		Assert.isTrue(config.has("log.level"));
		Assert.isFalse(config.has("log.levels"));
	}

	public function testDefaultsDoNotOverrideExistingValues():Void {
		var config = new Config(["port" => "9000"]).withDefaults(["port" => "8080", "host" => "0.0.0.0"]);

		Assert.equals("9000", config.getString("port"));
		Assert.equals("0.0.0.0", config.getString("host"));
	}

	public function testLaterSourcesOverrideEarlierOnes():Void {
		var base = new Config(["a" => "1", "b" => "2"]);
		var overrides = new Config(["b" => "22", "c" => "3"]);
		base.withConfig(overrides);

		Assert.equals("1", base.getString("a"));
		Assert.equals("22", base.getString("b"));
		Assert.equals("3", base.getString("c"));
	}

	public function testTypedAccessorsConvertAndValidate():Void {
		var config = new Config([
			"port" => "8080",
			"ratio" => "0.25",
			"debug" => "yes",
			"quiet" => "0",
			"origins" => " a.com , b.com ,, c.com "
		]);

		Assert.equals(8080, config.getInt("port"));
		Assert.equals(0.25, config.getFloat("ratio"));
		Assert.isTrue(config.getBool("debug"));
		Assert.isFalse(config.getBool("quiet"));
		Assert.same(["a.com", "b.com", "c.com"], config.getList("origins"));
	}

	public function testFallbacksApplyOnlyWhenAbsent():Void {
		var config = new Config(["present" => "1"]);

		Assert.equals(1, config.getInt("present", 99));
		Assert.equals(99, config.getInt("absent", 99));
		Assert.equals("x", config.getString("absent", "x"));
		Assert.isTrue(config.getBool("absent", true));
		Assert.equals(1.5, config.getFloat("absent", 1.5));
		Assert.same(["d"], config.getList("absent", ["d"]));
		Assert.same([], config.getList("absent"));
		Assert.isNull(config.getInt("absent"));
		Assert.isNull(config.getString("absent"));
	}

	public function testMalformedValuesThrowRatherThanFallBack():Void {
		// A mistyped port must fail at startup, not silently become a
		// default and surprise the operator later.
		var config = new Config(["port" => "80a80", "flag" => "maybe", "ratio" => "abc"]);

		Assert.raises(() -> config.getInt("port"), ArgumentError);
		Assert.raises(() -> config.getInt("port", 8080), ArgumentError);
		Assert.raises(() -> config.getBool("flag"), ArgumentError);
		Assert.raises(() -> config.getFloat("ratio"), ArgumentError);

		// Trailing garbage must not be truncated into a plausible value.
		var trailing = new Config(["port" => "8080; rm -rf", "ratio" => "1.5abc"]);
		Assert.raises(() -> trailing.getInt("port"), ArgumentError);
		Assert.raises(() -> trailing.getFloat("ratio"), ArgumentError);
	}

	public function testWellFormedNumericFormsAreAccepted():Void {
		var config = new Config([
			"negative" => "-5",
			"positive" => "+7",
			"hex" => "0x1F",
			"padded" => "  42  ",
			"exponent" => "1.5e3",
			"leadingDot" => ".5",
			"trailingDot" => "2."
		]);

		Assert.equals(-5, config.getInt("negative"));
		Assert.equals(7, config.getInt("positive"));
		Assert.equals(31, config.getInt("hex"));
		Assert.equals(42, config.getInt("padded"));
		Assert.equals(1500.0, config.getFloat("exponent"));
		Assert.equals(0.5, config.getFloat("leadingDot"));
		Assert.equals(2.0, config.getFloat("trailingDot"));
	}

	public function testRequireRejectsMissingAndBlankValues():Void {
		var config = new Config(["secret" => "s3cr3t", "blank" => "   "]);

		Assert.equals("s3cr3t", config.require("secret"));
		Assert.raises(() -> config.require("absent"), ArgumentError);
		Assert.raises(() -> config.require("blank"), ArgumentError);
	}

	public function testFileSourceParsesCommentsQuotesAndOverrides():Void {
		var path:String = __writeTempFile([
			"# a comment",
			"; another comment",
			"",
			"port = 8080",
			"log.level=debug",
			'greeting = "  hello world  "',
			"empty=",
			"url=http://example.com/?a=b"
		]);

		var config = new Config(["port" => "1"]).withFile(path);

		Assert.equals(8080, config.getInt("port"));
		Assert.equals("debug", config.getString("log.level"));
		Assert.equals("  hello world  ", config.getString("greeting"));
		Assert.equals("", config.getString("empty"));
		// Only the first '=' separates key from value.
		Assert.equals("http://example.com/?a=b", config.getString("url"));

		sys.FileSystem.deleteFile(path);
	}

	public function testMissingFileIsFatalUnlessOptional():Void {
		var missing:String = haxe.io.Path.join([__tempDirectory(), "crossbyte-config-does-not-exist.conf"]);

		Assert.raises(() -> new Config().withFile(missing), ArgumentError);

		var config = new Config(["a" => "1"]).withFile(missing, true);
		Assert.equals("1", config.getString("a"));
	}

	public function testMalformedFileLineReportsFailure():Void {
		var path:String = __writeTempFile(["port = 8080", "this line has no separator"]);

		Assert.raises(() -> new Config().withFile(path), ArgumentError);

		sys.FileSystem.deleteFile(path);
	}

	public function testEnvironmentSourceStripsPrefix():Void {
		// PATH exists on every supported platform, so this asserts the
		// mechanism without depending on a fixture variable.
		var config = new Config().withEnvironment();
		Assert.isTrue(config.has("path") || config.has("PATH"));

		var prefixed = new Config().withEnvironment("CROSSBYTE_ABSENT_PREFIX_");
		Assert.equals(0, prefixed.keys().length);
	}

	private function __tempDirectory():String {
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}

	private static var __fixtureCounter:Int = 0;

	private function __writeTempFile(lines:Array<String>):String {
		// Unique per fixture so concurrent test processes cannot delete or
		// overwrite each other's file.
		__fixtureCounter++;
		var unique:String = Std.string(Std.int(Sys.time() * 1000)) + "-" + Std.string(__fixtureCounter);
		var path:String = haxe.io.Path.join([__tempDirectory(), 'crossbyte-config-test-$unique.conf']);
		sys.io.File.saveContent(path, lines.join("\n"));
		return path;
	}
}
