package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;

/**
	Two connections joined in memory, for the RPC tests: what one sends, the
	other reads at once, unless it is told to hold what arrives until asked.
**/
class LinkedConnection implements INetConnection {
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
	public var protocol:Protocol = TCP;
	public var inTimestamp(default, null):Float = 0;
	public var outTimestamp(default, null):Float = 0;
	public var bufferInbound:Bool = false;
	/** Whether this reports itself connected; see `becomeReady`. **/
	public var isConnected:Bool = true;
	/** How many sends this has made. **/
	public var sent:Int = 0;
	/** Once closed, a send throws, as a closed socket's does. **/
	public var strictSend:Bool = false;
	/** Every send throws, open or not, as one to a peer that has reset does. **/
	public var failSends:Bool = false;
	/** `false` once closed. **/
	public var open(default, null):Bool = true;

	public var peer:LinkedConnection;
	@:noCompletion private var __pendingInputs:Array<ByteArray> = [];
	// What a read is handed, reused from one read to the next as a socket's
	// input is; a read arriving while one is being read, a call answered
	// at once, whose answer calls again, gets a copy of its own. Each read
	// was a ByteArray of its own, which every RPC allocation budget counted.
	@:noCompletion private var __input:ByteArray = new ByteArray();
	@:noCompletion private var __reading:Bool = false;

	@:noCompletion private var __readEnabled:Bool = false;
	@:noCompletion private var __onData:ByteArrayInput->Void = input -> {};
	@:noCompletion private var __onClose:Reason->Void = reason -> {};
	@:noCompletion private var __onError:Reason->Void = reason -> {};
	@:noCompletion private var __onReady:Void->Void = () -> {};

	public static function pair():{client:LinkedConnection, server:LinkedConnection} {
		var client = new LinkedConnection();
		var server = new LinkedConnection();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		if (failSends || (!open && strictSend)) {
			throw "send failed";
		}
		sent++;
		outTimestamp = Timer.getTime();
		if (peer != null) {
			peer.receive(data);
		}
	}

	public function close():Void {
		open = false;
		__readEnabled = false;
		__onClose(Closed);
	}

	/** Becomes connected and says so, as a socket whose connect completes does. **/
	public function becomeReady():Void {
		isConnected = true;
		__onReady();
	}

	/**
		Its peer has gone, and the connection says so, as a listening
		`LocalConnection` does when its client leaves: it closes, and keeps
		its callbacks for the next.
	**/
	public function peerLeft():Void {
		open = false;
		__onClose(Closed);
	}

	/** Takes `next` as its peer, as a listening `LocalConnection` takes its next client, and says it is ready. **/
	public function takePeer(next:LinkedConnection):Void {
		open = true;
		peer = next;
		next.peer = this;
		__onReady();
	}

	@:noCompletion private function receive(data:ByteArray):Void {
		inTimestamp = Timer.getTime();
		if (bufferInbound) {
			__pendingInputs.push(copyOf(data));
			return;
		}
		if (!__readEnabled) {
			return;
		}
		if (__reading) {
			__onData(copyOf(data));
			return;
		}
		// Copied, as a socket copies what it is sent: `data` is the sender's,
		// for the length of its send only.
		final input = __input;
		input.clear();
		input.writeBytes(data, 0, data.length);
		input.position = 0;
		__reading = true;
		try {
			__onData(input);
		} catch (error:Dynamic) {
			__reading = false;
			throw error;
		}
		__reading = false;
	}

	private static function copyOf(data:ByteArray):ByteArray {
		var copy = new ByteArray();
		copy.writeBytes(data, 0, data.length);
		copy.position = 0;
		return copy;
	}

	/** Hands everything buffered to the session in one read, as a socket would. **/
	public function deliverBufferedAsOneRead():Void {
		var joined = new ByteArray();
		for (input in __pendingInputs) {
			joined.writeBytes(input, 0, input.length);
		}
		__pendingInputs = [];
		joined.position = 0;
		__onData(joined);
	}

	public function flushBufferedReads():Void {
		if (!__readEnabled) {
			__pendingInputs = [];
			return;
		}
		var pending = __pendingInputs;
		__pendingInputs = [];
		for (input in pending) {
			input.position = 0;
			__onData(input);
		}
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return "127.0.0.1";
	}

	@:noCompletion private inline function get_remotePort():Int {
		return 1;
	}

	@:noCompletion private inline function get_localAddress():String {
		return "127.0.0.1";
	}

	@:noCompletion private inline function get_localPort():Int {
		return 1;
	}

	@:noCompletion private inline function get_connected():Bool {
		return isConnected;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	@:noCompletion private inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}
