package crossbyte.core;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	`ConfigTree`: JSON in, layers merged, environment variables reaching nested
	and camelCase keys, strict typed reads. Runs everywhere; the cases that
	read files or the process's environment are left out of a browser.
**/
class ConfigTreeTest extends utest.Test {
	static inline var DOCUMENT:String = '{"realm": {"this": {"id": "eu-1", "port": 7000, "endpoints": [{"host": "a.example", "port": 7001}, {"host": "b.example", "publicPort": 7002}]}},'
		+ ' "auth": {"token": {"maxAge": 3600, "keys": [{"kid": "2026-09", "publicKey": "AAA"}, {"kid": "2026-10", "publicKey": "BBB"}]}},'
		+ ' "flags": {"debug": true, "ratio": 0.25, "big": 1e300, "none": null}, "tags": ["red", 2, false]}';

	public function testValuesAreReadByPath():Void {
		var config = ConfigTree.fromJson(DOCUMENT);

		Assert.equals("eu-1", config.getString("realm.this.id"));
		Assert.equals(7000, config.getInt("realm.this.port"));
		Assert.equals("a.example", config.getString("realm.this.endpoints[0].host"));
		Assert.equals("b.example", config.getString("realm.this.endpoints.1.host"));
		Assert.equals(7002, config.getInt("realm.this.endpoints[1].publicPort"));
		Assert.equals(true, config.getBool("flags.debug"));
		Assert.equals(0.25, config.getFloat("flags.ratio"));
		Assert.equals("BBB", config.getString("auth.token.keys[1].publicKey"));
	}

	public function testMissingValuesAndNullGiveTheFallback():Void {
		var config = ConfigTree.fromJson(DOCUMENT);

		Assert.equals(8080, config.getInt("server.port", 8080));
		Assert.isNull(config.getInt("server.port"));
		Assert.equals("x", config.getString("flags.none", "x"));
		Assert.isFalse(config.has("flags.none"));
		Assert.isTrue(config.has("flags.debug"));
		Assert.isFalse(config.has("realm.this.endpoints[5]"));
		Assert.isNull(config.get("realm.this.endpoints[5].host"));
		// Through a value: nothing there, not an error.
		Assert.isNull(config.getString("realm.this.id.more"));
	}

	public function testTypedReadsAreStrict():Void {
		var config = ConfigTree.fromJson('{"port": "80a80", "fraction": 80.5, "huge": 4294967296, "text": "80", "hex": "0x1F",'
			+ ' "word": "yes", "one": 1, "two": 2, "obj": {"a": 1}, "list": [1], "neg": "-2147483648", "spaced": " 42 "}');

		// "80a80" is not 80, as Std.parseInt would read it.
		Assert.raises(() -> config.getInt("port"), ArgumentError);
		Assert.raises(() -> config.getInt("fraction"), ArgumentError);
		Assert.raises(() -> config.getInt("huge"), ArgumentError);
		Assert.raises(() -> config.getInt("obj"), ArgumentError);
		Assert.raises(() -> config.getInt("word"), ArgumentError);
		Assert.raises(() -> config.getFloat("word"), ArgumentError);
		Assert.raises(() -> config.getBool("two"), ArgumentError);
		Assert.raises(() -> config.getBool("text"), ArgumentError);
		Assert.raises(() -> config.getString("obj"), ArgumentError);
		Assert.raises(() -> config.getString("list"), ArgumentError);
		Assert.raises(() -> config.getArray("obj"), ArgumentError);

		Assert.equals(80, config.getInt("text"));
		Assert.equals(31, config.getInt("hex"));
		Assert.equals(42, config.getInt("spaced"));
		Assert.equals(-2147483647 - 1, config.getInt("neg"));
		Assert.equals(80.5, config.getFloat("fraction"));
		Assert.equals(80.0, config.getFloat("text"));
		Assert.equals(true, config.getBool("word"));
		Assert.equals(true, config.getBool("one"));
		// A number reads as the text it was written as.
		Assert.equals("80.5", config.getString("fraction"));
		Assert.equals("4294967296", config.getString("huge"));
	}

	public function testARefusalNamesThePath():Void {
		var config = ConfigTree.fromJson('{"server": {"port": "80a80"}}');
		var message:String = null;
		try {
			config.getInt("server.port");
		} catch (e:ArgumentError) {
			message = e.message;
		}
		Assert.isTrue(message != null && message.indexOf("server.port") >= 0, message);
	}

