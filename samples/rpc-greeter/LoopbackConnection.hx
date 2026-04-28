import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;

class LoopbackConnection implements INetConnection {
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

	public var peer:LoopbackConnection;
	@:noCompletion private var __pendingInputs:Array<ByteArray> = [];

	private var __connected:Bool = true;
	private var __readEnabled:Bool = false;
	private var __onData:ByteArrayInput->Void = input -> {};
	private var __onClose:Reason->Void = reason -> {};
	private var __onError:Reason->Void = reason -> {};
	private var __onReady:Void->Void = () -> {};

	public static function pair():{client:LoopbackConnection, server:LoopbackConnection} {
		var client = new LoopbackConnection("127.0.0.1", 41000, "127.0.0.1", 42000);
		var server = new LoopbackConnection("127.0.0.1", 42000, "127.0.0.1", 41000);
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	private final __localAddress:String;
	private final __localPort:Int;
	private final __remoteAddress:String;
	private final __remotePort:Int;

	public function new(localAddress:String, localPort:Int, remoteAddress:String, remotePort:Int) {
		__localAddress = localAddress;
		__localPort = localPort;
		__remoteAddress = remoteAddress;
		__remotePort = remotePort;
	}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		if (!__connected || peer == null || !peer.__connected) {
			__onError(Reason.Closed);
			return;
		}

		outTimestamp = Sys.time();
		var copy = new ByteArray();
		copy.writeBytes(data, 0, data.length);
		copy.position = 0;
		peer.__receive(copy);
	}

	public function close():Void {
		if (!__connected) {
			return;
		}

		__connected = false;
		__readEnabled = false;
		__onClose(Reason.Closed);
	}

	private function __receive(input:ByteArray):Void {
		inTimestamp = Sys.time();
		if (bufferInbound) {
			__pendingInputs.push(input);
			return;
		}
		if (!__readEnabled || !__connected) {
			return;
		}
		__onData(input);
	}

	public function flushBufferedReads():Void {
		if (!__readEnabled || !__connected) {
			__pendingInputs = [];
			return;
		}
		final pending = __pendingInputs;
		__pendingInputs = [];
		for (input in pending) {
			input.position = 0;
			__onData(input);
		}
	}

	private inline function get_remoteAddress():String {
		return __remoteAddress;
	}

	private inline function get_remotePort():Int {
		return __remotePort;
	}

	private inline function get_localAddress():String {
		return __localAddress;
	}

	private inline function get_localPort():Int {
		return __localPort;
	}

	private inline function get_connected():Bool {
		return __connected;
	}

	private inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	private inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	private inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	private inline function get_onError():Reason->Void {
		return __onError;
	}

	private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	private inline function get_onReady():Void->Void {
		return __onReady;
	}

	private inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}
