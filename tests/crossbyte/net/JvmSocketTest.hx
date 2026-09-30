package crossbyte.net;

#if (java || jvm)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import java.net.InetSocketAddress;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import utest.Assert;

/**
	The jvm's `sys.net.Socket`, which CrossByte supplies itself over NIO:
	connects and `select`, measured by what they do to the thread calling them.
**/
class JvmSocketTest extends utest.Test {
	/**
		A connect the peer is slow to answer leaves the runtime running. It
		spun on `finishConnect()` until the connection came up: two seconds
		of the runtime's thread against a listener whose queue was full, and
		the whole SYN-retry time, 21 s on Windows, two minutes on Linux,
		against a host that never answers. Natively a connect in progress
		returns at once and the tick finishes it; so does this now.
	**/
	public function testAConnectToABusyListenerLeavesTheRuntimeRunning():Void {
		var runtime = crossbyte.core.CrossByte.current();
		var busy = __busyListener();

		var socket = new crossbyte.net.Socket();
		var connected = false;
		var failure:String = null;
		socket.addEventListener(Event.CONNECT, function(_) connected = true);
		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);

		var started = haxe.Timer.stamp();
		socket.connect("127.0.0.1", busy.port);
		var took = haxe.Timer.stamp() - started;

		// Now make room, and let the tick see the connect through.
		var deadline = haxe.Timer.stamp() + 15;
		while (!connected && failure == null && haxe.Timer.stamp() < deadline) {
			busy.drain();
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.005);
		}

		try {
			socket.close();
		} catch (_:Dynamic) {}
		busy.close();

		Assert.isTrue(took < 0.25, 'connect() held the runtime thread for ${Math.round(took * 1000)} ms');
		Assert.isTrue(connected, "the connect never completed once the listener made room: " + failure);
	}

	/**
		A blocking connect gives up at the socket's timeout, as a read does.
		It was bounded by the system alone, so an https request to a host that
		never answered waited out the SYN retries whatever its timeout said.
	**/
	public function testABlockingConnectGivesUpAtItsTimeout():Void {
		var busy = __busyListener();

		var socket = new sys.net.Socket();
		socket.setTimeout(0.2);
		var failure:String = null;
		var started = haxe.Timer.stamp();
		try {
			socket.connect(new sys.net.Host("127.0.0.1"), busy.port);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		var took = haxe.Timer.stamp() - started;

		try {
			socket.close();
		} catch (_:Dynamic) {}
		busy.close();

		Assert.notNull(failure, "a connect to a full listen queue succeeded within its 0.2 s timeout");
		Assert.isTrue(took < 1.0, 'a connect with a 0.2 s timeout gave up after ${Math.round(took * 1000)} ms');
	}

	/**
		`select` answers only for the sockets it is asked about. A socket stays
		registered from one call to the next now, so one asked about earlier
		and ready since must neither be reported by a later call that did not
		ask about it nor cut that call's wait short.
	**/
	public function testSelectAnswersOnlyForTheSocketsItIsAskedAbout():Void {
		var pairs = __pairs(2);
		var a = pairs.servers[0];
		var b = pairs.servers[1];
		pairs.clients[0].output.writeByte(1);

		var first = sys.net.Socket.select([a, b], null, null, 2.0);
		var started = haxe.Timer.stamp();
		var second = sys.net.Socket.select([b], null, null, 0.3);
		var waited = haxe.Timer.stamp() - started;
		var third = sys.net.Socket.select([a, b], null, null, 2.0);
		pairs.close();

		Assert.isTrue(first.read.length == 1 && first.read[0] == a, "the readable socket was not the one reported: " + first.read.length);
		Assert.equals(0, second.read.length, "a socket not asked about was reported");
		Assert.isTrue(waited >= 0.2, 'a socket not asked about ended the wait after ${Math.round(waited * 1000)} ms of 300');
		Assert.isTrue(third.read.length == 1 && third.read[0] == a, "a socket asked about again was not reported");
	}

	/**
		A socket `select` keeps registered lets go of its address when closed.
		On Windows a registered channel's socket is only closed once the
		selector lets it go, at its next select, so kept registered between
		calls a closed datagram socket kept its address until the runtime's
		next pump, and binding it again straight away, as a restarted peer
		does, was refused.
	**/
	public function testASocketSelectKeepsLetsGoOfItsAddressWhenClosed():Void {
		var first = new sys.net.UdpSocket();
		first.bind(new sys.net.Host("127.0.0.1"), 0);
		first.setBlocking(false);
		var port = first.host().port;
		var other = new sys.net.UdpSocket();
		other.bind(new sys.net.Host("127.0.0.1"), 0);
		other.setBlocking(false);

		// Watched, and so kept registered after the call.
		sys.net.Socket.select([first, other], null, null, 0.05);
		first.close();

		var again = new sys.net.UdpSocket();
		var failure:String = null;
		try {
			again.bind(new sys.net.Host("127.0.0.1"), port);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		again.close();
		other.close();

		Assert.isNull(failure, "a closed datagram socket's address could not be bound again: " + failure);
	}

	/**
		`select` leaves a blocking socket blocking, as it is natively. It made
		the channel non-blocking to register it and left it so, and a blocking
		reader then met a read that answered "would block" at once rather
		than waiting for the data on its way.
	**/
	public function testSelectLeavesABlockingSocketBlocking():Void {
		var pairs = __pairs(1);
		var reader = pairs.servers[0];
		reader.setBlocking(true);
		reader.setTimeout(5);

		sys.net.Socket.select([reader], null, null, 0);

		var writer = pairs.clients[0];
		sys.thread.Thread.create(() -> {
			crossbyte.sys.System.sleep(0.1);
			try {
				writer.output.writeByte(7);
			} catch (_:Dynamic) {}
		});

		var got:Int = -1;
		var failure:String = null;
		try {
			got = reader.input.readByte();
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		pairs.close();

		Assert.isNull(failure, "a blocking read after select did not wait for its data: " + failure);
		Assert.equals(7, got);
	}

	/**
		On Windows, past 1,023 sockets, `select` starts no thread per call.
		The selector hands each further 1,024 sockets to a helper thread, and
		registering every socket and cancelling every key on every call
		started one and stopped it again each time: at 2,000 sockets, one
		thread per select, and the registry selects on every pump.
	**/
	public function testSelectOverManySocketsStartsNoThreadPerCall():Void {
		if (Sys.systemName() != "Windows") {
			// Only the Windows selector works through helper threads.
			Assert.pass();
			return;
		}

		var pairs = __pairs(1050);
		var threads = java.lang.management.ManagementFactory.getThreadMXBean();

		// The first call registers them all and may start what it needs.
		sys.net.Socket.select(pairs.servers, null, null, 0);
		var before = threads.getTotalStartedThreadCount();
		for (i in 0...10) {
			sys.net.Socket.select(pairs.servers, null, null, 0);
		}
		var started:Int = haxe.Int64.toInt(threads.getTotalStartedThreadCount() - before);
		pairs.close();

		Assert.isTrue(started < 5, '$started threads were started by 10 selects over 1,050 sockets');
	}

	/**
		`count` connected pairs over loopback: the accepted ends, made
		non-blocking as a runtime's are, and the blocking clients.
	**/
	private static function __pairs(count:Int):{servers:Array<sys.net.Socket>, clients:Array<sys.net.Socket>, close:Void->Void} {
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(16);
		var port = listener.host().port;

		var servers:Array<sys.net.Socket> = [];
		var clients:Array<sys.net.Socket> = [];
		for (i in 0...count) {
			var client = new sys.net.Socket();
			client.connect(new sys.net.Host("127.0.0.1"), port);
			clients.push(client);
			var server = listener.accept();
			server.setBlocking(false);
			servers.push(server);
		}
		listener.close();

		return {
			servers: servers,
			clients: clients,
			close: function() {
				for (socket in servers.concat(clients)) {
					try {
						socket.close();
					} catch (_:Dynamic) {}
				}
			}
		};
	}

	/**
		A listener whose queue is full, so the next connection's SYN goes
		unanswered until there is room: the shape of a server too busy to
		accept, made without depending on a host that does not answer.
	**/
	private static function __busyListener():{port:Int, drain:Void->Void, close:Void->Void} {
		var listener = ServerSocketChannel.open();
		listener.bind(new InetSocketAddress("127.0.0.1", 0), 1);
		listener.configureBlocking(false);
		var port:Int = (cast listener.getLocalAddress() : InetSocketAddress).getPort();

		var channels:Array<SocketChannel> = [];
		for (i in 0...8) {
			var filler = SocketChannel.open();
			filler.configureBlocking(false);
			filler.connect(new InetSocketAddress("127.0.0.1", port));
			channels.push(filler);
		}
		crossbyte.sys.System.sleep(0.2);

		return {
			port: port,
			drain: function() {
				var next:SocketChannel = listener.accept();
				while (next != null) {
					channels.push(next);
					next = listener.accept();
				}
			},
			close: function() {
				for (channel in channels) {
					try {
						channel.close();
					} catch (_:Dynamic) {}
				}
				try {
					listener.close();
				} catch (_:Dynamic) {}
			}
		};
	}
}
#end
