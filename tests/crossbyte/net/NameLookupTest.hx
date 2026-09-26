package crossbyte.net;

import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	Connecting to a name, and sending to one, without the runtime waiting on
	the resolver.

	A name was looked up in the call, on the runtime's thread, so every socket
	and timer on it waited for as long as the resolver took: a second, for a
	name that does not exist, measured. A datagram socket looked its
	destination up again for every datagram. Now a name is looked up on a
	thread of its own and the answer handed back to the runtime, so a call
	given one returns at once, and a name that does not resolve is reported
	afterwards rather than from inside the call.

	The names that do not resolve are under `.invalid`, which never does (RFC
	6761), and fresh each run, so no resolver has the answer cached.
**/
class NameLookupTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	// Long enough for a thread to start on a loaded machine, and well short
	// of the second a failing lookup took on the runtime's thread.
	private static inline var PROMPT:Float = 0.5;

	@:timeout(20000)
	public function testASocketConnectingToAMissingNameIsNotHeldByTheLookup(async:Async):Void {
		var socket = new Socket();
		var name:String = __missingName();
		var failures:Array<String> = [];
		var inCall:Bool = true;
		var reportedInCall:Bool = false;

		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			if (inCall) {
				reportedInCall = true;
			}
			failures.push(e.text);
		});

		var started:Float = haxe.Timer.stamp();
		socket.connect(name, 80);
		var spent:Float = haxe.Timer.stamp() - started;
		inCall = false;

		Assert.isFalse(reportedInCall, "the failed lookup was reported from inside connect(), so connect() waited for it");
		Assert.isTrue(spent < PROMPT, 'connect() spent $spent s on a name: it waited on the resolver');

		NetPump.until(() -> failures.length > 0, 15.0, function(_) {
			Assert.equals(1, failures.length, "a name that does not resolve was not reported exactly once");
			#if !nodejs
			Assert.isTrue(failures.length > 0 && failures[0].indexOf(name) >= 0, "the failure does not name what did not resolve: " + failures[0]);
			#end
			Assert.isFalse(socket.connected);
			async.done();
		});
	}

	/**
		The runtime goes on while a slow lookup runs.

		A single label with no domain is the slow case on Windows: when DNS
		has no answer the resolver tries LLMNR and NetBIOS as well, and a name
		nobody has took 6.8 seconds to fail, all of it spent inside
		`connect()`, with every socket and timer on the runtime waiting. Where
		the resolver answers quickly this passes either way.
	**/
	@:timeout(40000)
	public function testTheRuntimeRunsWhileASlowLookupDoes(async:Async):Void {
		var socket = new Socket();
		var name:String = "crossbyte-missing-" + Std.random(0x3FFFFFFF);
		var failed:Bool = false;
		var ticks:Int = 0;
		var runtime = crossbyte.core.CrossByte.current();
		var onTick = function(_) ticks++;
		runtime.addEventListener(crossbyte.events.TickEvent.TICK, onTick);
		socket.addEventListener(IOErrorEvent.IO_ERROR, function(_) failed = true);

		var started:Float = haxe.Timer.stamp();
		socket.connect(name, 80);
		var spent:Float = haxe.Timer.stamp() - started;

		Assert.isTrue(spent < PROMPT, 'connect() spent $spent s on a name: the runtime waited on the resolver');

		NetPump.until(() -> failed, 35.0, function(_) {
			runtime.removeEventListener(crossbyte.events.TickEvent.TICK, onTick);
			Assert.isTrue(failed, "a name that does not resolve was never reported");
			Assert.isTrue(ticks > 1, 'the runtime ticked $ticks times while the name was looked up');
			async.done();
		});
	}

	@:timeout(15000)
	public function testASocketConnectsToAName(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var connected:Bool = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, function(_) connected = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			#if !nodejs
			var lookups:Int = crossbyte._internal.net.Resolver.__started;
			#end
			client.connect("localhost", server.localPort);
			#if !nodejs
			Assert.equals(lookups + 1, crossbyte._internal.net.Resolver.__started, "the name was not looked up off the runtime's thread");
			#end

			NetPump.until(() -> (connected && accepted.length > 0) || failure != null, 10.0, function(_) {
				Assert.isTrue(connected, "a socket given a name never connected: " + failure);
				Assert.equals(1, accepted.length);
				try client.close() catch (_:Dynamic) {}
				for (socket in accepted) {
					try socket.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm || nodejs)
	@:timeout(20000)
	public function testAWebSocketConnectingToAMissingNameIsNotHeldByTheLookup(async:Async):Void {
		var client = new WebSocket();
		var name:String = __missingName();
		var failure:String = null;
		var closed:Bool = false;

		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) closed = true);

		var started:Float = haxe.Timer.stamp();
		client.connect(name, 80);
		var spent:Float = haxe.Timer.stamp() - started;

		Assert.isTrue(spent < PROMPT, 'connect() spent $spent s on a name: it waited on the resolver');

		NetPump.until(() -> failure != null && closed, 15.0, function(_) {
			Assert.notNull(failure, "a name that does not resolve was never reported");
			Assert.isTrue(closed, "a session whose name did not resolve was never closed");
			#if !nodejs
			Assert.isTrue(failure != null && failure.indexOf(name) >= 0, "the failure does not name what did not resolve: " + failure);
			#end
			async.done();
		});
	}

	@:timeout(15000)
	public function testAWebSocketConnectsToAName(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new WebSocket();
			var opened:Bool = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			#if !nodejs
			var lookups:Int = crossbyte._internal.net.Resolver.__started;
			#end
			client.connect("localhost", server.localPort);
			#if !nodejs
			Assert.equals(lookups + 1, crossbyte._internal.net.Resolver.__started, "the name was not looked up off the runtime's thread");
			#end

			NetPump.until(() -> (opened && sessions.length > 0) || failure != null, 10.0, function(_) {
				Assert.isTrue(opened, "a WebSocket given a name never opened: " + failure);
				Assert.equals(1, sessions.length);
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				NetPump.wait(0.1, () -> async.done());
			});
		});
	}

	@:timeout(20000)
	public function testADatagramToAMissingNameIsReportedNotThrown(async:Async):Void {
		var socket = new DatagramSocket();
		var name:String = __missingName();
		var failures:Array<String> = [];
		var thrown:Dynamic = null;
		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failures.push(e.text));

		var payload = new ByteArray();
		payload.writeUTFBytes("hello");

		var started:Float = haxe.Timer.stamp();
		try {
			socket.send(payload, 0, 0, name, 9);
		} catch (e:Dynamic) {
			thrown = e;
		}
		var spent:Float = haxe.Timer.stamp() - started;

		Assert.isNull(thrown, "send() looked the name up in the call and threw: " + thrown);
		Assert.isTrue(spent < PROMPT, 'send() spent $spent s on a name: it waited on the resolver');

		NetPump.until(() -> failures.length > 0, 15.0, function(_) {
			Assert.isTrue(failures.length > 0, "a datagram to a name that does not resolve was dropped without a word");
			Assert.isTrue(failures.length > 0 && failures[0].indexOf(name) >= 0, "the failure does not name what did not resolve: " + failures[0]);
			socket.close();
			async.done();
		});
	}

	@:timeout(15000)
	public function testDatagramsToANameArriveAndItIsLookedUpOnce(async:Async):Void {
		var receiver = new DatagramSocket();
		var received:Array<String> = [];
		receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) received.push(e.data.readUTFBytes(e.data.length)));
		receiver.bind(0, "127.0.0.1");
		receiver.receive();

		var sender = new DatagramSocket();
		var failures:Array<String> = [];
		sender.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failures.push(e.text));

		NetPump.until(() -> receiver.localPort != 0, 5.0, function(_) {
			#if !nodejs
			var lookups:Int = crossbyte._internal.net.Resolver.__started;
			#end

			// Three at once, before any answer can have come back, and one
			// more once it has.
			for (i in 0...3) {
				var payload = new ByteArray();
				payload.writeUTFBytes("datagram " + i);
				sender.send(payload, 0, 0, "localhost", receiver.localPort);
			}

			NetPump.until(() -> received.length >= 3 || failures.length > 0, 10.0, function(_) {
				var payload = new ByteArray();
				payload.writeUTFBytes("datagram 3");
				sender.send(payload, 0, 0, "localhost", receiver.localPort);

				NetPump.until(() -> received.length >= 4 || failures.length > 0, 10.0, function(_) {
					Assert.same([], failures);
					received.sort(Reflect.compare);
					Assert.same(["datagram 0", "datagram 1", "datagram 2", "datagram 3"], received,
						"datagrams sent to a name while it was looked up did not all arrive");
					#if !nodejs
					Assert.equals(lookups + 1, crossbyte._internal.net.Resolver.__started,
						"the name was not looked up exactly once for four datagrams");
					#end
					sender.close();
					receiver.close();
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm)
	@:timeout(20000)
	public function testAReliableConnectToAMissingNameIsReportedNotThrown(async:Async):Void {
		var client = new ReliableDatagramSocket();
		var name:String = __missingName();
		var failure:String = null;
		var closed:Bool = false;
		var thrown:Dynamic = null;
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) closed = true);

		var started:Float = haxe.Timer.stamp();
		try {
			client.connect(name, 9);
		} catch (e:Dynamic) {
			thrown = e;
		}
		var spent:Float = haxe.Timer.stamp() - started;

		Assert.isNull(thrown, "connect() looked the name up in the call and threw: " + thrown);
		Assert.isTrue(spent < PROMPT, 'connect() spent $spent s on a name: it waited on the resolver');

		NetPump.until(() -> failure != null && closed, 15.0, function(_) {
			Assert.isTrue(failure != null && failure.indexOf(name) >= 0, "the failure does not name what did not resolve: " + failure);
			Assert.isTrue(closed, "a session whose name did not resolve was not closed");
			async.done();
		});
	}

	@:timeout(15000)
	public function testAReliableSessionConnectsToAName(async:Async):Void {
		var server = new ReliableDatagramServerSocket();
		var accepted:Array<ReliableDatagramSocket> = [];
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent) accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new ReliableDatagramSocket();
		var connected:Bool = false;
		var failure:String = null;
		client.addEventListener(Event.CONNECT, function(_) connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);

		NetPump.until(() -> server.localPort > 0, 5.0, function(_) {
			var lookups:Int = crossbyte._internal.net.Resolver.__started;
			client.connect("localhost", server.localPort);
			Assert.equals(lookups + 1, crossbyte._internal.net.Resolver.__started, "the name was not looked up off the runtime's thread");

			NetPump.until(() -> (connected && accepted.length > 0) || failure != null, 10.0, function(_) {
				Assert.isTrue(connected, "a reliable session given a name never connected: " + failure);
				Assert.equals("127.0.0.1", client.remoteAddress, "the session does not report the address its name resolved to");
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				NetPump.wait(0.1, () -> async.done());
			});
		});
	}
	#end

	private static function __missingName():String {
		return "crossbyte-" + Std.random(0x3FFFFFFF) + "-" + Std.random(0x3FFFFFFF) + ".invalid";
	}
}
