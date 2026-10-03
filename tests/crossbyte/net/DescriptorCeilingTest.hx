package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	Sockets numbered past `select`'s ceiling, FD_SETSIZE (1,024), on Linux
	and macOS.

	`select` takes no descriptor at or past it there, and hxcpp refuses one
	rather than overflow its set: "Socket descriptor too large for select
	(use poll)". CrossByte asks `select` about single sockets in several
	places, whether a connect has finished, whether a listener has a
	connection waiting, so in a process holding a thousand descriptors,
	the newer sockets failed there. The load harness's idle scenario found
	it on Linux: each process of WebSocket clients stopped at 1,018
	connections, every one after failing to connect.

	These open descriptors first, so that the sockets made after them land
	past the ceiling, where the system allows that many: Linux does, and
	macOS's default limit of 256 does not, so there they test nothing more
	than any other case. Windows has no such ceiling, a set there is a
	counted array, and runs the same cases as a check that nothing else
	changed.
**/
class DescriptorCeilingTest extends utest.Test {
	#if cpp
	private static inline var FILLER:Int = 1100;

	private var __filler:Array<sys.io.FileInput> = [];

	/** Opens FILLER descriptors on Linux and macOS, if the system allows. **/
	private function __fill():Void {
		if (crossbyte.sys.System.isWindows) {
			return;
		}
		try {
			for (_ in 0...FILLER) {
				__filler.push(sys.io.File.read("/dev/null", true));
			}
		} catch (_:Dynamic) {
			// A limit below FILLER, as macOS's default is: nothing to cross.
			__release();
		}
	}

	private function __release():Void {
		for (file in __filler) {
			try file.close() catch (_:Dynamic) {}
		}
		__filler = [];
	}

	public function teardown():Void {
		__release();
	}

	public function testSelectAnswersForASocketPastTheCeiling():Void {
		__fill();
		var listener = new sys.net.Socket();
		var client = new sys.net.Socket();
		var accepted:Null<sys.net.Socket> = null;
		var ready:Dynamic = null;
		var failure:Dynamic = null;
		try {
			listener.bind(new sys.net.Host("127.0.0.1"), 0);
			listener.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), listener.host().port);
			accepted = listener.accept();
			client.output.writeByte(7);
			client.output.flush();
			ready = sys.net.Socket.select([accepted], [], [], 5.0);
		} catch (error:Dynamic) {
			failure = error;
		}
		for (socket in [listener, client, accepted]) {
			if (socket != null) {
				try socket.close() catch (_:Dynamic) {}
			}
		}
		__release();

		Assert.isNull(failure, "select refused a socket: " + failure);
		if (ready != null) {
			Assert.equals(1, (ready.read : Array<sys.net.Socket>).length, "the socket with a byte waiting was not readable");
		}
	}

	/**
		A WebSocket client whose socket is past the ceiling connects: its
		connect was asked about through `select`, which threw, and the
		attempt failed.
	**/
	@:timeout(30000)
	public function testAWebSocketClientPastTheCeilingConnects(async:Async):Void {
		__fill();
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> sessions.push(cast event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		var connected:Bool = false;
		var failure:Null<String> = null;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, event -> failure = event.text);
		client.connect("127.0.0.1", server.localPort);

		NetPump.until(() -> (connected && sessions.length > 0) || failure != null, 15.0, function(_) {
			Assert.isNull(failure, "the client failed: " + failure);
			Assert.isTrue(connected, "the client never connected");
			try client.close() catch (_:Dynamic) {}
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			__release();
			async.done();
		});
	}

	/**
		A server listening on a socket past the ceiling accepts: before it
		accepts it asks select whether a connection is waiting, which threw,
		so a listener opened in a process already holding a thousand
		descriptors, a second service, a listener per match, took none.
	**/
	@:timeout(30000)
	public function testAServerSocketPastTheCeilingAccepts(async:Async):Void {
		__fill();
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> accepted.push(event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		var client = new sys.net.Socket();
		var failure:Dynamic = null;
		try {
			client.connect(new sys.net.Host("127.0.0.1"), server.localPort);
		} catch (error:Dynamic) {
			failure = error;
		}

		NetPump.until(() -> accepted.length > 0 || failure != null, 10.0, function(_) {
			Assert.isNull(failure, "the client could not connect: " + failure);
			Assert.equals(1, accepted.length, "the server accepted nothing");
			try client.close() catch (_:Dynamic) {}
			for (socket in accepted) {
				try socket.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			__release();
			async.done();
		});
	}

	/**
		A `Socket` client whose socket is past the ceiling connects: whether
		its connect had finished was asked of select, which threw.
	**/
	@:timeout(30000)
	public function testASocketClientPastTheCeilingConnects(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> accepted.push(event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		// The listener exists now; the client made from here is past the
		// ceiling.
		__fill();

		var client = new Socket();
		var connected:Bool = false;
		var failure:Null<String> = null;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, event -> failure = event.text);
		client.connect("127.0.0.1", server.localPort);

		NetPump.until(() -> (connected && accepted.length > 0) || failure != null, 15.0, function(_) {
			Assert.isNull(failure, "the client failed: " + failure);
			Assert.isTrue(connected, "the client never connected");
			try client.close() catch (_:Dynamic) {}
			for (socket in accepted) {
				try socket.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			__release();
			async.done();
		});
	}
	#else
	public function testOnlyNative():Void {
		// hxcpp's select is the one with the ceiling; the other targets'
		// sockets are polled without it.
		Assert.pass();
	}
	#end
}
