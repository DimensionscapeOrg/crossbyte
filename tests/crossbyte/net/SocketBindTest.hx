package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.http.HTTPTestSupport;
import utest.Async;
#end
import utest.Assert;

/**
	`Socket.bind`: where a connection leaves from, chosen before it is made,
	and what is said when that cannot be.
**/
@:timeout(15000)
class SocketBindTest extends utest.Test {
	#if (js && !nodejs)
	public function testABrowserRefusesIt():Void {
		Assert.raises(() -> new Socket().bind(0, "127.0.0.1"), IllegalOperationError);
	}
	#else
	public function testWhatCannotBeBoundIsRefusedAtOnce():Void {
		var socket:Socket = new Socket();
		Assert.raises(() -> socket.bind(-1, "127.0.0.1"), RangeError);
		Assert.raises(() -> socket.bind(65536, "127.0.0.1"), RangeError);
		Assert.raises(() -> socket.bind(0, "localhost"), ArgumentError);
		Assert.raises(() -> socket.bind(0, "not an address"), ArgumentError);
	}

	/** The port asked for is the one the server sees. **/
	public function testAConnectionLeavesFromTheBoundPort(async:Async):Void {
		__freePort(function(free:Int):Void {
			__connectFrom(free, "127.0.0.1", "127.0.0.1", function(outcome:Outcome):Void {
				Assert.isNull(outcome.failure, "the connection failed: " + outcome.failure);
				Assert.equals(free, outcome.serverSawPort, "the server saw another port");
				Assert.equals(free, outcome.localPort);
				async.done();
			});
		});
	}

	/**
		The address asked for is the one the server sees: all of 127/8 is this
		machine on Linux and Windows, and macOS has only 127.0.0.1 until told
		otherwise, where this says so rather than failing.
	**/
	public function testAConnectionLeavesFromTheBoundAddress(async:Async):Void {
		__connectFrom(0, "127.0.0.2", "127.0.0.1", function(outcome:Outcome):Void {
			if (outcome.failure != null) {
				if (Sys.systemName() == "Mac") {
					Assert.warn("127.0.0.2 is not this machine here; the case did not run");
				} else {
					Assert.fail("the connection failed: " + outcome.failure);
				}
				async.done();
				return;
			}
			Assert.equals("127.0.0.2", outcome.serverSawAddress, "the server saw another address");
			Assert.equals("127.0.0.2", outcome.localAddress);
			Assert.isTrue(outcome.serverSawPort > 0);
			async.done();
		});
	}

