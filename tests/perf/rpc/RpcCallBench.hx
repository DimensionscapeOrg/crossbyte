// RPC calls over each transport, two processes, in the shape grpc_bench.js
// and grpcbench make gRPC calls:
//
//   RpcCallBench server --transport tcp|tls|ws|wss|rudp|rudpenc|local --port 4900
//   RpcCallBench client --transport tcp --port 4900 --connections 1 --inflight 1
//                       --kind int|string|struct|blob|intmap|strmap|oneway --entries 8 --warmup 2 --seconds 5
//
// The client keeps `inflight` calls waiting on each connection, making the
// next as each is answered, through receivers (nothing allocated for a call),
// and times each one's round trip. It prints WINDOW_START and WINDOW_END
// around the measured window. At the end it asks the server, by RPC, for what
// the window cost it in processor time, and prints one RESULT line of JSON.
// rpc-bench.hxml builds it; run.js runs it beside gRPC.
import LoadStats.Histogram;
import LoadStats.ProcessStats;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
#if !js
import crossbyte.ipc.LocalConnection;
#end
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import crossbyte.rpc.Float32;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCIntReceiver;
import crossbyte.rpc.RPCSession;
import crossbyte.rpc.RPCStringReceiver;
import crossbyte.rpc.RPCStruct;
import crossbyte.rpc.RPCValueReceiver;
import crossbyte.rpc.UInt8;
import haxe.Json;
import haxe.Timer;
import haxe.io.Bytes;

class BenchVec implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var z:Float32 = 0;

	public function new() {}
}

class BenchSlot implements RPCStruct {
	public var item:Int = 0;
	public var count:UInt8 = 0;

	public function new() {}
}

class BenchState implements RPCStruct {
	public var id:Int = 0;
	public var position:BenchVec = new BenchVec();
	public var velocity:BenchVec = new BenchVec();
	public var flags:UInt8 = 0;
	public var name:String = "";
	public var inventory:Array<BenchSlot> = [];

	public function new() {}
}

interface CallContract {
	function num(v:Int):Int;
	function text(v:Int):String;
	function state(v:Int):BenchState;
	function blob(v:Bytes):Bytes;
	function intMap(v:Map<String, Int>):Map<String, Int>;
	function strMap(v:Map<String, String>):Map<String, String>;
	function note(v:Int):Void;
	function mark():Int;
	function report():String;
}

@:rpcContract(CallContract)
class CallCommands extends RPCCommands {
	public function new() {}
}

class CallHandler extends RPCHandler implements CallContract {
	final shared:BenchState;

	public var notes:Int = 0;

	var before:Null<ProcessStats> = null;
	var startedAt:Float = 0;
	var calls:Float = 0;

	public function new() {
		shared = new BenchState();
		shared.id = 7;
		shared.name = "player seven";
		for (i in 0...8) {
			final slot = new BenchSlot();
			slot.item = 100 + i;
			slot.count = i;
			shared.inventory.push(slot);
		}
	}

	public function num(v:Int):Int {
		calls++;
		return v;
	}

	public function text(v:Int):String {
		calls++;
		return "hello, world";
	}

	public function blob(v:Bytes):Bytes {
		calls++;
		return v;
	}

	// The map that arrived, answered: read into a map, and written again, as
	// gRPC's benches answer theirs.
	public function intMap(v:Map<String, Int>):Map<String, Int> {
		calls++;
		return v;
	}

	public function strMap(v:Map<String, String>):Map<String, String> {
		calls++;
		return v;
	}

	public function state(v:Int):BenchState {
		calls++;
		shared.flags = v & 0xFF;
		return shared;
	}

	public function note(v:Int):Void {
		calls++;
		notes++;
	}

	var nodeCpuAtMark:Float = 0;

	public function mark():Int {
		#if nodejs
		final usage:Dynamic = js.Syntax.code("process.cpuUsage()");
		nodeCpuAtMark = (usage.user + usage.system) / 1e6;
		#end
		Alloc.begin();
		before = ProcessStats.sample();
		startedAt = Timer.stamp();
		calls = 0;
		return 1;
	}

	public function report():String {
		final after = ProcessStats.sample();
		final elapsed = Timer.stamp() - startedAt;
		#if nodejs
		// Node's own count: Sys.cpuTime there is the process's uptime.
		final usage:Dynamic = js.Syntax.code("process.cpuUsage()");
		final cpu = (usage.user + usage.system) / 1e6 - nodeCpuAtMark;
		#else
		final cpu = after.cpu - before.cpu;
		#end
		return Json.stringify({
			serverCalls: calls,
			serverCores: Math.round(cpu / elapsed * 1000) / 1000,
			serverCpuNsPerCall: Math.round(cpu * 1e9 / calls),
			serverAllocPerCall: Alloc.perCall(calls)
		});
	}
}

