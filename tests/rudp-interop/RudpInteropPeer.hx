import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DeliveryMode;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import haxe.io.Bytes;

/**
	One end of the encrypted reliable UDP interoperability check: the same
	program built natively, for the jvm and for Node, and run against each
	other by `ci/rudp-interop/run.js`, so a session sealed by libsodium is
	opened by the jvm's Haxe ChaCha20-Poly1305 and by Node's crypto, and
	the other way round.

	```
	RudpInteropPeer server <key hex>
	RudpInteropPeer client <port> <key hex> [refused]
	```

	The server prints `PORT <n>`, echoes every message of its one session
	back, reliably, and exits 0 once that session has closed. The client
	sends messages of every size the protocol treats differently, reliable
	and unreliable, checks every echo byte for byte, closes gracefully and
	exits 0, or, with `refused`, exits 0 only if its attempt ends with the
	ioError a key mismatch gives. Anything else exits non-zero.
**/
class RudpInteropPeer extends HostApplication {
	static var done:Bool = false;
	static var code:Int = 2;

	static final RELIABLE:Array<Int> = [1, 100, 1179, 5000, 20000];
	static final UNRELIABLE:Array<Int> = [50, 1179];

	static var app:RudpInteropPeer;

	function new() {
		super();
	}

	public static function main():Void {
		// The runtime the sockets run on, driven by the loop below.
		app = new RudpInteropPeer();
		var args = Sys.args();
		if (args.length >= 2 && args[0] == "server") {
			server(Bytes.ofHex(args[1]));
		} else if (args.length >= 3 && args[0] == "client") {
			client(Std.parseInt(args[1]), Bytes.ofHex(args[2]), args.length > 3 && args[3] == "refused");
		} else {
			Sys.println("usage: RudpInteropPeer server <key hex> | client <port> <key hex> [refused]");
			exit(64);
			return;
		}
		run(30.0);
	}

	static function server(key:Bytes):Void {
		var server = new ReliableDatagramServerSocket();
		server.bind(0, "127.0.0.1");
		server.encryptionKeyFor = (_, _, _) -> key;
		var echoed:Int = 0;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			var session = e.socket;
			if (!session.encrypted) {
				finish(3, "SERVER the session is not encrypted");
				return;
			}
			session.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
				session.send(d.data);
				echoed++;
			});
			session.addEventListener(Event.CLOSE, function(_:Event):Void {
				finish(0, 'SERVER DONE echoed $echoed');
				server.close();
			});
		});
		server.listen();
		// Said once the port is known: on Node, once the bind has called back.
		listening = server;
	}

	static var listening:ReliableDatagramServerSocket = null;

	static function announce():Void {
		if (listening != null && listening.localPort > 0) {
			say("PORT " + listening.localPort);
			listening = null;
		}
	}

	static function say(line:String):Void {
		Sys.println(line);
		#if !nodejs
		// Piped, it would wait in a buffer; on Node a flush is an fsync.
		Sys.stdout().flush();
		#end
	}

	static function client(port:Int, key:Bytes, expectRefusal:Bool):Void {
		var socket = new ReliableDatagramSocket();
		var expected:Map<String, Bool> = new Map();
		var got:Int = 0;
		socket.encryptionKey = key;
		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			if (expectRefusal && e.text.indexOf("different keys") >= 0) {
				finish(0, "CLIENT REFUSED as expected: " + e.text);
			} else {
				finish(1, "CLIENT ERROR " + e.text);
			}
		});
		socket.addEventListener(Event.CONNECT, function(_:Event):Void {
			if (expectRefusal) {
				finish(1, "CLIENT connected with the wrong key");
				return;
			}
			var index:Int = 0;
			for (size in RELIABLE) {
				var message = pattern(size, index++);
				expected.set(digest(message), true);
				socket.send(message);
			}
			for (size in UNRELIABLE) {
				var message = pattern(size, index++);
				expected.set(digest(message), true);
				socket.send(message, 0, 0, DeliveryMode.UNRELIABLE);
			}
		});
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
			var k = digest(d.data);
			if (!expected.exists(k)) {
				finish(1, "CLIENT an echo did not match anything sent: " + d.data.length + " bytes");
				return;
			}
			expected.remove(k);
			got++;
			if (got == RELIABLE.length + UNRELIABLE.length) {
				socket.close();
			}
		});
		socket.addEventListener(Event.CLOSE, function(_:Event):Void {
			if (!done) {
				finish(got == RELIABLE.length + UNRELIABLE.length ? 0 : 1, 'CLIENT ${got == RELIABLE.length + UNRELIABLE.length ? "OK" : "closed early"}: $got echoes');
			}
		});
		socket.connect("127.0.0.1", port);
	}

	/** `size` bytes made from `index`, and its length and a checksum as a key. **/
	static function pattern(size:Int, index:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = size;
		for (i in 0...size) {
			(bytes : Bytes).set(i, (i * 31 + index * 7 + (i >> 8)) & 255);
		}
		bytes.position = 0;
		return bytes;
	}

	static function digest(data:ByteArray):String {
		var sum:Int = 0;
		for (i in 0...data.length) {
			sum = (sum * 33 + (data : Bytes).get(i)) | 0;
		}
		return data.length + ":" + sum;
	}

	static function finish(exitCode:Int, line:String):Void {
		if (done) {
			return;
		}
		done = true;
		code = exitCode;
		say(line);
	}

	static function run(timeout:Float):Void {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		var last:Float = haxe.Timer.stamp();
		#if nodejs
		function turn():Void {
			var now = haxe.Timer.stamp();
			app.advance(now - last, 0);
			last = now;
			announce();
			if (done || now > deadline) {
				if (!done) {
					say("TIMEOUT");
				}
				// A moment for a FIN or an echo to leave.
				js.Node.setTimeout(() -> exit(code), 50);
				return;
			}
			js.Node.setTimeout(turn, 1);
		}
		turn();
		#else
		while (!done && haxe.Timer.stamp() < deadline) {
			var now = haxe.Timer.stamp();
			app.advance(now - last, 0);
			last = now;
			announce();
			crossbyte.sys.System.sleep(0.001);
		}
		if (!done) {
			say("TIMEOUT");
		}
		var linger:Float = haxe.Timer.stamp() + 0.05;
		while (haxe.Timer.stamp() < linger) {
			app.advance(0.001, 0);
			crossbyte.sys.System.sleep(0.001);
		}
		exit(code);
		#end
	}

	static function exit(exitCode:Int):Void {
		#if nodejs
		js.Node.process.exit(exitCode);
		#else
		Sys.exit(exitCode);
		#end
	}
}
