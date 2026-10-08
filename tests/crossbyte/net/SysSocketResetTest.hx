package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	A connection its peer has reset fails each read and write with an error
	the caller can catch, on every target, and a socket call that fails
	otherwise does too.

	On eval a failed `send`, `recv`, `shutdown` or `bind` must not be an
	error that passes every Haxe `catch` and ends the interpreter, and on
	Linux a write to a connection the peer had closed must not end it with
	SIGPIPE: a development server would end over one client's reset, and
	a `ServerSocket.bind` to a port in use would end the program it was
	meant to report to. Each case has to come back.
**/
class SysSocketResetTest extends utest.Test {
	#if (sys && !(js || php))
	private static inline var WAIT:Float = 5.0;

	public function testAWriteToAResetConnectionThrows():Void {
		var pair = __resetPair();
		if (pair == null) {
			return;
		}

		// Twice: on Linux the second meets a connection whose error the
		// first took, which is where SIGPIPE comes from.
		for (attempt in 0...2) {
			var thrown:Dynamic = null;
			try {
				pair.client.output.writeBytes(Bytes.ofString("after the reset"), 0, 15);
			} catch (e:Dynamic) {
				thrown = e;
			}
			Assert.notNull(thrown, 'write $attempt to a reset connection succeeded');
		}
		__close(pair);
	}