	public function testBadJsonThrowsNamingWhere():Void {
		var cases:Array<Array<String>> = [
			['{"a": 1,\n  "b": }', "line 2, column 8"],
			['{"a": [1, 2,]}', "line 1, column 13"],
			['{"a": 1} trailing', "line 1, column 10"],
			['{"a": "unclosed', "line 1, column 16"],
			['{a: 1}', "line 1, column 2"],
			['', "empty"],
			['{"a": 01}', "line 1, column 8"],
			['{"a": tru}', "line 1, column 7"],
			['// comment\n{}', "line 1, column 1"],
		];
		for (entry in cases) {
			var message:String = null;
			try {
				ConfigTree.fromJson(entry[0], "service.json");
			} catch (e:ArgumentError) {
				message = e.message;
			}
			Assert.isTrue(message != null && message.indexOf("service.json") >= 0 && message.indexOf(entry[1]) >= 0, '${entry[0]}: $message');
		}

		// A document is an object at its top level.
		Assert.raises(() -> ConfigTree.fromJson("[1, 2]"), ArgumentError);
		Assert.raises(() -> ConfigTree.fromJson("null"), ArgumentError);
		// Nesting is bounded rather than left to the stack.
		var deep:StringBuf = new StringBuf();
		deep.add('{"a":');
		for (_ in 0...200) {
			deep.add("[");
		}
		Assert.raises(() -> ConfigTree.fromJson(deep.toString()), ArgumentError);
	}

	public function testStringsAreReadWithTheirEscapes():Void {
		var config = ConfigTree.fromJson('\u{FEFF}{"path": "C:\\\\data\\\\file", "quote": "say \\"hi\\"", "lines": "a\\nb\\tc", "e": "caf\\u00e9", "face": "\\ud83d\\ude00", "slash": "a\\/b"}');

		Assert.equals("C:\\data\\file", config.getString("path"));
		Assert.equals('say "hi"', config.getString("quote"));
		Assert.equals("a\nb\tc", config.getString("lines"));
		Assert.equals("caf\u00e9", config.getString("e"));
		Assert.equals("\u{1F600}", config.getString("face"));
		Assert.equals("a/b", config.getString("slash"));
	}

	public function testLayersMergeDeeplyAndArraysAreReplaced():Void {
		var config = ConfigTree.fromJson('{"server": {"port": 9000, "tls": {"on": true}}, "origins": ["a", "b"]}')
			.withJson('{"server": {"host": "10.0.0.1", "tls": {"cert": "c.pem"}}, "origins": ["c"]}', "override.json");

		Assert.equals(9000, config.getInt("server.port"));
		Assert.equals("10.0.0.1", config.getString("server.host"));
		Assert.equals(true, config.getBool("server.tls.on"));
		Assert.equals("c.pem", config.getString("server.tls.cert"));
		// A list in an override is the list.
		Assert.same(["c"], config.getStrings("origins"));
	}

	public function testDefaultsFillOnlyWhatIsMissing():Void {
		var config = ConfigTree.fromJson('{"server": {"port": 9000}, "log": null}')
			.withDefaults({server: {port: 8080, host: "0.0.0.0"}, log: {level: "info"}, limits: [1, 2]});

		Assert.equals(9000, config.getInt("server.port"));
		Assert.equals("0.0.0.0", config.getString("server.host"));
		Assert.equals("info", config.getString("log.level"));
		Assert.same([1, 2], config.getArray("limits"));

		// Defaults given first are overridden by what comes after.
		var first = new ConfigTree().withDefaults({port: 8080}).withJson('{"port": 9090}');
		Assert.equals(9090, first.getInt("port"));

		// A map works as an object does.
		var values:Map<String, Dynamic> = ["port" => 7000, "name" => "x"];
		var mapped = new ConfigTree().withDefaults(values);
		Assert.equals(7000, mapped.getInt("port"));

		// Only JSON-shaped values.
		Assert.raises(() -> new ConfigTree().withDefaults({when: new ArgumentError("not json")}), ArgumentError);
	}

	public function testAnEnvironmentVariableReachesACamelCaseKeyInAnArrayOfObjects():Void {
		var config = ConfigTree.fromJson(DOCUMENT).withEnvironment("YGG_", "__", [
			"YGG_AUTH__TOKEN__KEYS__1__PUBLICKEY" => "CCC",
			"YGG_AUTH__TOKEN__MAX_AGE" => "60",
			"YGG_REALM__THIS__ENDPOINTS__0__PORT" => "7101",
			"YGG_REALM__THIS__ENDPOINTS__1__public_port" => "7202",
			"OTHER_REALM__THIS__ID" => "ignored",
		]);

		Assert.equals("CCC", config.getString("auth.token.keys[1].publicKey"));
		Assert.equals("AAA", config.getString("auth.token.keys[0].publicKey"));
		Assert.equals(60, config.getInt("auth.token.maxAge"));
		Assert.equals(7101, config.getInt("realm.this.endpoints[0].port"));
		Assert.equals(7202, config.getInt("realm.this.endpoints[1].publicPort"));
		Assert.equals("eu-1", config.getString("realm.this.id"));
		// Reached, not added beside.
		Assert.same(["kid", "publicKey"], config.keys("auth.token.keys[1]"));
	}

