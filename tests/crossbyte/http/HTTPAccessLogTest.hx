package crossbyte.http;

import crossbyte._internal.http.AccessLog;
import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.utils.Logger;
import utest.Assert;
import utest.Async;

/**
	The access log's lines are written off the runtime (`AccessLog`): queued as
	each response goes, and written a few times a second by a thread of their
	own, to a bounded queue. What that must keep: a connection's lines in its
	order, every line below the cap, a count of the lines dropped past it, and
	everything queued written when the server drains or closes.

	On a target without threads the lines go through `Logger`, and the
	cases check that instead.
**/
@:timeout(20000)
class HTTPAccessLogTest extends utest.Test {
	private var __written:String = "";

	public function setup():Void {
		__written = "";
		#if target.threaded
		AccessLog.flush();
		AccessLog.__output = text -> __written += text;
		// Long, so only a flush writes: the drain's, here.
		AccessLog.__intervalOverride = 60;
		#end
	}

	public function teardown():Void {
		#if target.threaded
		AccessLog.flush();
		AccessLog.__output = null;
		AccessLog.__intervalOverride = 0;
		AccessLog.__capOverride = 0;
		#end
		Logger.sink = null;
		Logger.recordSink = null;
		Logger.json = false;
	}

	/**
		A path is the client's text, and decoded it can hold anything but a
		NUL: a space, a quote, an equals sign, a line feed. Read as logfmt, as
		a collector reads it, each line still has one `status`, the real one,
		and the path comes back as it was asked for.
	**/
	public function testAPathCannotForgeAFieldOfItsOwn(async:Async):Void {
		#if !target.threaded
		var lines:Array<String> = [];
		Logger.sink = line -> lines.push(line);
		#end
		var server:HTTPServer = __server(404);
		// Asked for, and as each should read back.
		var asked:Array<String> = ["/a%20status=500", "/b%22%20status=500", "/c%0Astatus=500", "/d=1"];
		var decoded:Array<String> = ["/a status=500", '/b" status=500', "/c\nstatus=500", "/d=1"];
		var requests:String = "";
		for (i in 0...asked.length) {
			requests += 'GET ${asked[i]} HTTP/1.1\r\nHost: x\r\n' + (i == asked.length - 1 ? "Connection: close\r\n" : "") + "\r\n";
		}

		HTTPTestSupport.exchangeEach(server, [requests], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			#if target.threaded
			var text:String = __written;
			#else
			var text:String = lines.join("\n");
			#end
			var logged:Array<String> = text.split("\n").filter(line -> line.indexOf("[http.access]") >= 0);
			Assert.equals(asked.length, logged.length, "lines: " + text);
			// The form HTTPServer documents, quoted and escaped as Logger quotes a field.
			var expected:Array<String> = [
				'[INFO] [http.access] method=GET path="/a status=500" status=404 client=',
				'[INFO] [http.access] method=GET path="/b\\" status=500" status=404 client=',
				'[INFO] [http.access] method=GET path="/c\\nstatus=500" status=404 client=',
				'[INFO] [http.access] method=GET path="/d=1" status=404 client='
			];
			for (i in 0...logged.length) {
				Assert.isTrue(logged[i].indexOf(expected[i]) >= 0, 'line $i: ' + logged[i]);
			}
			for (i in 0...logged.length) {
				var pairs:Array<Array<String>> = __logfmt(logged[i]);
				var statuses:Array<String> = [for (pair in pairs) if (pair[0] == "status") pair[1]];
				Assert.same(["404"], statuses, "a path forged a status: " + logged[i]);
				Assert.equals(decoded[i], __field(pairs, "path"), logged[i]);
				Assert.equals("GET", __field(pairs, "method"), logged[i]);
				var client:Null<String> = __field(pairs, "client");
				Assert.isTrue(client != null && client.indexOf("127.0.0.1") >= 0, logged[i]);
			}
			async.done();
		}, true);
	}

	/** In JSON each part of the line is a field of the object, the status among them. */
	public function testJsonCarriesTheStatusAsAField(async:Async):Void {
		#if !target.threaded
		var lines:Array<String> = [];
		Logger.sink = line -> lines.push(line);
		#end
		Logger.json = true;
		var server:HTTPServer = __server(404);

		HTTPTestSupport.exchangeEach(server, ["GET /a%20status=500 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"], function(_):Void {
			try server.close() catch (_:Dynamic) {}
			#if target.threaded
			var text:String = __written;
			#else
			var text:String = lines.join("\n");
			#end
			var logged:Array<String> = text.split("\n").filter(line -> line.indexOf('"http.access"') >= 0);
			Assert.equals(1, logged.length, "lines: " + text);
			if (logged.length == 1) {
				var record:Dynamic = haxe.Json.parse(logged[0]);
				Assert.equals("INFO", record.level);
				Assert.equals("http.access", record.category);
				Assert.equals("404", record.status);
				Assert.equals("/a status=500", record.path);
				Assert.equals("GET", record.method);
				Assert.isTrue(Std.string(record.client).indexOf("127.0.0.1") >= 0, logged[0]);
			}
			async.done();
		}, true);
	}

	/**
		A record sink that throws does not throw out of the access log into
		the response being logged, as it does not out of `Logger`: the line
		goes where a line with no sink goes, the access log's own way, and the
		next line is offered to the sink again.
	**/
	public function testARecordSinkThatThrowsDoesNotThrowOutOfTheAccessLog():Void {
		var calls:Int = 0;
		var records:Array<crossbyte.utils.LogRecord> = [];
		Logger.recordSink = function(record:crossbyte.utils.LogRecord) {
			calls++;
			if (calls == 1) {
				throw "collector unreachable";
			}
			records.push(record);
		};

		AccessLog.write("GET", "/first", 200, "127.0.0.1");
		AccessLog.write("GET", "/second", 200, "127.0.0.1");

		Assert.equals(2, calls);
		Assert.equals(1, records.length);
		if (records.length == 1) {
			var fields:Null<Map<String, String>> = records[0].fields;
			Assert.equals("/second", fields == null ? null : fields.get("path"));
		}
		#if target.threaded
		AccessLog.flush();
		Assert.isTrue(__written.indexOf("path=/first") >= 0, "the line the sink refused was lost: " + __written);
		#end
	}

	/** A record sink is handed the parts as fields, and the line as text mode writes it. */
	public function testARecordSinkIsHandedThePartsAsFields(async:Async):Void {
		var records:Array<crossbyte.utils.LogRecord> = [];
		Logger.recordSink = record -> if (record.category == "http.access") records.push(record);
		var server:HTTPServer = __server(404);

		HTTPTestSupport.exchangeEach(server, ["GET /a%20status=500 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"], function(_):Void {
			try server.close() catch (_:Dynamic) {}
			Logger.recordSink = null;
			Assert.equals(1, records.length);
			if (records.length == 1) {
				var fields:Null<Map<String, String>> = records[0].fields;
				Assert.notNull(fields, "the record has no fields");
				Assert.equals("404", fields == null ? null : fields.get("status"));
				Assert.equals("/a status=500", fields == null ? null : fields.get("path"));
				Assert.equals("GET", fields == null ? null : fields.get("method"));
				Assert.equals(crossbyte.utils.LogLevel.INFO, records[0].level);
				Assert.same(["404"], [for (pair in __logfmt(records[0].line)) if (pair[0] == "status") pair[1]], records[0].line);
			}
			async.done();
		}, true);
	}

	/**
		Requests on one keep-alive connection are logged in the order they
		were answered, and none is written until the server drains, which
		writes them all: the writer is waiting a minute.
	**/
	public function testAConnectionsLinesArriveInOrderAndDrainWritesThem(async:Async):Void {
		#if !target.threaded
		var lines:Array<String> = [];
		Logger.sink = line -> lines.push(line);
		#end
		var server:HTTPServer = __server();
		var requests:String = "";
		for (i in 0...20) {
			requests += 'GET /ordered/$i HTTP/1.1\r\nHost: x\r\n' + (i == 19 ? "Connection: close\r\n" : "") + "\r\n";
		}

		__settle(() -> {
			HTTPTestSupport.exchangeEach(server, [requests], function(responses:Array<HTTPTestResponse>):Void {
				#if target.threaded
				var pendingBeforeDrain:Int = AccessLog.__pending();
				var writtenBeforeDrain:String = __written;
				#end
				var drained:Bool = false;
				server.drain(1.0, () -> drained = true);
				HTTPTestSupport.pumpUntilAsync(() -> drained, 5, function(_):Void {
					#if target.threaded
					Assert.equals(20, pendingBeforeDrain, "the lines were not queued, or were written before the drain");
					Assert.equals("", writtenBeforeDrain);
					var text:String = __written;
					#else
					var text:String = lines.join("\n");
					#end
					var at:Int = -1;
					for (i in 0...20) {
						var next:Int = text.indexOf('/ordered/$i ', at + 1);
						Assert.isTrue(next > at, 'line $i is missing or out of order');
						at = next;
					}
					async.done();
				});
			}, true);
		});
	}

	/** Below the cap no line is lost, across connections. */
	public function testNothingIsLostBelowTheCap(async:Async):Void {
		#if !target.threaded
		var lines:Array<String> = [];
		Logger.sink = line -> lines.push(line);
		#end
		var server:HTTPServer = __server();
		var requests:Array<String> = [];
		for (c in 0...10) {
			var batch:String = "";
			for (i in 0...10) {
				batch += 'GET /every/$c/$i HTTP/1.1\r\nHost: x\r\n' + (i == 9 ? "Connection: close\r\n" : "") + "\r\n";
			}
			requests.push(batch);
		}

		HTTPTestSupport.exchangeEach(server, requests, function(_):Void {
			try server.close() catch (_:Dynamic) {}
			#if target.threaded
			var text:String = __written;
			#else
			var text:String = lines.join("\n");
			#end
			var found:Int = 0;
			for (c in 0...10) {
				for (i in 0...10) {
					if (text.indexOf('/every/$c/$i ') >= 0) {
						found++;
					}
				}
			}
			Assert.equals(100, found, "lines were lost");
			Assert.isTrue(text.indexOf("dropped") < 0, "lines were dropped below the cap");
			async.done();
		}, true);
	}

	/**
		Past the cap a line is dropped and counted, never waited for or held,
		and the next write says how many were, once.
	**/
	public function testPastTheCapLinesAreCountedAndTheCountSaidOnce(async:Async):Void {
		#if target.threaded
		// Room for a few lines only.
		AccessLog.__capOverride = 200;
		var server:HTTPServer = __server();
		var batch:String = "";
		for (i in 0...30) {
			batch += 'GET /flood/$i HTTP/1.1\r\nHost: x\r\n' + (i == 29 ? "Connection: close\r\n" : "") + "\r\n";
		}

		__settle(() -> {
			HTTPTestSupport.exchangeEach(server, [batch], function(_):Void {
				var queued:Int = AccessLog.__pending();
				try server.close() catch (_:Dynamic) {}
				var text:String = __written;
				var kept:Int = 0;
				for (i in 0...30) {
					if (text.indexOf('/flood/$i ') >= 0) {
						kept++;
					}
				}
				Assert.isTrue(kept > 0 && kept < 30, 'kept $kept of 30 under a 200-character cap');
				Assert.equals(queued, kept);
				var said:EReg = ~/([0-9]+) access log lines were dropped/;
				Assert.isTrue(said.match(text), "the drop was not reported: " + text);
				Assert.equals(30 - kept, Std.parseInt(said.matched(1)));
				Assert.equals(text.indexOf("dropped"), text.lastIndexOf("dropped"), "the count was said more than once");
				async.done();
			}, true);
		});
		#else
		Assert.pass("no queue on a target without threads");
		async.done();
		#end
	}

	private function __server(status:Int = 200):HTTPServer {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.rateLimitKey = _ -> null;
		config.middleware.push((handler, next) -> handler.respond(status, "text/plain", "ok"));
		return new HTTPServer(config);
	}

	/**
		`line` read as a logfmt collector reads it (Loki's `| logfmt`, the go
		logfmt grammar): pairs of a key and its value, in order. A key is a run
		of anything but a space, `=` or `"`; after `=` comes a value, quoted
		with backslash escapes or a run up to the next space. A bare word is a
		key with no value (null).
	**/
	private static function __logfmt(line:String):Array<Array<String>> {
		var pairs:Array<Array<String>> = [];
		var i:Int = 0;
		var length:Int = line.length;
		while (i < length) {
			while (i < length && line.charAt(i) == " ") {
				i++;
			}
			var keyStart:Int = i;
			while (i < length && line.charAt(i) != " " && line.charAt(i) != "=" && line.charAt(i) != '"') {
				i++;
			}
			var key:String = line.substring(keyStart, i);
			if (i < length && line.charAt(i) == "=") {
				i++;
				var value:StringBuf = new StringBuf();
				if (i < length && line.charAt(i) == '"') {
					i++;
					while (i < length && line.charAt(i) != '"') {
						if (line.charAt(i) == "\\" && i + 1 < length) {
							i++;
							switch (line.charAt(i)) {
								case "n":
									value.add("\n");
								case "r":
									value.add("\r");
								case "t":
									value.add("\t");
								case other:
									value.add(other);
							}
						} else {
							value.add(line.charAt(i));
						}
						i++;
					}
					i++;
				} else {
					while (i < length && line.charAt(i) != " ") {
						value.add(line.charAt(i));
						i++;
					}
				}
				pairs.push([key, value.toString()]);
			} else if (key.length > 0) {
				pairs.push([key, null]);
			} else {
				// A stray quote: skipped, as the go grammar reports and moves on.
				i++;
			}
		}
		return pairs;
	}

	private static function __field(pairs:Array<Array<String>>, key:String):Null<String> {
		for (pair in pairs) {
			if (pair[0] == key) {
				return pair[1];
			}
		}
		return null;
	}

	/**
		Lets a writer started by an earlier case finish the short wait it was
		in, so the minute-long one is what holds it.
	**/
	private static function __settle(then:Void->Void):Void {
		var until:Float = haxe.Timer.stamp() + 0.3;
		HTTPTestSupport.pumpWallUntilAsync(() -> haxe.Timer.stamp() >= until, 2, _ -> {
			#if target.threaded
			AccessLog.flush();
			#end
			then();
		});
	}
}