/** Bytes this process allocated, on the jvm (exact); -1 elsewhere. **/
class Alloc {
	static var last:Float = -1;

	public static function total():Float {
		#if jvm
		final bean:AllocatingThreadBean = cast java.lang.management.ManagementFactory.getThreadMXBean();
		final ids:java.NativeArray<haxe.Int64> = bean.getAllThreadIds();
		final sizes:java.NativeArray<haxe.Int64> = bean.getThreadAllocatedBytes(ids);
		var sum = 0.0;
		for (i in 0...ids.length) {
			final v:haxe.Int64 = sizes[i];
			var low:Float = v.low;
			if (low < 0) {
				low += 4294967296.0;
			}
			final b = v.high * 4294967296.0 + low;
			if (b > 0) {
				sum += b;
			}
		}
		return sum;
		#else
		return -1;
		#end
	}

	public static function begin():Void {
		last = total();
	}

	public static function perCall(calls:Float):Float {
		final now = total();
		if (now < 0 || last < 0) {
			return -1;
		}
		return Math.round((now - last) / calls * 10) / 10;
	}
}

#if jvm
@:native("com.sun.management.ThreadMXBean")
extern interface AllocatingThreadBean {
	overload function getThreadAllocatedBytes(id:haxe.Int64):haxe.Int64;
	overload function getThreadAllocatedBytes(ids:java.NativeArray<haxe.Int64>):java.NativeArray<haxe.Int64>;
	function getAllThreadIds():java.NativeArray<haxe.Int64>;
}
#end

class RpcCallBench extends ServerApplication {
	public static var opts:Opts;

	public static function main():Void {
		opts = new Opts(Sys.args());
		ServerApplication.defaultTicksPerSecond = 60;
		new RpcCallBench();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, _ -> {
			switch (opts.role) {
				case "server":
					serve();
				case "client":
					new Client(opts).start();
				default:
					Sys.println("usage: RpcCallBench server|client ...");
					Sys.exit(2);
			}
		});
	}

	static final sessions:Array<RPCSession<Dynamic, Dynamic>> = [];

	function serve():Void {
		final transport = opts.str("transport", "tcp");
		final port = opts.int("port", 4900);
		final handler = new CallHandler();
		final accept = (connection:INetConnection) -> {
			sessions.push(new RPCSession(connection, null, handler));
		};
		switch (transport) {
			case "tcp":
				new NetHost("tcp://127.0.0.1:" + port, accept).listen();
			case "ws":
				new NetHost("ws://127.0.0.1:" + port, accept).listen();
			case "wss":
				final cert = Certs.get();
				new NetHost("wss://127.0.0.1:" + port, accept, null, null, false, {certificate: cert.certificate, key: cert.key}).listen();
			case "tls":
				final cert = Certs.get();
				final server = new ServerSocket(true);
				server.setCertificate(cert.certificate, cert.key);
				server.bind(port, "127.0.0.1");
				NetHost.fromServerSocket(server, accept).listen();
			case "rudp":
				new NetHost("rudp://127.0.0.1:" + port, accept).listen();
			case "rudpenc":
				final server = new ReliableDatagramServerSocket();
				server.encryptionKeyFor = (address, port, payload) -> Certs.KEY;
				server.bind(port, "127.0.0.1");
				NetHost.fromReliableDatagramServerSocket(server, accept).listen();
			#if !js
			case "local":
				final listener = new LocalConnection();
				listener.listen("rpcbench" + port);
				sessions.push(new RPCSession(NetConnection.fromLocalConnection(listener), null, handler));
			#end
			default:
				throw "unknown transport " + transport;
		}
		say("READY");
	}

	public static function say(line:String):Void {
		Sys.println(line);
		Sys.stdout().flush();
	}
}

class Certs {
	public static final KEY:Bytes = Bytes.ofHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");

	public static function get():{certificate:crossbyte.net.Certificate, key:crossbyte.net.Key} {
		final fixture = crossbyte.net.TLSTestFixture.trusted();
		if (fixture == null) {
			throw "no certificate toolchain";
		}
		return {certificate: fixture.certificate, key: fixture.key};
	}
}

class Link implements RPCIntReceiver implements RPCStringReceiver implements RPCValueReceiver<Bytes> {
	public final commands = new CallCommands();

