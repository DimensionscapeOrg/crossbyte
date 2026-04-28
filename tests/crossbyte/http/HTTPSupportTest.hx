package crossbyte.http;

import crossbyte._internal.http.RewriteEngine;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

class HTTPSupportTest extends utest.Test {
	public function testRateLimiterLimitsAtEleventhRequestAndResetsWindow():Void {
		var limiter = new RateLimiter(0.01);

		for (_ in 0...10) {
			Assert.isFalse(limiter.isRateLimited("127.0.0.1"));
		}
		Assert.isTrue(limiter.isRateLimited("127.0.0.1"));

		Sys.sleep(0.03);

		Assert.isFalse(limiter.isRateLimited("127.0.0.1"));
		Assert.isFalse(limiter.isRateLimited("192.168.0.2"));
	}

	public function testHTTPServerConfigProvidesIndependentDefaults():Void {
		var first = new HTTPServerConfig();
		var second = new HTTPServerConfig();

		Assert.notNull(first.rateLimiter);
		Assert.notNull(first.tryFiles);
		Assert.notNull(first.rewrites);
		Assert.equals(2, first.directoryIndex.length);
		Assert.equals(3, first.tryFiles.length);
		Assert.equals("$uri", first.tryFiles[0]);
		Assert.equals("/index.html", first.tryFiles[2]);
		Assert.equals(1, first.rewrites.length);
		Assert.equals("^/api/.*$", first.rewrites[0].pattern);
		Assert.isTrue(first.rootDirectory != null);

		first.directoryIndex.push("fallback.htm");
		first.customHeaders.push(new URLRequestHeader("X-Test", "one"));
		first.middleware.push((_, ?next) -> if (next != null) next());
		first.tryFiles.push("/app.html");
		first.rewrites.push({
			pattern: "^/docs/(.*)$",
			target: "/docs/$1",
			flags: [RewriteFlag.L],
			conditions: []
		});

		Assert.equals(3, first.directoryIndex.length);
		Assert.equals(2, second.directoryIndex.length);
		Assert.equals(0, second.customHeaders.length);
		Assert.equals(0, second.middleware.length);
		Assert.equals(3, second.tryFiles.length);
		Assert.equals(1, second.rewrites.length);
	}

	public function testRewriteEngineSupportsStaticPhpAndPassThroughDecisions():Void {
		var root = File.createTempDirectory();
		try {
			root.resolvePath("asset.txt").save(ByteArray.fromBytes(Bytes.ofString("asset")));
			root.resolvePath("index.html").save(ByteArray.fromBytes(Bytes.ofString("home")));
			root.resolvePath("about.html").save(ByteArray.fromBytes(Bytes.ofString("about")));
			root.resolvePath("index.php").save(ByteArray.fromBytes(Bytes.ofString("<?php")));

			var cfg = new HTTPServerConfig(
				"127.0.0.1",
				8080,
				root,
				null,
				["index.html"],
				null,
				null,
				null,
				null,
				null,
				false,
				null,
				null,
				null,
				600,
				false,
				256,
				0,
				false,
				"127.0.0.1",
				8080,
				"php-cgi",
				"php.ini",
				1,
				["$uri", "$uri/", "/index.html"],
				[
					{
						pattern: "^/blog$",
						target: "/about.html",
						flags: [RewriteFlag.PT, RewriteFlag.L],
						conditions: []
					},
					{
						pattern: "^/api/(.*)$",
						target: "/index.php?path=$1",
						flags: [RewriteFlag.PHP, RewriteFlag.QSA, RewriteFlag.L, RewriteFlag.NC],
						conditions: [{
							type: RewriteConditionType.Method,
							key: "",
							pattern: "^GET$",
							negate: false
						}]
					}
				]
			);

			var staticDecision = RewriteEngine.decide(cfg, "/asset.txt", "", "GET", new StringMap<String>());
			Assert.notNull(staticDecision);
			Assert.equals("/asset.txt", staticDecision.finalPath);
			Assert.isTrue(staticDecision.isStatic);
			Assert.isFalse(staticDecision.toPHP);

			var dirDecision = RewriteEngine.decide(cfg, "/", "", "GET", new StringMap<String>());
			Assert.notNull(dirDecision);
			Assert.equals("/index.html", dirDecision.finalPath);
			Assert.isTrue(dirDecision.isStatic);

			var passThrough = RewriteEngine.decide(cfg, "/blog", "", "GET", new StringMap<String>());
			Assert.notNull(passThrough);
			Assert.equals("/about.html", passThrough.finalPath);
			Assert.isTrue(passThrough.isStatic);
			Assert.isFalse(passThrough.toPHP);

			var headers = new StringMap<String>();
			var phpDecision = RewriteEngine.decide(cfg, "/API/users", "page=2", "GET", headers);
			Assert.notNull(phpDecision);
			Assert.equals("/index.php", phpDecision.finalPath);
			Assert.isTrue(phpDecision.toPHP);
			Assert.equals("page=2&path=users", phpDecision.query);
			Assert.isTrue(phpDecision.preserveURI);

			var blockedByMethod = RewriteEngine.decide(cfg, "/api/users", "page=2", "POST", headers);
			Assert.notNull(blockedByMethod);
			Assert.equals("/index.html", blockedByMethod.finalPath);
			Assert.isTrue(blockedByMethod.isStatic);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testRewriteEngineNormalizesAndRejectsTraversal():Void {
		Assert.equals("/api/v1", RewriteEngine.normalize("api//v1"));
		Assert.equals("/", RewriteEngine.normalize(""));

		var threw = false;
		try {
			RewriteEngine.normalize("/../../secret");
		} catch (e:Dynamic) {
			threw = Std.string(e) == "403";
		}

		Assert.isTrue(threw);
	}

	public function testRewriteEngineSupportsHeaderConditionsAndBackrefs():Void {
		var root = File.createTempDirectory();
		try {
			root.resolvePath("mobile.html").save(ByteArray.fromBytes(Bytes.ofString("mobile")));
			var cfg = new HTTPServerConfig(
				"127.0.0.1",
				8080,
				root,
				null,
				["index.html"],
				null,
				null,
				null,
				null,
				null,
				false,
				null,
				null,
				null,
				600,
				false,
				256,
				0,
				false,
				"127.0.0.1",
				8080,
				"php-cgi",
				"php.ini",
				1,
				["$uri", "$uri/", "/index.html"],
				[{
					pattern: "^/content/(.*)$",
					target: "/$1.html",
					flags: [RewriteFlag.PT, RewriteFlag.L],
					conditions: [{
						type: RewriteConditionType.Header,
						key: "User-Agent",
						pattern: "Mobile",
						negate: false
					}]
				}]
			);

			var headers = new StringMap<String>();
			headers.set("User-Agent", "Mobile Safari");
			var allowed = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Assert.notNull(allowed);
			Assert.equals("/mobile.html", allowed.finalPath);

			headers.set("User-Agent", "Desktop");
			var fallback = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Assert.isNull(fallback);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}
}
