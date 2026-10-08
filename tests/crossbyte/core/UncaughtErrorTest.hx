package crossbyte.core;

import crossbyte.core._internal.PassFlush;
import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import crossbyte.events.UncaughtErrorEvent;
import crossbyte.utils.Logger;
import utest.Assert;
#if (cpp || java || jvm)
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
#end

/**
	A callback's failure costs that callback, not the runtime.

	In each case here, a throw that left the timer, the tick dispatch or the
	socket poll with nothing above to catch it would end the loop: EXIT never
	dispatched, held output never flushed, a recurring timer that threw
	dequeued for good, and every other connection taken down with the one
	whose handler had the bug.
**/
@:access(crossbyte.core.CrossByte)
class UncaughtErrorTest extends utest.Test {
	private var logged:Array<String>;

	public function setup():Void {
		logged = [];
		Logger.sink = line -> logged.push(line);
	}

	public function teardown():Void {
		Logger.sink = null;
	}

	public function testATimerThatThrowsIsContainedAndStaysArmed():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var reports = __watch(runtime);
		var failing = 0;
		var healthy = 0;

		runtime.__timer.setInterval(0.1, 0.1, () -> {
			failing++;
			throw "timer bug";
		});
		runtime.__timer.setInterval(0.1, 0.1, () -> healthy++);

		var escaped:Dynamic = __pump(runtime, 3, 0.1);
		runtime.exit();