	// The 4 KB a blob call sends, and is sent back.
	static final BLOB:Bytes = {
		final b = Bytes.alloc(4096);
		for (i in 0...4096) {
			b.set(i, (i * 31 + 7) & 0xFF);
		}
		b;
	};

	// The maps a map call sends, made once, as the blob is: keys "key0" up,
	// values their number, or "value" and their number.
	public static var intEntries:Map<String, Int> = new Map();
	public static var strEntries:Map<String, String> = new Map();

	public static function makeMaps(entries:Int):Void {
		for (i in 0...entries) {
			intEntries.set("key" + i, i);
			strEntries.set("key" + i, "value" + i);
		}
	}

	public var session:RPCSession<CallCommands, Dynamic>;
	public var up:Bool = false;
	final intAnswers:IntMapAnswers;
	final strAnswers:StrMapAnswers;

	final client:Client;
	final sentAt:Array<Float> = [for (_ in 0...4096) 0.0];
	var seq:Int = 0;

	public function new(client:Client) {
		this.client = client;
		intAnswers = new IntMapAnswers(this);
		strAnswers = new StrMapAnswers(this);
	}

	public function connect(transport:String, port:Int):Void {
		final connection:NetConnection = switch (transport) {
			case "tcp": new NetConnection("tcp://127.0.0.1:" + port);
			case "ws": new NetConnection("ws://127.0.0.1:" + port + "/");
			case "wss":
				final socket = new crossbyte.net.WebSocket();
				socket.secure = true;
				socket.certAuthority = Certs.get().certificate;
				final nc = NetConnection.fromWebSocket(socket);
				socket.connect("127.0.0.1", port);
				nc;
			case "tls":
				final socket = new Socket();
				socket.secure = true;
				socket.certAuthority = Certs.get().certificate;
				final nc = NetConnection.fromSocket(socket);
				socket.connect("127.0.0.1", port);
				nc;
			case "rudp": new NetConnection("rudp://127.0.0.1:" + port);
			case "rudpenc":
				final socket = new ReliableDatagramSocket();
				socket.encryptionKey = Certs.KEY;
				final nc = NetConnection.fromReliableDatagramSocket(socket);
				socket.connect("127.0.0.1", port);
				nc;
			case "local": new NetConnection("local://rpcbench" + port);
			default: throw "unknown transport " + transport;
		};
		session = new RPCSession<CallCommands, Dynamic>(connection, commands);
		connection.onReady = () -> up = true;
		if (connection.connected) {
			up = true;
		}
	}

	/** One call of the kind measured; its round trip timed by its id. **/
	public function call(kind:String):Void {
		final now = Timer.stamp();
		switch (kind) {
			case "int":
				sentAt[commands.numThen(seq++, this) & 4095] = now;
			case "string":
				sentAt[commands.textThen(seq++, this) & 4095] = now;
			case "blob":
				sentAt[commands.blobThen(BLOB, this) & 4095] = now;
			case "intmap":
				sentAt[commands.intMapThen(intEntries, intAnswers) & 4095] = now;
			case "strmap":
				sentAt[commands.strMapThen(strEntries, strAnswers) & 4095] = now;
			default:
				commands.note(seq++);
		}
	}

	public inline function answered(call:Int):Void {
		client.answered(this, Timer.stamp() - sentAt[call & 4095]);
	}

	public function onInt(call:Int, value:Int):Void {
		answered(call);
	}

	public function onString(call:Int, value:String):Void {
		answered(call);
	}

	public function onValue(call:Int, value:Bytes):Void {
		answered(call);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		client.failures++;
	}
}

/** A map call's answer, handed to the link that made it. **/
class IntMapAnswers implements RPCValueReceiver<Map<String, Int>> {
	final link:Link;

	public function new(link:Link) {
		this.link = link;
	}

	public function onValue(call:Int, value:Map<String, Int>):Void {
		link.answered(call);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		link.onFailure(call, failure);
	}
}

class StrMapAnswers implements RPCValueReceiver<Map<String, String>> {
	final link:Link;

	public function new(link:Link) {
		this.link = link;
	}

	public function onValue(call:Int, value:Map<String, String>):Void {
		link.answered(call);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		link.onFailure(call, failure);
	}
}

class Client {
	final opts:Opts;
	final links:Array<Link> = [];

	public var failures:Float = 0;
	public var total:Float = 0;

	var measuring:Bool = false;
	var rtt = new Histogram();
	var answers:Float = 0;
	var kind:String;
	var inflight:Int;

