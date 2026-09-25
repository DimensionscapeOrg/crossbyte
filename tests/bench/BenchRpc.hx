import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.utils.Hash;
import haxe.io.Bytes;

/**
	What an RPC call costs: decoding and dispatching one on the handler's
	side, a one-way call from the client's stub to the handler, and a request
	answered.

	The two sessions are joined in memory, so a send is a copy and a call on
	the other side, and what is timed is RPC and nothing under it. A socket
	adds a system call either way, which is not what these are for.
**/
class BenchRpc {
	public static function run():Void {
		Bench.section("RPC");

		var link = BenchLink.pair();
		var commands = new BenchCommands();
		var handler = new BenchHandler();
		var client = new RPCSession<BenchCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);

		// A one-way `move(7, 1.5, -2.5)`, framed as the stub frames it, fed to
		// the handler's side directly: decode, dispatch, call.
		var frame = moveFrame();
		var serverRead = link.server.onData;
		Bench.run("dispatch a one-way call (3 args)", function():Void {
			frame.position = 0;
			serverRead(frame);
		});

		// The same, to a handler that overrides beforeCall and afterCall and
		// does nothing in them: what the hooks themselves cost a call.
		var hookedLink = BenchLink.pair();
		var hooked = new HookedBenchHandler();
		var hookedServer = new RPCSession(hookedLink.server, null, hooked);
		var hookedRead = hookedLink.server.onData;
		Bench.run("dispatch one-way, hooks overridden", function():Void {
			frame.position = 0;
			hookedRead(frame);
		});

		Bench.run("one-way call, stub to handler", function():Void {
			commands.move(7, 1.5, -2.5);
		});

		Bench.run("request and response", function():Void {
			commands.name(7);
		});

		// The same request to a method that answers with a Future: one complete
		// already -- a cached answer, the same future each time, so what is
		// timed is the dispatch and not the handler's allocation -- and one
		// completed after the method has returned, on this thread.
		Bench.run("request answered with a complete future", function():Void {
			commands.ready(7);
		});

		Bench.run("request answered later, same thread", function():Void {
			commands.later(7);
			handler.pending.complete("player");
		});

		if (handler.moves == 0 || hooked.moves == 0 || client == null || server == null || hookedServer == null) {
			Sys.println("  (the handler was never called)");
		}
	}

	static function moveFrame():ByteArray {
		var payload = new ByteArrayOutput(64);
		payload.writeByte(0);
		payload.writeInt(Hash.fnv1a32(Bytes.ofString("move")));
		payload.writeInt(7);
		payload.writeDouble(1.5);
		payload.writeDouble(-2.5);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}
}

private class BenchCommands extends RPCCommands {
	public function new() {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {}

	@:rpc public function name(id:Int):RPCResponse<String> {}

	@:rpc public function ready(id:Int):RPCResponse<String> {}

	@:rpc public function later(id:Int):RPCResponse<String> {}
}

private class BenchHandler extends RPCHandler {
	public var moves:Int = 0;
	public var x:Float = 0;

	public function new() {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {
		moves++;
		this.x += x - y;
	}

	@:rpc public function name(id:Int):String {
		return "player";
	}

	static final readyAnswer:crossbyte.Future<String> = crossbyte.Future.resolved("player");

	public var pending:crossbyte.Completer<String>;

	@:rpc public function ready(id:Int):crossbyte.Future<String> {
		return readyAnswer;
	}

	@:rpc public function later(id:Int):crossbyte.Future<String> {
		pending = new crossbyte.Completer<String>();
		return pending.future;
	}
}

private class HookedBenchHandler extends BenchHandler {
	public function new() {
		super();
	}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<crossbyte.rpc.RPCError> {
		return null;
	}

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {}
}

/** Two connections joined in memory: what one sends, the other reads at once. **/
private class BenchLink implements INetConnection {
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

	public var peer:BenchLink;

	var __readEnabled:Bool = false;
	var __onData:ByteArrayInput->Void = input -> {};
	var __onClose:Reason->Void = reason -> {};
	var __onError:Reason->Void = reason -> {};
	var __onReady:Void->Void = () -> {};

	public static function pair():{client:BenchLink, server:BenchLink} {
		var client = new BenchLink();
		var server = new BenchLink();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		if (peer != null && peer.__readEnabled) {
			data.position = 0;
			peer.__onData(data);
		}
	}

	public function close():Void {
		__readEnabled = false;
		__onClose(Closed);
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
		return true;
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