	public function testAnEnvironmentVariableAddsWhatIsNotThere():Void {
		var config = ConfigTree.fromJson('{"servers": [{"host": "a"}]}').withEnvironment("APP", "__", [
			"APP__NEW__SETTING" => "1",
			"app_servers__1__host" => "b",
			"APP_SERVERS__2__HOST" => "c",
			"APP__LIST__0" => "x",
			"APP__LIST__1" => "y",
		]);

		Assert.equals(1, config.getInt("new.setting"));
		Assert.equals("b", config.getString("servers[1].host"));
		Assert.equals("c", config.getString("servers[2].host"));
		Assert.same(["x", "y"], config.getStrings("list"));
	}

	public function testEnvironmentIndexesAreAppliedInNumberOrder():Void {
		var variables:Map<String, String> = new Map();
		for (i in 0...12) {
			variables.set('APP_ITEMS__${i}', 'v$i');
		}
		var config = new ConfigTree().withEnvironment("APP_", "__", variables);
		Assert.same([for (i in 0...12) 'v$i'], config.getStrings("items"));
	}

	public function testEnvironmentMistakesAreRefusedNamingTheVariable():Void {
		var base = '{"port": 80, "list": [1, 2], "camel": {"maxAge": 1, "max_age": 2}, "obj": {"a": 1}}';
		var bad:Array<String> = ["APP_PORT__X", "APP_LIST__5", "APP_LIST__NAME", "APP_CAMEL__MAXAGE", "APP_OBJ", "APP_LIST", "APP_A____B"];
		for (name in bad) {
			var message:String = null;
			try {
				ConfigTree.fromJson(base).withEnvironment("APP_", "__", [name => "1"]);
			} catch (e:ArgumentError) {
				message = e.message;
			}
			Assert.isTrue(message != null && message.indexOf(name) >= 0, '$name: $message');
		}

		// An object or array set from a variable takes JSON of its kind.
		var config = ConfigTree.fromJson(base).withEnvironment("APP_", "__", ["APP_LIST" => '["a", "b"]', "APP_OBJ" => '{"b": 2}']);
		Assert.same(["a", "b"], config.getStrings("list"));
		Assert.equals(2, config.getInt("obj.b"));
		Assert.isNull(config.getInt("obj.a"));

		Assert.raises(() -> new ConfigTree().withEnvironment(""), ArgumentError);
	}

	public function testSectionsAreViewsWithTheirOwnPaths():Void {
		var config = ConfigTree.fromJson(DOCUMENT);
		var realm = config.section("realm.this");

		Assert.equals(7000, realm.getInt("port"));
		Assert.equals("a.example", realm.getString("endpoints[0].host"));
		var hosts = [for (endpoint in config.sections("realm.this.endpoints")) endpoint.getString("host")];
		Assert.same(["a.example", "b.example"], hosts);

		realm.set("port", 7500);
		Assert.equals(7500, config.getInt("realm.this.port"));

		// Nothing there: an empty section, read through fallbacks.
		Assert.equals(5, config.section("absent").getInt("x", 5));
		Assert.equals(0, config.sections("absent").length);
		Assert.raises(() -> config.section("realm.this.port"), ArgumentError);
		Assert.raises(() -> config.sections("realm.this"), ArgumentError);
		Assert.raises(() -> config.sections("tags"), ArgumentError);
	}

	public function testKeysKeepTheirOrder():Void {
		var config = ConfigTree.fromJson('{"z": 1, "a": 2, "m": 3}').withJson('{"b": 4, "a": 5}');
		Assert.same(["z", "a", "m", "b"], config.keys());
		Assert.same(["0", "1", "2"], ConfigTree.fromJson(DOCUMENT).keys("tags"));
	}

	public function testValuesComeOutAsPlainValues():Void {
		var config = ConfigTree.fromJson(DOCUMENT);

		var endpoint:Dynamic = config.get("realm.this.endpoints[0]");
		Assert.equals("a.example", endpoint.host);
		Assert.equals(7001, endpoint.port);
		var tags:Array<Dynamic> = config.getArray("tags");
		Assert.equals(3, tags.length);
		Assert.equals("red", tags[0]);
		Assert.equals(2, tags[1]);
		Assert.equals(false, tags[2]);
		Assert.same(["red", "2", "false"], config.getStrings("tags"));
		Assert.equals(1e300, config.get("flags.big"));
	}