	public function new(opts:Opts) {
		this.opts = opts;
	}

	public function start():Void {
		kind = opts.str("kind", "int");
		inflight = opts.int("inflight", 1);
		Link.makeMaps(opts.int("entries", 8));
		final count = opts.int("connections", 1);
		for (i in 0...count) {
			final link = new Link(this);
			link.connect(opts.str("transport", "tcp"), opts.int("port", 4900));
			links.push(link);
		}
		var waiter = 0;
		final started = Timer.stamp();
		waiter = crossbyte.Timer.setInterval(0.05, 0.05, () -> {
			var up = 0;
			for (l in links) {
				if (l.up) {
					up++;
				}
			}
			if (up == links.length) {
				crossbyte.Timer.clear(waiter);
				run();
			} else if (Timer.stamp() - started > 20) {
				RpcCallBench.say("FAILED " + up + " of " + links.length + " up");
				Sys.exit(3);
			}
		});
	}

	function run():Void {
		if (kind == "oneway") {
			// One-way calls have no answer to pace them: a burst a frame, as
			// many as a connection's in-flight count, every millisecond.
			crossbyte.Timer.setInterval(0.001, 0.001, () -> {
				for (l in links) {
					for (_ in 0...inflight) {
						l.call(kind);
						answers++;
					}
				}
			});
		} else {
			for (l in links) {
				for (_ in 0...inflight) {
					l.call(kind);
				}
			}
		}
		crossbyte.Timer.setTimeout(opts.float("warmup", 2), () -> {
			links[0].commands.markThen(new Marked(measure));
		});
	}

	function measure():Void {
		RpcCallBench.say("WINDOW_START");
		measuring = true;
		rtt = new Histogram();
		answers = 0;
		final started = Timer.stamp();
		Alloc.begin();
		crossbyte.Timer.setTimeout(opts.float("seconds", 5), () -> {
			measuring = false;
			final elapsed = Timer.stamp() - started;
			RpcCallBench.say("WINDOW_END");
			final record:Dynamic = {
				system: "crossbyte",
				transport: opts.str("transport", "tcp"),
				kind: kind,
				entries: opts.int("entries", 8),
				connections: links.length,
				inflight: inflight,
				target: #if cpp "native" #elseif jvm "jvm" #elseif js "node" #else "other" #end,
				callsPerSec: Math.round(answers / elapsed),
				totalAnswers: total,
				rttP50us: Math.round(rtt.percentile(0.5) * 1000),
				rttP99us: Math.round(rtt.percentile(0.99) * 1000),
				failures: failures,
				clientAllocPerCall: Alloc.perCall(answers)
			};
			links[0].commands.report().then(json -> {
				final server:Dynamic = Json.parse(json);
				for (f in Reflect.fields(server)) {
					Reflect.setField(record, f, Reflect.field(server, f));
				}
				RpcCallBench.say("RESULT " + Json.stringify(record));
				Sys.exit(0);
			}, e -> {
				RpcCallBench.say("RESULT " + Json.stringify(record));
				Sys.exit(0);
			});
		});
	}

	public function answered(link:Link, seconds:Float):Void {
		total++;
		if (measuring) {
			answers++;
			rtt.add(seconds * 1000);
		}
		link.call(kind);
	}
}

class Marked implements RPCIntReceiver {
	final then:Void->Void;

	public function new(then:Void->Void) {
		this.then = then;
	}

	public function onInt(call:Int, value:Int):Void {
		then();
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		RpcCallBench.say("FAILED mark: " + failure);
		Sys.exit(4);
	}
}

class Opts {
	var values:Map<String, String> = new Map();

	public var role:String;

	public function new(raw:Array<String>) {
		role = raw.length > 0 ? raw[0] : "";
		var i = 1;
		while (i < raw.length) {
			var name = raw[i];
			if (StringTools.startsWith(name, "--")) {
				if (i + 1 < raw.length && !StringTools.startsWith(raw[i + 1], "--")) {
					values.set(name.substr(2), raw[i + 1]);
					i += 2;
					continue;
				}
				values.set(name.substr(2), "true");
			}
			i++;
		}
	}

	public function str(name:String, fallback:String):String {
		var v = values.get(name);
		return v == null ? fallback : v;
	}

	public function int(name:String, fallback:Int):Int {
		var v = Std.parseInt(str(name, ""));
		return v == null ? fallback : v;
	}

	public function float(name:String, fallback:Float):Float {
		var v = Std.parseFloat(str(name, ""));
		return Math.isNaN(v) ? fallback : v;
	}
}
