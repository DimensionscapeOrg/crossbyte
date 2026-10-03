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

	On a target without threads the lines go through `Logger` as they always
	did, and the cases check that instead.
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

	private function __server():HTTPServer {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.rateLimitKey = _ -> null;
		config.middleware.push((handler, next) -> handler.respond(200, "text/plain", "ok"));
		return new HTTPServer(config);
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
