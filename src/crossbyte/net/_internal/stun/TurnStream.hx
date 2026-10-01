package crossbyte.net._internal.stun;

// A TCP connection, which a page cannot open.
#if !(js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import crossbyte.net.TurnClient;
import crossbyte.net.TurnTransport;

/**
	The connection a `TurnClient` reaches its relay over when its transport is
	TCP: what the client sends is written to it, what arrives is handed to
	`receiveStream`, and its end is the allocation's.

	`TurnClient` owns no socket, which is what lets the whole exchange be
	tested in memory; this is the socket, for the callers here that reach a
	relay over TCP or TLS. TLS is framed exactly as TCP is; the socket is a
	secure one, checking the relay's certificate against the name it was
	given with the client's `verifyCert` and `certAuthority`.

	A relay that redirects with 300 Try Alternate is another server, reached
	over a connection of its own: the client sends its retry to the
	alternate's address, and the connection follows. It went on writing to
	the connection opened once, so the retry reached the relay that had just
	redirected it, which redirected it again, and the allocation failed as a
	redirection back to a relay already asked.
**/
class TurnStream {
	public var client(default, null):TurnClient;

	@:noCompletion private var __socket:Socket;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __closed:Bool = false;

	/** Where the open connection goes, as the client names it, so a send elsewhere is known for a move. **/
	@:noCompletion private var __address:String;

	@:noCompletion private var __port:Int = 0;

	/** What the client sent before the connection opened, sent when it does. **/
	@:noCompletion private var __waiting:Array<ByteArray> = [];

	/**
		Connects to `client`'s relay and takes over its `onSend`. Call before
		`client.allocate`.
	**/
	public function new(client:TurnClient) {
		this.client = client;

		client.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			if (!__closed && (address != __address || port != __port)) {
				__reconnect();
			}

			__write(payload);
		};

		__open();
	}

	/** A connection to wherever the client sends now. **/
	@:noCompletion private function __open():Void {
		__address = client.serverAddress;
		__port = client.serverPort;
		__connected = false;
		__socket = new Socket();

		if (client.transport == TLS) {
			// It refused a TLS relay, saying so, while a client Socket did not
			// start TLS; it does now, natively, on the jvm and on Node.
			__socket.secure = true;
			__socket.verifyCert = client.verifyCert;
			#if !(macro || (js && !nodejs))
			__socket.certAuthority = client.certAuthority;
			#end
		}
		__socket.addEventListener(Event.CONNECT, __onConnect);
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
		__socket.addEventListener(Event.CLOSE, __onClose);
		__socket.addEventListener(IOErrorEvent.IO_ERROR, __onError);

		try {
			// The alternate's domain, after a redirection over TLS that named one,
			// is what its certificate is checked against.
			__socket.connect(client.__streamHost, __port);
		} catch (e:Dynamic) {
			__end("could not connect: " + Std.string(e));
		}
	}

	/**
		The client moved to another server: the connection to the one that
		redirected it is let go, quietly, since its end is not the end of an
		allocation the alternate has yet to grant, and one to the alternate
		opened. Anything still waiting for the old one to open was for that
		server, and goes with it.
	**/
	@:noCompletion private function __reconnect():Void {
		var previous = __socket;
		previous.removeEventListener(Event.CONNECT, __onConnect);
		previous.removeEventListener(ProgressEvent.SOCKET_DATA, __onData);
		previous.removeEventListener(Event.CLOSE, __onClose);
		previous.removeEventListener(IOErrorEvent.IO_ERROR, __onError);

		try {
			previous.close();
		} catch (_:Dynamic) {}

		__waiting = [];
		__open();
	}

	/** Closes the connection, which a relay takes as the end of the allocation. **/
	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;

		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __write(payload:ByteArray):Void {
		if (__closed) {
			return;
		}

		if (!__connected) {
			var copy = new ByteArray();
			copy.writeBytes(payload, 0, payload.length);
			copy.position = 0;
			__waiting.push(copy);
			return;
		}

		try {
			__socket.writeBytes(payload, 0, payload.length);
			__socket.flush();
		} catch (e:Dynamic) {
			__end("a write failed: " + Std.string(e));
		}
	}

	@:noCompletion private function __onConnect(_:Event):Void {
		__connected = true;

		var waiting = __waiting;
		__waiting = [];

		for (payload in waiting) {
			__write(payload);
		}
	}

	@:noCompletion private function __onData(_:ProgressEvent):Void {
		if (__closed) {
			return;
		}

		var available:Int = __socket.bytesAvailable;

		if (available <= 0) {
			return;
		}

		var chunk = new ByteArray();
		__socket.readBytes(chunk, 0, available);
		chunk.position = 0;
		client.receiveStream(chunk, haxe.Timer.stamp());
	}

	@:noCompletion private function __onClose(_:Event):Void {
		__end("the relay closed the connection");
	}

	@:noCompletion private function __onError(e:IOErrorEvent):Void {
		__end(e.text);
	}

	@:noCompletion private function __end(reason:String):Void {
		if (__closed) {
			return;
		}

		__closed = true;

		try {
			__socket.close();
		} catch (_:Dynamic) {}

		client.streamClosed(reason);
	}
}
#end
