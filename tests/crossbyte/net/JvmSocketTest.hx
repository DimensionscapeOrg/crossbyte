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
		the whole SYN-retry time -- 21 s on Windows, two minutes on Linux --
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
			Sys.sleep(0.005);
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
		Sys.sleep(0.2);

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