		Assert.isNull(escaped, "a timer's failure escaped the runtime: " + escaped);
		Assert.equals(3, failing, "the timer that threw did not stay armed");
		Assert.equals(3, healthy, "the timer beside it was not served");
		Assert.equals(3, reports.length);
		for (report in reports) {
			Assert.equals(UncaughtErrorEvent.TIMER, report.source);
			Assert.equals("timer bug", report.error);
		}
		Assert.equals(3, __errorLines("timer bug"), "each failure should be logged: " + logged);
	}

	public function testATickListenerThatThrowsDoesNotSkipTheOthers():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var reports = __watch(runtime);
		var first = 0;
		var second = 0;

		runtime.addEventListener(TickEvent.TICK, _ -> {
			first++;
			throw "tick bug";
		});
		runtime.addEventListener(TickEvent.TICK, _ -> second++);

		var escaped:Dynamic = __pump(runtime, 2, 1 / 60);
		runtime.exit();

		Assert.isNull(escaped, "a tick listener's failure escaped the runtime: " + escaped);
		Assert.equals(2, first);
		Assert.equals(2, second, "the listener after the one that threw was skipped");
		Assert.equals(2, reports.length);
		if (reports.length > 0) {
			Assert.equals(UncaughtErrorEvent.TICK, reports[0].source);
		}
	}

	public function testAnExitListenerThatThrowsDoesNotStopTheExit():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var reports = __watch(runtime);
		var flushed = 0;
		var laterExits = 0;

		runtime.addEventListener(Event.EXIT, _ -> {
			runtime.__queuePassFlush(new Counted(() -> flushed++));
			throw "exit bug";
		});
		runtime.addEventListener(Event.EXIT, _ -> laterExits++);
		runtime.pump(1 / 60, 0);

		var escaped:Dynamic = null;
		try {
			runtime.exit();
		} catch (e:Dynamic) {
			escaped = e;
		}

		Assert.isNull(escaped, "an EXIT listener's failure escaped exit(): " + escaped);
		Assert.equals(1, laterExits, "the EXIT listener after the one that threw never ran");
		Assert.equals(1, flushed, "what was held at exit was never sent");
		Assert.equals(1, reports.length);
		if (reports.length > 0) {
			Assert.equals(UncaughtErrorEvent.LIFECYCLE, reports[0].source);
		}
	}

	#if js
	/**
		On JavaScript the loop is a chain of the platform's own timeouts, so a
		throw out of one must not end the chain: on Node the process would die
		of it, and in a page the runtime would simply never run another frame.
	**/
	@:timeout(5000)
	public function testTheFrameChainCarriesOnPastAFailure(async:utest.Async):Void {
		var passes = 0;
		var exits = 0;
		var runtime:CrossByte = null;
		runtime = new CrossByte(false, CUSTOM(() -> {
			passes++;
			if (passes == 1) {
				throw "frame bug";
			}
			if (passes == 3) {
				runtime.exit();
			}
		}), true);
		runtime.tps = 200;
		runtime.addEventListener(Event.EXIT, _ -> exits++);
		var reports = __watch(runtime);
		runtime.__runEventLoop();

		var started = haxe.Timer.stamp();
		var check:Void->Void = null;
		check = () -> {
			if (exits == 0 && haxe.Timer.stamp() - started < 4) {
				js.Syntax.code("setTimeout({0}, 5)", check);
				return;
			}
			Assert.equals(3, passes, "the frames stopped at the failure");
			Assert.equals(1, exits);
			Assert.equals(1, reports.length);
			async.done();
		};
		js.Syntax.code("setTimeout({0}, 5)", check);
	}
	#else
	public function testTheLoopCarriesOnPastAFailureBetweenCallbacks():Void {
		// A custom loop body stands for whatever fails outside any one
		// callback. The loop is run on this thread, to its end.
		var passes = 0;
		var exits = 0;
		var runtime:CrossByte = null;
		runtime = new CrossByte(false, CUSTOM(() -> {
			passes++;
			if (passes == 1) {
				throw "loop bug";
			}
			if (passes == 3) {
				runtime.exit();
			}
		}), true);
		runtime.tps = 1000;
		runtime.addEventListener(Event.EXIT, _ -> exits++);
		var reports = __watch(runtime);

		var escaped:Dynamic = null;
		try {
			runtime.__runEventLoop();
		} catch (e:Dynamic) {
			escaped = e;
		}
		runtime.exit();

		Assert.isNull(escaped, "the loop let a failure end it: " + escaped);
		Assert.equals(3, passes, "the loop did not carry on after the failure");
		Assert.equals(1, exits);
		Assert.equals(1, reports.length);
		if (reports.length > 0) {
			Assert.equals(UncaughtErrorEvent.LOOP, reports[0].source);
		}
	}
	#end

	public function testAPostedCallbackThatThrowsIsReported():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var reports = __watch(runtime);
		var after = false;

		runtime.__post(() -> throw "posted bug");
		runtime.__post(() -> after = true);
		var escaped:Dynamic = __pump(runtime, 1, 1 / 60);
		runtime.exit();

		Assert.isNull(escaped);
		Assert.isTrue(after, "the callback after the one that threw never ran");
		Assert.equals(1, reports.length);
		if (reports.length > 0) {
			Assert.equals(UncaughtErrorEvent.POSTED, reports[0].source);
		}
	}

	public function testAnUncaughtErrorListenerThatThrowsIsNotReportedThroughItself():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		var heard = 0;
		runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, _ -> {
			heard++;
			throw "reporter bug";
		});
		runtime.addEventListener(TickEvent.TICK, _ -> throw "tick bug");

		var escaped:Dynamic = __pump(runtime, 2, 1 / 60);
		runtime.exit();

		Assert.isNull(escaped);
		Assert.equals(2, heard, "the reporter recursed or stopped hearing");
		Assert.equals(2, __errorLines("reporter bug"));
	}

	#if (cpp || java || jvm)
	public function testASocketHandlerThatThrowsClosesOnlyThatConnection():Void {
		var runtime = CrossByte.current();
		var reports = __watch(runtime);
		var server = new ServerSocket();
		var peers:Array<Socket> = [];
		var bad = new Socket();
		var good = new Socket();
		var badClosed = false;
		var goodReply = "";

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ServerSocketConnectEvent.CONNECT, (event:ServerSocketConnectEvent) -> {
				var peer = event.socket;
				peers.push(peer);
				peer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
					var text = peer.readUTFBytes(peer.bytesAvailable);
					if (text == "boom") {
						throw "handler bug";
					}
					peer.writeUTFBytes("echo:" + text);
					peer.flush();
				});
			});
			server.listen();

			bad.addEventListener(Event.CLOSE, _ -> badClosed = true);
			good.addEventListener(ProgressEvent.SOCKET_DATA, _ -> goodReply += good.readUTFBytes(good.bytesAvailable));
			bad.connect("127.0.0.1", server.localPort);
			good.connect("127.0.0.1", server.localPort);
			Assert.isTrue(__pumpUntil(() -> bad.connected && good.connected && peers.length == 2, 5), "the two clients never connected");

			bad.writeUTFBytes("boom");
			bad.flush();
			Assert.isTrue(__pumpUntil(() -> badClosed, 5), "the connection whose handler threw was left open");

			good.writeUTFBytes("hello");
			good.flush();
			Assert.isTrue(__pumpUntil(() -> goodReply == "echo:hello", 5), "the other connection stopped being served: '" + goodReply + "'");

			Assert.equals(1, reports.length);
			if (reports.length > 0) {
				Assert.equals(UncaughtErrorEvent.SOCKET, reports[0].source);
				Assert.equals("handler bug", reports[0].error);
				Assert.isTrue(peers.indexOf(reports[0].origin) >= 0, "the report did not say which socket");
			}
		} catch (e:Dynamic) {
			Assert.fail("a socket handler's failure escaped the runtime: " + Std.string(e));
		}

		runtime.removeEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, __lastWatcher);
		for (socket in [bad, good]) {
			try socket.close() catch (_:Dynamic) {}
		}
		for (peer in peers) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Bool {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.005);
		}
		return done();
	}
	#end

	private var __lastWatcher:UncaughtErrorEvent->Void;

	private function __watch(runtime:CrossByte):Array<UncaughtErrorEvent> {
		var reports:Array<UncaughtErrorEvent> = [];
		__lastWatcher = event -> reports.push(event);
		runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, __lastWatcher);
		return reports;
	}

	// Pumps `times`, returning whatever escaped rather than letting it end the
	// test, so a failure to contain is an assertion rather than an error.
	private static function __pump(runtime:CrossByte, times:Int, delta:Float):Dynamic {
		var escaped:Dynamic = null;
		for (_ in 0...times) {
			try {
				runtime.pump(delta, 0);
			} catch (e:Dynamic) {
				escaped = e;
			}
		}
		return escaped;
	}

	private function __errorLines(containing:String):Int {
		var count = 0;
		for (line in logged) {
			if (line.indexOf("[ERROR]") >= 0 && line.indexOf(containing) >= 0) {
				count++;
			}
		}
		return count;
	}
}

private class Counted implements PassFlush {
	private var onFlush:Void->Void;

	public function new(onFlush:Void->Void) {
		this.onFlush = onFlush;
	}

	public function __flushPass():Void {
		onFlush();
	}
}
