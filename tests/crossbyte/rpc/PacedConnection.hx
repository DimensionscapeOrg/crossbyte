package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnectionBase;
import crossbyte.net.Reason;
import crossbyte.net.Transport;

/**
	Two connections joined in memory that hold what is sent until the test
	moves it, and say how much they hold, as a socket's unsent bytes say:
	for an `RPCSession` that paces what it sends by what its connection
	holds (an answer in pieces). What arrives is read as a stream, what the
	reader leaves unread kept for the next arrival, as over TCP.

	Each send is kept as it was sent, so a test can read the frames that
	went, in order.
**/
class PacedConnection extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	public var peer:PacedConnection;

	/** What was sent and has not been moved to the peer, a send each. **/
	public final held:Array<ByteArray> = [];

	/** Every send that was moved to the peer, in order. **/
	public final moved:Array<ByteArray> = [];

	public var heldBytes(default, null):Int = 0;
	public var open(default, null):Bool = true;

	final input:ByteArray = new ByteArray();
	var __readEnabled:Bool = false;
	var __onData:ByteArrayInput->Void = input -> {};
	var __onClose:Reason->Void = reason -> {};
	var __onError:Reason->Void = reason -> {};
	var __onReady:Void->Void = () -> {};

	public static function pair():{client:PacedConnection, server:PacedConnection} {
		final client = new PacedConnection();
		final server = new PacedConnection();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {
		protocol = TCP;
		__paces = true;
		__holdsOutput = true;
	}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		if (!open) {
			throw "send on a closed connection";
		}
		final copy = new ByteArray();
		copy.writeBytes(data, 0, data.length);
		copy.position = 0;
		held.push(copy);
		heldBytes += copy.length;
	}

	override public function __bytesQueued():Int {
		return heldBytes;
	}

	override public function __bytesPending():Int {
		return heldBytes;
	}

	/** Moves up to `bytes` of what is held (whole sends; all of it by default) to the peer, which reads it. **/
	public function deliver(bytes:Int = 0x7FFFFFFF):Int {
		var count:Int = 0;
		while (held.length > 0 && bytes > 0) {
			final next:ByteArray = held.shift();
			heldBytes -= next.length;
			bytes -= next.length;
			moved.push(next);
			count++;
			if (peer != null && peer.open) {
				peer.receive(next);
			}
		}
		return count;
	}

	function receive(data:ByteArray):Void {
		if (!__readEnabled) {
			return;
		}
		// Kept unread from before, then this.
		final readTo:Int = input.position;
		final unread:Int = input.length - readTo;
		final joined = new ByteArray();
		if (unread > 0) {
			joined.writeBytes(input, readTo, unread);
		}
		joined.writeBytes(data, 0, data.length);
		input.clear();
		input.writeBytes(joined, 0, joined.length);
		input.position = 0;
		__onData(input);
	}

	public function close():Void {
		__closeWith(Reason.Closed);
	}

	override public function __closeWith(reason:Reason):Void {
		if (!open) {
			return;
		}
		open = false;
		__notifyClose(reason);
		__onClose(reason);
	}

	/** The peer has gone: this one ends as a socket whose peer closed does. **/
	public function peerLeft():Void {
		__closeWith(Reason.Closed);
	}

	inline function get_remoteAddress():String {
		return "127.0.0.1";
	}

	inline function get_remotePort():Int {
		return 1;
	}

	inline function get_localAddress():String {
		return "127.0.0.1";
	}

	inline function get_localPort():Int {
		return 1;
	}

	inline function get_connected():Bool {
		return open;
	}

	inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	inline function get_onClose():Reason->Void {
		return __onClose;
	}

	inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	inline function get_onError():Reason->Void {
		return __onError;
	}

	inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	inline function get_onReady():Void->Void {
		return __onReady;
	}

	inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}