	public function testAReadOfAResetConnectionThrows():Void {
		var pair = __resetPair();
		if (pair == null) {
			return;
		}

		var thrown:Dynamic = null;
		var read:Int = -1;
		try {
			read = pair.client.input.readBytes(Bytes.alloc(16), 0, 16);
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.notNull(thrown, 'a read of a reset connection read $read bytes');
		__close(pair);
	}

	/**
		An orderly close by the peer, then writes: the first reaches the
		peer's system, which answers it with a reset, and a later one has to
		fail with an error that can be caught, not one past every catch (eval
		on Windows) or SIGPIPE (Linux).
	**/
	public function testWritesToAConnectionThePeerClosedThrow():Void {
		var server = new sys.net.Socket();
		var client = new sys.net.Socket();
		var peer:sys.net.Socket = null;
		var failures:Int = 0;
		try {
			server.bind(new sys.net.Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), server.host().port);
			peer = server.accept();
			peer.close();
			Assert.isTrue(__readable(client), "the peer's close never reached the client");

			for (attempt in 0...3) {
				try {
					client.output.writeBytes(Bytes.ofString("into a closed connection"), 0, 24);
				} catch (_:Dynamic) {
					failures++;
				}
				// Time for the peer's answer, a reset, to come back.
				crossbyte.sys.System.sleep(0.2);
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		Assert.isTrue(failures > 0, "every write to a connection the peer closed succeeded");

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	/** A shutdown of a reset connection fails with an error that can be caught, on eval on Linux too. **/
	public function testAShutdownOfAResetConnectionComesBack():Void {
		var pair = __resetPair();
		if (pair == null) {
			return;
		}

		var outcome:String = try {
			pair.client.shutdown(false, true);
			"returned";
		} catch (e:Dynamic) {
			"threw " + Std.string(e);
		}
		Assert.notNull(outcome);
		__close(pair);
	}

	public function testABindToAPortInUseThrows():Void {
		var holder = new sys.net.Socket();
		var second = new sys.net.Socket();
		try {
			holder.bind(new sys.net.Host("127.0.0.1"), 0);
			holder.listen(1);
			var port:Int = holder.host().port;

			var thrown:Dynamic = null;
			try {
				second.bind(new sys.net.Host("127.0.0.1"), port);
			} catch (e:Dynamic) {
				thrown = e;
			}
			Assert.notNull(thrown, "a second socket was bound to a port a listener holds");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try second.close() catch (_:Dynamic) {}
		try holder.close() catch (_:Dynamic) {}
	}

	/**
		The same through a `ServerSocket`, which says so with the `IOError`
		its `bind` promises.
	**/
	public function testAServerBoundToAPortInUseThrowsAnIOError():Void {
		var holder = new ServerSocket();
		holder.bind(0, "127.0.0.1");
		holder.listen();

		var second = new ServerSocket();
		var thrown:Dynamic = null;
		try {
			second.bind(holder.localPort, "127.0.0.1");
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IOError), "a bind to a port in use threw " + thrown);
		try second.close() catch (_:Dynamic) {}
		try holder.close() catch (_:Dynamic) {}
	}

	/**
		A select that names a closed socket comes back (with an error, or
		without the socket) rather than ending the process. eval and hxcpp
		throw; hl leaves a closed socket out.
	**/
	public function testASelectOnAClosedSocketComesBack():Void {
		var socket = new sys.net.Socket();
		socket.close();

		var outcome:String = try {
			var ready = sys.net.Socket.select([socket], [], [], 0);
			ready.read.length == 0 ? "answered" : "answered with the closed socket";
		} catch (e:Dynamic) {
			"threw";
		}
		Assert.notEquals("answered with the closed socket", outcome);
	}

	/**
		A server whose client resets: the connection's `close` is dispatched
		and the runtime goes on, on every target. On eval the read the reset
		made ready must not end the interpreter.
	**/
	@:timeout(20000)
	public function testAServerGoesOnPastAClientThatResets(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted = e.socket;
			// Left unread by the client, so its close is a reset.
			accepted.writeUTFBytes("never read");
			accepted.flush();
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new sys.net.Socket();
		client.connect(new sys.net.Host("127.0.0.1"), server.localPort);

		NetPump.until(() -> accepted != null && __readable(client, 0), WAIT, function(_) {
			if (accepted == null) {
				Assert.fail("the connection was never accepted");
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
				return;
			}

			var ended:Bool = false;
			accepted.addEventListener(Event.CLOSE, _ -> ended = true);
			accepted.addEventListener(IOErrorEvent.IO_ERROR, _ -> ended = true);
			client.close();

			NetPump.until(() -> ended, WAIT, function(_) {
				Assert.isTrue(ended, "the reset connection was never ended");
				// And the server still takes connections.
				var next = new Socket();
				var connected:Bool = false;
				next.addEventListener(Event.CONNECT, _ -> connected = true);
				next.connect("127.0.0.1", server.localPort);
				NetPump.until(() -> connected, WAIT, function(_) {
					Assert.isTrue(connected, "the server stopped taking connections after a client reset");
					try next.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	/**
		A client whose peer has reset the connection, the reset arrived: the
		peer closed with bytes it had not read, which makes a close a reset.
		Null, after failing, if the pair could not be made.
	**/
	private static function __resetPair():Null<ResetPair> {
		var server = new sys.net.Socket();
		var client = new sys.net.Socket();
		try {
			server.bind(new sys.net.Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), server.host().port);
			var peer = server.accept();

			client.output.writeBytes(Bytes.ofString("unread"), 0, 6);
			client.output.flush();
			if (!__readable(peer)) {
				Assert.fail("the bytes never reached the peer");
				return null;
			}
			peer.close();
			if (!__readable(client)) {
				Assert.fail("the reset never reached the client");
				return null;
			}
			return {server: server, client: client};
		} catch (e:Dynamic) {
			Assert.fail("could not make a reset connection: " + Std.string(e));
			try client.close() catch (_:Dynamic) {}
			try server.close() catch (_:Dynamic) {}
			return null;
		}
	}

	private static function __readable(socket:sys.net.Socket, seconds:Float = WAIT):Bool {
		return sys.net.Socket.select([socket], [], [], seconds).read.length > 0;
	}

	private static function __close(pair:ResetPair):Void {
		try pair.client.close() catch (_:Dynamic) {}
		try pair.server.close() catch (_:Dynamic) {}
	}
	#end
}

#if (sys && !(js || php))
private typedef ResetPair = {
	var server:sys.net.Socket;
	var client:sys.net.Socket;
}
#end