	public function testRequireAndSet():Void {
		var config = ConfigTree.fromJson('{"name": "svc", "blank": "  ", "none": null}');

		Assert.equals("svc", config.require("name"));
		Assert.raises(() -> config.require("blank"), ArgumentError);
		Assert.raises(() -> config.require("none"), ArgumentError);
		Assert.raises(() -> config.require("absent"), ArgumentError);

		config.set("db.pool.size", 4).set("hosts[0]", "a").set("hosts[1]", "b");
		Assert.equals(4, config.getInt("db.pool.size"));
		Assert.same(["a", "b"], config.getStrings("hosts"));
		Assert.raises(() -> config.set("hosts[3]", "d"), ArgumentError);
		Assert.raises(() -> config.set("name.inner", 1), ArgumentError);
		Assert.raises(() -> config.getString("a..b"), ArgumentError);
		Assert.raises(() -> config.getString("a[x]"), ArgumentError);
	}

	public function testATreeMergesAnother():Void {
		var base = ConfigTree.fromJson('{"a": {"b": 1, "c": 2}}');
		var other = ConfigTree.fromJson('{"a": {"c": 3}}');
		base.withTree(other);
		Assert.equals(1, base.getInt("a.b"));
		Assert.equals(3, base.getInt("a.c"));
		// A copy was taken: changing one does not change the other.
		other.set("a.c", 4);
		Assert.equals(3, base.getInt("a.c"));
	}

	public function testASecretIsResolved():Void {
		var config = ConfigTree.fromJson('{"plain": "dev-key", "blank": "", "number": 5}');
		Assert.equals("dev-key", config.secret("plain"));
		Assert.raises(() -> config.secret("blank"), ArgumentError);
		Assert.raises(() -> config.secret("number"), ArgumentError);
		Assert.raises(() -> config.secret("absent"), ArgumentError);
	}

	#if !(js && !nodejs)
	public function testASecretNamedByEnvironmentOrFileIsRead():Void {
		var path:String = __write("from-a-file\n");
		var config = ConfigTree.fromJson('{"file": "file:' + StringTools.replace(path, "\\", "\\\\") + '", "missing": "env:CROSSBYTE_CONFIGTREE_NEVER_SET"}');
		Assert.equals("from-a-file", config.secret("file"));
		Assert.raises(() -> config.secret("missing"), ArgumentError);
		sys.FileSystem.deleteFile(path);
	}

	public function testFilesAreReadAndNamedInErrors():Void {
		var good:String = __write('{"server": {"port": 9000}}');
		var bad:String = __write('{"server": {"port": 9000,}}');
		var missing:String = good + ".absent";

		var config = new ConfigTree().withJsonFile(good).withJsonFile(missing, true);
		Assert.equals(9000, config.getInt("server.port"));

		Assert.raises(() -> new ConfigTree().withJsonFile(missing), ArgumentError);
		var message:String = null;
		try {
			new ConfigTree().withJsonFile(bad, true);
		} catch (e:ArgumentError) {
			message = e.message;
		}
		Assert.isTrue(message != null && message.indexOf(bad) >= 0 && message.indexOf("line 1, column 26") >= 0, message);

		sys.FileSystem.deleteFile(good);
		sys.FileSystem.deleteFile(bad);
	}

	public function testTheProcessEnvironmentIsReadByDefault():Void {
		#if jvm
		// Sys.putEnv throws on the jvm: PATH, which every system has, under an
		// empty-looking prefix of its own name.
		var config = new ConfigTree().withEnvironment("PAT");
		Assert.isTrue(config.has("h"));
		#else
		Sys.putEnv("CROSSBYTE_TREE_TEST__SERVER__PORT", "9443");
		var config = ConfigTree.fromJson('{"server": {"port": 80}}').withEnvironment("CROSSBYTE_TREE_TEST");
		Assert.equals(9443, config.getInt("server.port"));
		#end
	}

	private static var __count:Int = 0;

	private function __write(content:String):String {
		var directory:String = ".";
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				directory = candidate;
				break;
			}
		}
		var path:String = haxe.io.Path.join([directory, 'crossbyte-configtree-${Std.random(1000000)}-${__count++}.json']);
		sys.io.File.saveContent(path, content);
		return path;
	}
	#else
	public function testABrowserHasNoFilesOrEnvironment():Void {
		Assert.raises(() -> new ConfigTree().withJsonFile("config.json"), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> new ConfigTree().withEnvironment("APP_"), crossbyte.errors.IllegalOperationError);
	}
	#end
}