	/** It holds for each connect after it, and `bind()` itself lets go of it. **/
	public function testItHoldsUntilItIsSetAgain(async:Async):Void {
		var server:ServerSocket = new ServerSocket();
		var seen:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> {
			seen.push(e.socket.remoteAddress);
			e.socket.close();
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		var closes:Int = 0;
		var socket:Socket = new Socket();
		socket.addEventListener(Event.CONNECT, _ -> socket.close());
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> closes = 100);
		socket.addEventListener(Event.CLOSE, _ -> closes++);

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort > 0, 5.0, function(_):Void {
			socket.bind(0, "127.0.0.1");
			socket.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> closes >= 1, 5.0, function(_):Void {
				socket.connect("127.0.0.1", server.localPort);
				HTTPTestSupport.pumpUntilAsync(() -> closes >= 2, 5.0, function(_):Void {
					socket.bind();
					socket.connect("127.0.0.1", server.localPort);
					HTTPTestSupport.pumpUntilAsync(() -> closes >= 3 && seen.length >= 3, 5.0, function(_):Void {
						server.close();
						Assert.equals(3, closes, "a connection failed");
						Assert.equals("127.0.0.1,127.0.0.1,127.0.0.1", seen.join(","));
						async.done();
					});
				});
			});
		});
	}

	/** Once connected it is too late, as it says, rather than taking effect on some later connect. **/
	public function testItIsTooLateOnceConnected(async:Async):Void {
		var server:ServerSocket = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();
		var socket:Socket = new Socket();
		var refused:Bool = false;
		var connected:Bool = false;
		socket.addEventListener(Event.CONNECT, function(_):Void {
			connected = true;
			try {
				socket.bind(0, "127.0.0.1");
			} catch (_:IllegalOperationError) {
				refused = true;
			}
		});
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort > 0, 5.0, function(_):Void {
			socket.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> connected, 5.0, function(_):Void {
				try socket.close() catch (_:Dynamic) {}
				server.close();
				Assert.isTrue(connected, "the connection failed");
				Assert.isTrue(refused, "bind on a connected socket was taken");
				async.done();
			});
		});
	}

	/** An address this machine does not have is what `connect` reports: an `ioError`, and no `close`. **/
	public function testAnAddressNotHereIsAnIoError(async:Async):Void {
		__connectFrom(0, "192.0.2.1", "127.0.0.1", function(outcome:Outcome):Void {
			Assert.notNull(outcome.failure, "a connection left from an address this machine does not have");
			Assert.equals(0, outcome.closes, "a failed connect was closed");
			async.done();
		});
	}

	/** A port another socket holds, likewise. **/
	public function testAPortInUseIsAnIoError(async:Async):Void {
		var holder:ServerSocket = new ServerSocket();
		holder.bind(0, "127.0.0.1");
		holder.listen();
		HTTPTestSupport.pumpUntilAsync(() -> holder.localPort > 0, 5.0, function(_):Void {
			__connectFrom(holder.localPort, "127.0.0.1", "127.0.0.1", function(outcome:Outcome):Void {
				holder.close();
				Assert.notNull(outcome.failure, "a connection left from a port another socket holds");
				async.done();
			});
		});
	}

	#if !(neko || hl || eval)
	/** IPv6 too, which a native connect makes a socket anew for, and must not here. **/
	public function testAnIPv6AddressIsBound(async:Async):Void {
		__freePort(function(free:Int):Void {
			__connectFrom(free, "::1", "::1", function(outcome:Outcome):Void {
				if (outcome.noServer) {
					Assert.warn("no IPv6 loopback on this machine; the case did not run");
					async.done();
					return;
				}
				Assert.isNull(outcome.failure, "the connection failed: " + outcome.failure);
				Assert.equals(free, outcome.serverSawPort, "the bind was lost connecting to IPv6");
				async.done();
			}, "::1");
		}, "::1");
	}

	/** Bound to one family, a host of the other cannot be reached, and it says so rather than letting go of the bind. **/
	public function testAnAddressOfTheOtherFamilyIsAnIoError(async:Async):Void {
		__connectFrom(0, "127.0.0.1", "::1", function(outcome:Outcome):Void {
			if (outcome.noServer) {
				Assert.warn("no IPv6 loopback on this machine; the case did not run");
				async.done();
				return;
			}
			Assert.notNull(outcome.failure, "a socket bound to IPv4 reached an IPv6 host");
			async.done();
		}, "::1");
	}
	#end

	#if (cpp || java || jvm)
	/** Over TLS, whose socket is another class on each target, the connection leaves from the bound port too. **/
	public function testASecureConnectionLeavesFromTheBoundPort(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		__freePort(function(free:Int):Void {
			var server:ServerSocket = new ServerSocket(true);
			server.setCertificate(fixture.certificate, fixture.key);
			var sawPort:Int = -1;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> sawPort = e.socket.remotePort);
			server.bind(0, "127.0.0.1");
			server.listen();

			var socket:Socket = new Socket();
			socket.secure = true;
			socket.verifyCert = false;
			var failure:Null<String> = null;
			socket.addEventListener(IOErrorEvent.IO_ERROR, e -> failure = e.text);
			socket.bind(free, "127.0.0.1");
			socket.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> sawPort >= 0 || failure != null, 8.0, function(_):Void {
				try socket.close() catch (_:Dynamic) {}
				server.close();
				Assert.isNull(failure, "the connection failed: " + failure);
				Assert.equals(free, sawPort, "the server saw another port");
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm)
	/** Over TLS to an IPv6 host, if this target's TLS goes there at all: the bind is kept, or it says so. **/
	public function testASecureConnectionToIPv6IsBoundOrRefused(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			async.done();
			return;
		}

		__freePort(function(free:Int):Void {
			if (free == 0) {
				Assert.warn("no IPv6 loopback on this machine; the case did not run");
				async.done();
				return;
			}
			var server:ServerSocket = new ServerSocket(true);
			server.setCertificate(fixture.certificate, fixture.key);
			var sawPort:Int = -1;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> sawPort = e.socket.remotePort);
			server.bind(0, "::1");
			server.listen();

			var socket:Socket = new Socket();
			socket.secure = true;
			socket.verifyCert = false;
			var failure:Null<String> = null;
			socket.addEventListener(IOErrorEvent.IO_ERROR, e -> failure = e.text);
			socket.bind(free, "::1");
			socket.connect("::1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> sawPort >= 0 || failure != null, 8.0, function(finished:Bool):Void {
				try socket.close() catch (_:Dynamic) {}
				server.close();
				Assert.isTrue(finished, "the connection neither came up nor failed");
				if (failure == null) {
					Assert.equals(free, sawPort, "the bind was lost connecting to IPv6 over TLS");
				}
				async.done();
			});
		}, "::1");
	}
	#end

	/** A port nothing is using just now: bound to find it, then let go of. **/
	private function __freePort(then:Int->Void, address:String = "127.0.0.1"):Void {
		var finder:ServerSocket = new ServerSocket();
		try {
			finder.bind(0, address);
			finder.listen();
		} catch (_:Dynamic) {
			then(0);
			return;
		}
		HTTPTestSupport.pumpUntilAsync(() -> finder.localPort > 0, 5.0, function(_):Void {
			var port:Int = finder.localPort;
			finder.close();
			then(port);
		});
	}

	/** Connects to a listener at `serverAddress`, leaving from `localAddress` and `localPort`, and says what came of it. **/
	private function __connectFrom(localPort:Int, localAddress:String, target:String, then:Outcome->Void, serverAddress:String = "127.0.0.1"):Void {
		var outcome:Outcome = new Outcome();
		var server:ServerSocket = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			outcome.serverSawPort = e.socket.remotePort;
			outcome.serverSawAddress = e.socket.remoteAddress;
		});
		try {
			server.bind(0, target.indexOf(":") >= 0 ? target : serverAddress);
			server.listen();
		} catch (_:Dynamic) {
			outcome.noServer = true;
			then(outcome);
			return;
		}

		var socket:Socket = new Socket();
		socket.addEventListener(IOErrorEvent.IO_ERROR, e -> outcome.failure = e.text);
		socket.addEventListener(Event.CLOSE, _ -> outcome.closes++);
		socket.addEventListener(Event.CONNECT, function(_):Void {
			outcome.localPort = socket.localPort;
			outcome.localAddress = socket.localAddress;
		});

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort > 0, 5.0, function(_):Void {
			socket.bind(localPort, localAddress);
			socket.connect(target, server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> outcome.serverSawPort >= 0 || outcome.failure != null, 5.0, function(_):Void {
				try socket.close() catch (_:Dynamic) {}
				// Whatever the server's end of it holds of the port goes with it.
				HTTPTestSupport.pumpMoreAsync(2, function():Void {
					server.close();
					then(outcome);
				});
			});
		});
	}
	#end
}

#if !(js && !nodejs)
private class Outcome {
	public var failure:Null<String> = null;
	public var closes:Int = 0;
	public var serverSawPort:Int = -1;
	public var serverSawAddress:Null<String> = null;
	public var localPort:Int = -1;
	public var localAddress:Null<String> = null;
	public var noServer:Bool = false;

	public function new() {}
}
#end
