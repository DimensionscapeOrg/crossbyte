import crossbyte.ds.IdList;
import crossbyte.ds.SequenceRing;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import crossbyte.rpc.Float32;
import crossbyte.rpc.RPCCodec;
import crossbyte.rpc.RPCCodecs;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCMapPatch;
import crossbyte.rpc.RPCPatch;
import crossbyte.rpc.RPCSession;
import crossbyte.rpc.RPCStruct;
import crossbyte.rpc.UInt16;
import crossbyte.rpc.UInt8;
import crossbyte.rpc.VarUInt;
import haxe.ds.IntMap;
import haxe.io.Bytes;
import stellar.protocol.InputCodec;
import stellar.protocol.Protocol as StellarProtocol;
import stellar.protocol.ShipStateCodec;
import stellar.sim.ShipControls;
import stellar.sim.ShipInput;
import stellar.sim.ShipRules;
import stellar.sim.ShipState;
import stellar.sim.WorldSim;
import yggdrasil.state.Delta;
import yggdrasil.state.Delta.DeltaApply;
import yggdrasil.state.Delta.DeltaCodec;
import yggdrasil.state.Delta.DeltaCompute;
import yggdrasil.state.Delta.DeltaOp;
import yggdrasil.state.Serializer.Reader;
import yggdrasil.state.Serializer.Writer;
import yggdrasil.state.Snapshot;
import yggdrasil.state.Snapshot.SnapshotEntity;
import yggdrasil.state.Snapshot.Snapshots;

/**
	Stellar's hot messages, per observer, through each way of sending them:
	CrossByte's typed patches with today's field types (A) and quantized (B),
	the same shapes in one bit stream (S, hand-written, to settle the design's
	question of two sections against one), and Yggdrasil's codec today
	(`DeltaCompute`, `DeltaCodec`, `ShipStateCodec` sent as
	`spaceDelta(spaceId, Bytes)`). Driven by Stellar's own simulation with
	bots, 17 ships, each the observer of the other 16, at 30 Hz, each patched
	against the tick its client acknowledged two ticks before.

	Each system runs the same recorded ticks. A tick is timed in two halves:
	every observer's message made and sent (diffs, writing, the frame) into a
	connection that keeps it, and then every message read by its client and
	applied into the client's ring of frames. So what is timed is the codec
	and RPC, and nothing under them.

	`--trace <file>` writes the ticks for the protobuf benches
	(`grpc-go/main.go`, `grpc-js/proto_bench.js`), which build the same
	messages and time the same halves.

	Prints one JSON line a system: bytes a message (arguments, and the frame
	over TCP), nanoseconds a message to make and to read, and natively and on
	the jvm bytes allocated a message.
**/
@:access(crossbyte.core.CrossByte)
class ReplicationBench {
	public static inline final SHIPS:Int = 17;
	public static inline final WINDOW:Int = 32;
	public static inline final LAG:Int = 2;

	static var ticks:Array<Array<ShipState>> = [];
	static var inputs:Array<Array<ShipInput>> = [];

	static var runtime:Null<crossbyte.core.CrossByte> = null;

	static function main():Void {
		// A runtime on this thread, as a server's sessions have: without one
		// a send takes a slower way of its own.
		runtime = new crossbyte.core.CrossByte(false, DEFAULT, true);
		final args:Array<String> = #if sys Sys.args() #elseif nodejs js.Node.process.argv.slice(2) #else [] #end;
		final count:Int = intArg(args, "--ticks", 1800);
		final systems:Array<String> = stringArg(args, "--systems", "A,B,S,Y").split(",");
		final reps:Int = intArg(args, "--reps", 1);
		record(count + 60);
		if (args.indexOf("--shapes") >= 0) {
			shapes();
			return;
		}
		final trace:Null<String> = stringArg(args, "--trace", null);
		if (trace != null) {
			#if sys
			sys.io.File.saveBytes(trace, traceBytes());
			#end
		}
		for (rep in 0...reps) {
			for (system in systems) {
				final result = run(system, count);
				println(haxe.Json.stringify(result));
			}
		}
	}

	// ------------------------------------------------------------ the world

	/** Steps Stellar's sim with bots, keeping each tick's ships and inputs. **/
	static function record(count:Int):Void {
		final world = new WorldSim();
		seed = 1;
		for (id in 0...SHIPS) {
			world.addShip(id + 1, new ShipState(next(2000) - 1000, next(2000) - 1000));
		}
		final held:Array<Int> = [for (_ in 0...SHIPS) 0];
		final aims:Array<Int> = [for (_ in 0...SHIPS) next(65536)];
		final seqs:Array<Int> = [for (_ in 0...SHIPS) 0];
		final moves:Array<ShipControls> = [Thrust, Thrust | StrafeLeft, Thrust | StrafeRight, Reverse, Thrust | Boost, None, StrafeLeft, StrafeRight];
		for (_ in 0...count) {
			final step = new Map<Int, ShipInput>();
			final tickInputs:Array<ShipInput> = [];
			for (i in 0...SHIPS) {
				// A bot changes what it holds now and then, turns most ticks,
				// fires now and then, and turns back toward the middle.
				final ship = world.ship(i + 1);
				if (next(12) == 0) {
					held[i] = moves[next(moves.length)];
				}
				if (Math.abs(ship.x) > 3000 || Math.abs(ship.y) > 3000) {
					aims[i] = Std.int((Math.atan2(-ship.y, -ship.x) / (2 * Math.PI)) * 65536) & 0xFFFF;
					held[i] = Thrust;
				} else if (next(3) != 0) {
					aims[i] = (aims[i] + next(400) - 200) & 0xFFFF;
				}
				seqs[i]++;
				final controls:Int = held[i] | (next(20) == 0 ? (Fire : Int) : 0);
				final input = new ShipInput(seqs[i], controls, aims[i]);
				step.set(i + 1, input);
				tickInputs.push(input);
			}
			world.step(step);
			ticks.push([for (i in 0...SHIPS) world.ship(i + 1).clone()]);
			inputs.push(tickInputs);
		}
	}

	static var seed:Int = 1;

	/** A number below `bound`, the same on every target. **/
	static function next(bound:Int):Int {
		seed = (crossbyte.utils.Hash.mul32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
		return (seed >>> 8) % bound;
	}

	/** The ticks, for the protobuf benches: per tick per ship its state and input. **/
	static function traceBytes():Bytes {
		final out = new haxe.io.BytesOutput();
		out.writeInt32(ticks.length);
		out.writeInt32(SHIPS);
		for (t in 0...ticks.length) {
			for (i in 0...SHIPS) {
				final s = ticks[t][i];
				for (v in [s.x, s.y, s.vx, s.vy, s.engineHeat, s.energy, s.reactorHeat, s.dragTimer, s.fireCooldown]) {
					out.writeDouble(v);
				}
				out.writeUInt16(s.aimSteps);
				out.writeByte((s.controls : Int) & ShipControls.ALL);
				out.writeByte(s.engineLocked ? 1 : 0);
				out.writeInt32(s.lastSeq);
				final input = inputs[t][i];
				out.writeInt32(input.seq);
				out.writeByte((input.controls : Int) & ShipControls.ALL);
				out.writeUInt16(input.aimSteps);
			}
		}
		return out.getBytes();
	}

	// ------------------------------------------------------------ the design's shapes

	/**
		The design's shapes, bytes only: the remote ship with 3 of its 8
		fields changed (aimSteps, x, y), the own ship with 10 of its 13, a
		tick of the own ship and 16 remote ships of 3 changed each, one input
		(seq 1,000), and the last four (ack 36,000, newest 1,000).
	**/
	static function shapes():Void {
		final remoteBase = new ShipState(1520, -310);
		remoteBase.vx = 120;
		remoteBase.vy = -45;
		remoteBase.aimSteps = 16000;
		remoteBase.controls = 5;
		remoteBase.engineHeat = 180;
		final remote = remoteBase.clone();
		remote.x = 1524;
		remote.y = -311.5;
		remote.aimSteps = 16384;
		final ownBase = remoteBase.clone();
		ownBase.lastSeq = 990;
		ownBase.energy = 200;
		ownBase.reactorHeat = 50;
		ownBase.dragTimer = 0.01;
		ownBase.fireCooldown = 0.05;
		final own = ownBase.clone();
		own.lastSeq = 1000;
		own.x += 4.1;
		own.y -= 1.3;
		own.vx += 3.3;
		own.vy -= 0.7;
		own.engineHeat += 5;
		own.energy -= 1.5;
		own.reactorHeat += 0.25;
		own.fireCooldown -= 0.033;
		own.aimSteps = 16384;
		final out:Array<Dynamic> = [];
		for (quantized in [false, true]) {
			final name:String = quantized ? "B" : "A";
			// One remote ship as a map patch entry: its key and patch.
			final one = shapeTick(quantized, 1, remoteBase, remote, ownBase, ownBase, 3);
			final ownOnly = shapeTick(quantized, 0, remoteBase, remote, ownBase, own, 3);
			final tick = shapeTick(quantized, 16, remoteBase, remote, ownBase, own, 3);
			out.push({system: name, remoteShipBytes: one - shapeTick(quantized, 0, remoteBase, remote, ownBase, ownBase, 3), ownShipBytes: ownOnly
				- shapeTick(quantized, 0, remoteBase, remote, ownBase, ownBase, 3), tickArgumentBytes: tick, tickFrameBytes: tick + 9});
		}
		// Yggdrasil: the same as spaceDelta's Bytes, and the call's arguments.
		final yb = yggdrasilShape(1, remoteBase, remote, ownBase, ownBase);
		final y0 = yggdrasilShape(0, remoteBase, remote, ownBase, ownBase);
		final yo = yggdrasilShape(0, remoteBase, remote, ownBase, own);
		final yt = yggdrasilShape(16, remoteBase, remote, ownBase, own);
		out.push({system: "Y", remoteShipBytes: yb - y0, ownShipBytes: yo - y0, tickArgumentBytes: yt, tickFrameBytes: yt + 9});
		for (line in out) {
			println(haxe.Json.stringify(line));
		}
		// Inputs, A and B: one, and the last four.
		final a = new Pair(new MatchACommands(), new ClientA());
		final inputA = new InputA();
		inputA.seq = 1000;
		inputA.controls = 5;
		inputA.aimSteps = 16384;
		a.server.commands.input(inputA);
		final oneA:Int = a.argumentBytes();
		a.server.commands.inputs(36000, 1000, [for (_ in 0...4) inputA]);
		final fourA:Int = a.argumentBytes();
		final b = new Pair(new MatchBCommands(), new ClientB());
		final inputB = new InputB();
		inputB.controls = 5;
		inputB.aimSteps = 16384;
		b.server.commands.input(1000, inputB);
		final oneB:Int = b.argumentBytes();
		b.server.commands.inputs(36000, 1000, [for (_ in 0...4) inputB]);
		final fourB:Int = b.argumentBytes();
		final y = new Pair(new SpaceCommands(), new SpaceClient());
		y.server.commands.spaceInput(1, InputCodec.encode(new ShipInput(1000, 5, 16384)));
		final oneY:Int = y.argumentBytes();
		println(haxe.Json.stringify({inputs: true, A: oneA, A4: fourA, B: oneB, B4: fourB, Y: oneY, Y4: 4 * oneY, frame: 9}));
	}

	/** The arguments of a tick of `others` remote ships (base and current alike for each) and the own ship. **/
	static function shapeTick(quantized:Bool, others:Int, remoteBase:ShipState, remote:ShipState, ownBase:ShipState, own:ShipState, keyStep:Int):Int {
		final ownPatch = new RPCPatch(RPCCodecs.of(OwnShip));
		final b = new OwnShip().set(ownBase);
		final c = new OwnShip().set(own);
		final keys = new IdList();
		for (i in 0...others) {
			keys.push(2 + i);
		}
		if (quantized) {
			final before = new IntMap<OtherShipB>();
			final now = new IntMap<OtherShipB>();
			for (i in 0...others) {
				before.set(2 + i, new OtherShipB().set(remoteBase));
				now.set(2 + i, new OtherShipB().set(remote));
			}
			final pair = new Pair(new MatchBCommands(), new ClientB());
			pair.server.commands.matchState(36000, 35998, ownPatch.diff(b, c), new RPCMapPatch(RPCCodecs.of(OtherShipB)).diffKeys(before, keys, now, keys));
			return pair.argumentBytes();
		}
		final before = new IntMap<OtherShipA>();
		final now = new IntMap<OtherShipA>();
		for (i in 0...others) {
			before.set(2 + i, new OtherShipA().set(remoteBase));
			now.set(2 + i, new OtherShipA().set(remote));
		}
		final pair = new Pair(new MatchACommands(), new ClientA());
		pair.server.commands.matchState(36000, 35998, ownPatch.diff(b, c), new RPCMapPatch(RPCCodecs.of(OtherShipA)).diffKeys(before, keys, now, keys));
		return pair.argumentBytes();
	}

	/** The same tick through Yggdrasil's codec, as spaceDelta's arguments. **/
	static function yggdrasilShape(others:Int, remoteBase:ShipState, remote:ShipState, ownBase:ShipState, own:ShipState):Int {
		final before:Array<SnapshotEntity> = [{id: 1, payload: ShipStateCodec.encodeOwn(ownBase)}];
		final now:Array<SnapshotEntity> = [{id: 1, payload: ShipStateCodec.encodeOwn(own)}];
		for (i in 0...others) {
			before.push({id: 2 + i, payload: ShipStateCodec.encodeOther(remoteBase)});
			now.push({id: 2 + i, payload: ShipStateCodec.encodeOther(remote)});
		}
		final delta:Delta = DeltaCompute.compute(Snapshots.create(35998, StellarProtocol.SNAPSHOT_SCHEMA, before), Snapshots.create(36000, StellarProtocol.SNAPSHOT_SCHEMA, now));
		final writer = new Writer(1024);
		DeltaCodec.encode(delta, writer);
		final pair = new Pair(new SpaceCommands(), new SpaceClient());
		pair.server.commands.spaceDelta(7, writer.bytes());
		return pair.argumentBytes();
	}

	// ------------------------------------------------------------ a run

	static function run(system:String, count:Int):Dynamic {
		final bench:System = switch (system) {
			case "A": new TypedSystem(false);
			case "B": new TypedSystem(true);
			case "S": new StreamSystem();
			case "Y": new YggdrasilSystem();
			case other: throw 'no system $other';
		};
		// Warm: the first ticks grow what the rest reuse, and the jvm compiles.
		final warm:Int = 60;
		for (t in 0...warm) {
			bench.tick(t);
		}
		bench.begin();
		var sendTime:Float = 0;
		var readTime:Float = 0;
		var bytes:Float = 0;
		var frameBytes:Float = 0;
		var messages:Int = 0;
		for (t in warm...count) {
			final a:Float = haxe.Timer.stamp();
			bench.send(t);
			final b:Float = haxe.Timer.stamp();
			bench.read(t);
			final c:Float = haxe.Timer.stamp();
			sendTime += b - a;
			readTime += c - b;
			bytes += bench.argumentBytes;
			frameBytes += bench.frameBytes;
			messages += SHIPS;
		}
		final extra:Dynamic = bench.extra(messages);
		bench.end();
		// The inputs: one a tick, and the last four.
		final inputTimes = bench.inputs(count);
		var allocated:Float = -1;
		#if (cpp || jvm)
		final cursor:Array<Int> = [warm];
		try {
			final reading = crossbyte.test.AllocationMeter.measure(() -> {
				final at:Int = cursor[0];
				cursor[0] = at + 1;
				bench.tick(warm + (at % (count - warm)));
			}, 300);
			allocated = reading.perOperation / SHIPS;
		} catch (_:Dynamic) {
			// Natively a tick that allocates kilobytes crosses the
			// collector's holes too often to be read: none counted.
			allocated = -2;
		}
		#end
		final result:Dynamic = {
			system: system,
			target: target(),
			messages: messages,
			argumentBytes: bytes / messages,
			frameBytes: frameBytes / messages,
			sendNs: sendTime / messages * 1e9,
			readNs: readTime / messages * 1e9,
			allocatedPerMessage: allocated,
			inputBytes: inputTimes.bytes,
			inputNs: inputTimes.ns,
			lastFourBytes: inputTimes.fourBytes,
			lastFourNs: inputTimes.fourNs
		};
		if (extra != null) {
			for (field in Reflect.fields(extra)) {
				Reflect.setField(result, field, Reflect.field(extra, field));
			}
		}
		return result;
	}

	public static function state(t:Int, ship:Int):ShipState {
		return ticks[t][ship];
	}

	public static function input(t:Int, ship:Int):ShipInput {
		return inputs[t][ship];
	}

	static function target():String {
		#if cpp
		return "native";
		#elseif jvm
		return "jvm";
		#elseif js
		return "node";
		#else
		return "interp";
		#end
	}

	static function println(line:String):Void {
		#if sys
		Sys.println(line);
		#else
		js.Syntax.code("console.log({0})", line);
		#end
	}

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		final at:Int = args.indexOf(name);
		return at >= 0 && at + 1 < args.length ? Std.parseInt(args[at + 1]) : fallback;
	}

	static function stringArg(args:Array<String>, name:String, fallback:Null<String>):Null<String> {
		final at:Int = args.indexOf(name);
		return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
	}
}

// ---------------------------------------------------------------- systems

class System {
	public var argumentBytes:Int = 0;
	public var frameBytes:Int = 0;

	/** Every observer's message made and sent. **/
	public function send(t:Int):Void {}

	/** Every message read by its client and applied. **/
	public function read(t:Int):Void {}

	public function tick(t:Int):Void {
		send(t);
		read(t);
	}

	/** Inputs, one a tick and the last four, per ship per tick: their bytes and their round trip. **/
	public function inputs(count:Int):{bytes:Float, ns:Float, fourBytes:Float, fourNs:Float} {
		return {bytes: 0, ns: 0, fourBytes: 0, fourNs: 0};
	}

	/** Called as the measured ticks begin, after the warm ones. **/
	public function begin():Void {}

	/** Called as they end. **/
	public function end():Void {}

	/** What a system measures beside the rest, by message. **/
	public function extra(messages:Int):Dynamic {
		return null;
	}
}

/** Keeps what is sent, to be read when asked: a frame per observer. **/
class Capture implements INetConnection {
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

	/** The last frame sent, its bytes. **/
	public final kept:ByteArray = new ByteArray();
	public var keptLength:Int = 0;

	var __onData:ByteArrayInput->Void = input -> {};
	var __onClose:Reason->Void = reason -> {};
	var __onError:Reason->Void = reason -> {};
	var __onReady:Void->Void = () -> {};
	var __read:Bool = true;

	public function new() {
		kept.length = 4096;
	}

	public function send(data:ByteArray):Void {
		final n:Int = data.length - data.position;
		if (kept.length < n) {
			kept.length = n;
		}
		(kept : Bytes).blit(0, data, data.position, n);
		keptLength = n;
	}

	/** Hands the kept frame to `into`'s reader, as its connection would. **/
	public function deliverTo(into:Capture):Void {
		kept.position = 0;
		final length:Int = kept.length;
		kept.length = keptLength;
		into.__onData(kept);
		kept.length = length;
	}

	public function close():Void {}

	public function expose():Transport {
		return null;
	}

	function get_remoteAddress():String {
		return "memory";
	}

	function get_remotePort():Int {
		return 0;
	}

	function get_localAddress():String {
		return "memory";
	}

	function get_localPort():Int {
		return 0;
	}

	function get_connected():Bool {
		return true;
	}

	function get_readEnabled():Bool {
		return __read;
	}

	function set_readEnabled(value:Bool):Bool {
		return __read = value;
	}

	function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	function get_onClose():Reason->Void {
		return __onClose;
	}

	function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	function get_onError():Reason->Void {
		return __onError;
	}

	function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	function get_onReady():Void->Void {
		return __onReady;
	}

	function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}

/** A server's session and a client's, joined by two captures. **/
class Pair<C:RPCCommands> {
	public final out:Capture = new Capture();
	public final into:Capture = new Capture();
	public final server:RPCSession<C>;
	public final client:RPCSession<Dynamic>;

	public function new(commands:C, handler:RPCHandler<Dynamic, Dynamic>) {
		server = new RPCSession<C>(out, commands);
		client = new RPCSession(into, null, handler);
	}

	/** The frame last sent, read by the client. **/
	public inline function deliver():Void {
		out.deliverTo(into);
	}

	/** The frame's bytes past its length, flags and op: the arguments. **/
	public inline function argumentBytes():Int {
		return out.keptLength - 9;
	}
}

// ------------------------------------------------------- CrossByte, typed

class OwnShip implements RPCStruct {
	public var lastSeq:VarUInt = 0;
	public var x:Float = 0;
	public var y:Float = 0;
	public var vx:Float = 0;
	public var vy:Float = 0;
	public var engineHeat:Float = 0;
	public var energy:Float = 0;
	public var reactorHeat:Float = 0;
	public var dragTimer:Float = 0;
	public var fireCooldown:Float = 0;
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var engineLocked:Bool = false;

	public function new() {}

	public function set(s:ShipState):OwnShip {
		lastSeq = s.lastSeq;
		x = s.x;
		y = s.y;
		vx = s.vx;
		vy = s.vy;
		engineHeat = s.engineHeat;
		energy = s.energy;
		reactorHeat = s.reactorHeat;
		dragTimer = s.dragTimer;
		fireCooldown = s.fireCooldown;
		aimSteps = s.aimSteps;
		controls = (s.controls : Int) & ShipControls.ALL;
		engineLocked = s.engineLocked;
		return this;
	}
}

/** Another player's ship with today's field types. **/
class OtherShipA implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var vx:Float32 = 0;
	public var vy:Float32 = 0;
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var engineLocked:Bool = false;
	public var engineHeat:Float32 = 0;

	public function new() {}

	public function set(s:ShipState):OtherShipA {
		x = s.x;
		y = s.y;
		vx = s.vx;
		vy = s.vy;
		aimSteps = s.aimSteps;
		controls = (s.controls : Int) & ShipControls.ALL;
		engineLocked = s.engineLocked;
		engineHeat = s.engineHeat;
		return this;
	}
}

/** The same, quantized: the design's bounds, the heat's from Stellar's rules. **/
@:rpcBits
class OtherShipB implements RPCStruct {
	public var aimSteps:UInt16 = 0;
	@:range(0, 63) public var controls:Int = 0;
	@:quantize(0, ShipRules.MAX_ENGINE_HEAT, 10) public var engineHeat:Float = 0;
	public var engineLocked:Bool = false;
	@:quantize(-1024, 1024, 16) public var vx:Float = 0;
	@:quantize(-1024, 1024, 16) public var vy:Float = 0;
	@:quantize(-8192, 8192, 16) public var x:Float = 0;
	@:quantize(-8192, 8192, 16) public var y:Float = 0;

	public function new() {}

	public function set(s:ShipState):OtherShipB {
		x = s.x;
		y = s.y;
		vx = s.vx;
		vy = s.vy;
		aimSteps = s.aimSteps;
		controls = (s.controls : Int) & ShipControls.ALL;
		engineLocked = s.engineLocked;
		engineHeat = s.engineHeat;
		return this;
	}
}

class InputA implements RPCStruct {
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var seq:VarUInt = 0;

	public function new() {}
}

@:rpcBits
class InputB implements RPCStruct {
	@:range(0, 63) public var controls:Int = 0;
	@:range(0, 65535) public var aimSteps:Int = 0;

	public function new() {}
}

interface MatchA {
	function matchState(tick:VarUInt, base:VarUInt, own:RPCPatch<OwnShip>, others:RPCMapPatch<OtherShipA>):Void;
	function input(input:InputA):Void;
	function inputs(ack:VarUInt, newest:VarUInt, recent:Array<InputA>):Void;
}

interface MatchB {
	function matchState(tick:VarUInt, base:VarUInt, own:RPCPatch<OwnShip>, others:RPCMapPatch<OtherShipB>):Void;
	function input(seq:VarUInt, input:InputB):Void;
	function inputs(ack:VarUInt, newest:VarUInt, recent:Array<InputB>):Void;
}

@:rpcContract(MatchA)
class MatchACommands extends RPCCommands {
	public function new() {}
}

@:rpcContract(MatchB)
class MatchBCommands extends RPCCommands {
	public function new() {}
}

/** A client's frames: the own ship and the others' map, with its keys, by tick. **/
class ClientFrames<V> {
	public final own:Array<OwnShip> = [for (_ in 0...ReplicationBench.WINDOW) new OwnShip()];
	public final values:Array<IntMap<V>> = [for (_ in 0...ReplicationBench.WINDOW) new IntMap<V>()];
	public final keys:Array<IdList> = [for (_ in 0...ReplicationBench.WINDOW) new IdList()];
	public var applied:Int = -1;

	public function new() {}
}

class ClientA extends RPCHandler implements MatchA {
	public final frames = new ClientFrames<OtherShipA>();
	public var lastInput:Int = 0;

	public function new() {}

	public function matchState(tick:VarUInt, base:VarUInt, own:RPCPatch<OwnShip>, others:RPCMapPatch<OtherShipA>):Void {
		final into:Int = (tick : Int) & (ReplicationBench.WINDOW - 1);
		final from:Int = (base : Int) & (ReplicationBench.WINDOW - 1);
		final f = frames;
		if (own.isFull) {
			own.apply(null, f.own[into]);
			others.applyKeys(null, null, f.values[into], f.keys[into], true);
		} else {
			own.apply(f.own[from], f.own[into]);
			others.applyKeys(f.values[from], f.keys[from], f.values[into], f.keys[into], true);
		}
		f.applied = tick;
	}

	public function input(input:InputA):Void {
		lastInput = input.seq;
	}

	public function inputs(ack:VarUInt, newest:VarUInt, @:reuse recent:Array<InputA>):Void {
		lastInput = newest;
	}
}

class ClientB extends RPCHandler implements MatchB {
	public final frames = new ClientFrames<OtherShipB>();
	public var lastInput:Int = 0;

	public function new() {}

	public function matchState(tick:VarUInt, base:VarUInt, own:RPCPatch<OwnShip>, others:RPCMapPatch<OtherShipB>):Void {
		final into:Int = (tick : Int) & (ReplicationBench.WINDOW - 1);
		final from:Int = (base : Int) & (ReplicationBench.WINDOW - 1);
		final f = frames;
		if (own.isFull) {
			own.apply(null, f.own[into]);
			others.applyKeys(null, null, f.values[into], f.keys[into], true);
		} else {
			own.apply(f.own[from], f.own[into]);
			others.applyKeys(f.values[from], f.keys[from], f.values[into], f.keys[into], true);
		}
		f.applied = tick;
	}

	public function input(seq:VarUInt, @:reuse input:InputB):Void {
		lastInput = seq;
	}

	public function inputs(ack:VarUInt, newest:VarUInt, @:reuse recent:Array<InputB>):Void {
		lastInput = newest;
	}
}

/**
	CrossByte's patches: a frame of the world's values per tick, shared by
	every observer, and per observer a view of ids and a ring of own ships.
**/
class TypedSystem extends System {
	final quantized:Bool;
	final pairsA:Array<Pair<MatchACommands>> = [];
	final pairsB:Array<Pair<MatchBCommands>> = [];
	final clientsA:Array<ClientA> = [];
	final clientsB:Array<ClientB> = [];
	// Shared per tick: the world's values, in a ring.
	final worldA:Array<IntMap<OtherShipA>> = [for (_ in 0...ReplicationBench.WINDOW) new IntMap<OtherShipA>()];
	final worldB:Array<IntMap<OtherShipB>> = [for (_ in 0...ReplicationBench.WINDOW) new IntMap<OtherShipB>()];
	// Per observer: the ids it sees (the others, the same every tick here),
	// its own ship by tick, and its patches.
	final views:Array<IdList> = [];
	final own:Array<Array<OwnShip>> = [];
	final ownPatch:Array<RPCPatch<OwnShip>> = [];
	final patchA:Array<RPCMapPatch<OtherShipA>> = [];
	final patchB:Array<RPCMapPatch<OtherShipB>> = [];

	public function new(quantized:Bool) {
		this.quantized = quantized;
		for (o in 0...ReplicationBench.SHIPS) {
			final view = new IdList();
			for (i in 0...ReplicationBench.SHIPS) {
				if (i != o) {
					view.push(i + 1);
				}
			}
			views.push(view);
			own.push([for (_ in 0...ReplicationBench.WINDOW) new OwnShip()]);
			ownPatch.push(new RPCPatch(RPCCodecs.of(OwnShip)));
			if (quantized) {
				final client = new ClientB();
				clientsB.push(client);
				pairsB.push(new Pair(new MatchBCommands(), client));
				patchB.push(new RPCMapPatch(RPCCodecs.of(OtherShipB)));
			} else {
				final client = new ClientA();
				clientsA.push(client);
				pairsA.push(new Pair(new MatchACommands(), client));
				patchA.push(new RPCMapPatch(RPCCodecs.of(OtherShipA)));
			}
		}
	}

	/** The world's values for tick `t`, into its frame: once a tick, for every observer. **/
	function commit(t:Int):Void {
		final slot:Int = t & (ReplicationBench.WINDOW - 1);
		for (i in 0...ReplicationBench.SHIPS) {
			final s = ReplicationBench.state(t, i);
			if (quantized) {
				var v = worldB[slot].get(i + 1);
				if (v == null) {
					v = new OtherShipB();
					worldB[slot].set(i + 1, v);
				}
				v.set(s);
			} else {
				var v = worldA[slot].get(i + 1);
				if (v == null) {
					v = new OtherShipA();
					worldA[slot].set(i + 1, v);
				}
				v.set(s);
			}
		}
	}

	override public function send(t:Int):Void {
		commit(t);
		final slot:Int = t & (ReplicationBench.WINDOW - 1);
		final base:Int = t - ReplicationBench.LAG;
		final full:Bool = base < 0;
		final from:Int = base & (ReplicationBench.WINDOW - 1);
		argumentBytes = 0;
		frameBytes = 0;
		for (o in 0...ReplicationBench.SHIPS) {
			final mine = own[o][slot].set(ReplicationBench.state(t, o));
			final ownP = ownPatch[o].diff(full ? null : own[o][from], mine);
			if (quantized) {
				final p = patchB[o].diffKeys(full ? null : worldB[from], views[o], worldB[slot], views[o]);
				pairsB[o].server.commands.matchState(t, base, ownP, p);
				argumentBytes += pairsB[o].argumentBytes();
				frameBytes += pairsB[o].out.keptLength;
			} else {
				final p = patchA[o].diffKeys(full ? null : worldA[from], views[o], worldA[slot], views[o]);
				pairsA[o].server.commands.matchState(t, base, ownP, p);
				argumentBytes += pairsA[o].argumentBytes();
				frameBytes += pairsA[o].out.keptLength;
			}
		}
	}

	override public function read(t:Int):Void {
		for (o in 0...ReplicationBench.SHIPS) {
			if (quantized) {
				pairsB[o].deliver();
				if (clientsB[o].frames.applied != t) {
					throw "a tick was not applied";
				}
			} else {
				pairsA[o].deliver();
				if (clientsA[o].frames.applied != t) {
					throw "a tick was not applied";
				}
			}
		}
	}

	override public function inputs(count:Int):{bytes:Float, ns:Float, fourBytes:Float, fourNs:Float} {
		final one:Array<Float> = [0, 0];
		final four:Array<Float> = [0, 0];
		final recentA:Array<InputA> = [for (_ in 0...4) new InputA()];
		final recentB:Array<InputB> = [for (_ in 0...4) new InputB()];
		final singleA = new InputA();
		final singleB = new InputB();
		var n:Int = 0;
		for (round in 0...2) {
			for (t in 4...count) {
				for (o in 0...ReplicationBench.SHIPS) {
					final input = ReplicationBench.input(t, o);
					final a:Float = haxe.Timer.stamp();
					if (quantized) {
						singleB.controls = (input.controls : Int) & ShipControls.ALL;
						singleB.aimSteps = input.aimSteps;
						pairsB[o].server.commands.input(input.seq, singleB);
						pairsB[o].deliver();
					} else {
						singleA.controls = (input.controls : Int) & ShipControls.ALL;
						singleA.aimSteps = input.aimSteps;
						singleA.seq = input.seq;
						pairsA[o].server.commands.input(singleA);
						pairsA[o].deliver();
					}
					final b:Float = haxe.Timer.stamp();
					final singleBytes:Int = quantized ? pairsB[o].argumentBytes() : pairsA[o].argumentBytes();
					for (k in 0...4) {
						final earlier = ReplicationBench.input(t - 3 + k, o);
						if (quantized) {
							recentB[k].controls = (earlier.controls : Int) & ShipControls.ALL;
							recentB[k].aimSteps = earlier.aimSteps;
						} else {
							recentA[k].controls = (earlier.controls : Int) & ShipControls.ALL;
							recentA[k].aimSteps = earlier.aimSteps;
							recentA[k].seq = earlier.seq;
						}
					}
					final c:Float = haxe.Timer.stamp();
					if (quantized) {
						pairsB[o].server.commands.inputs(t - ReplicationBench.LAG, input.seq, recentB);
						pairsB[o].deliver();
					} else {
						pairsA[o].server.commands.inputs(t - ReplicationBench.LAG, input.seq, recentA);
						pairsA[o].deliver();
					}
					final d:Float = haxe.Timer.stamp();
					if (round == 1) {
						// The second round, warm.
						one[0] += singleBytes;
						four[0] += quantized ? pairsB[o].argumentBytes() : pairsA[o].argumentBytes();
						one[1] += b - a;
						four[1] += d - c;
						n++;
					}
				}
			}
		}
		return {bytes: one[0] / n, ns: one[1] / n * 1e9, fourBytes: four[0] / n, fourNs: four[1] / n * 1e9};
	}
}

// ------------------------------------------------------- one bit stream

/**
	The design's question, two sections or one stream: the others' map patch
	alone, as the bit layout writes it (`RPCMapPatch.write`: each ship's mask
	and bit fields in a bit section padded to a byte, then `aimSteps` in its
	byte section) against the same patches as one bit stream (counts and keys
	as varints of 8-bit groups, then each ship's mask and every changed field,
	`aimSteps` 16 bits among them, padded once), hand written with
	`BitWriter` and `BitReader`. Each observer's patch is diffed once; the
	writing and the reading are timed apart, and both applied into a frame.
**/
class StreamSystem extends System {
	final typed = new TypedSystem(true);
	final writer = new crossbyte.io.BitWriter(512);
	final reader = new crossbyte.io.BitReader();
	final sectioned:Array<ByteArray> = [];
	final streamed:Array<ByteArray> = [];
	final readPatch = new RPCMapPatch(RPCCodecs.of(OtherShipB));
	final framesB:Array<Array<IntMap<OtherShipB>>> = [];
	final keysB:Array<Array<IdList>> = [];
	final framesS:Array<Array<IntMap<OtherShipB>>> = [];
	var sectionBytes:Float = 0;
	var streamBytes:Float = 0;
	var sectionWrite:Float = 0;
	var streamWrite:Float = 0;
	var sectionRead:Float = 0;
	var streamRead:Float = 0;
	var counting:Bool = false;

	public function new() {
		for (o in 0...ReplicationBench.SHIPS) {
			sectioned.push(new ByteArray());
			streamed.push(new ByteArray());
			framesB.push([for (_ in 0...ReplicationBench.WINDOW) new IntMap<OtherShipB>()]);
			keysB.push([for (_ in 0...ReplicationBench.WINDOW) new IdList()]);
			framesS.push([for (_ in 0...ReplicationBench.WINDOW) new IntMap<OtherShipB>()]);
		}
	}

	override public function send(t:Int):Void {
		@:privateAccess typed.commit(t);
		final world = @:privateAccess typed.worldB;
		final views = @:privateAccess typed.views;
		final patches = @:privateAccess typed.patchB;
		final slot:Int = t & (ReplicationBench.WINDOW - 1);
		final base:Int = t - ReplicationBench.LAG;
		final full:Bool = base < 0;
		final from:Int = base & (ReplicationBench.WINDOW - 1);
		argumentBytes = 0;
		frameBytes = 0;
		for (o in 0...ReplicationBench.SHIPS) {
			final p = patches[o].diffKeys(full ? null : world[from], views[o], world[slot], views[o]);
			final a:Float = haxe.Timer.stamp();
			final out = sectioned[o];
			out.position = 0;
			out.length = 0;
			p.write(out);
			final b:Float = haxe.Timer.stamp();
			writer.reset();
			writeVar(p.isFull ? 1 : 0);
			writeVar(p.addedCount);
			writeVar(p.updatedCount);
			var previous:Int = 0;
			for (i in 0...p.addedCount) {
				final key:Int = p.addedKey(i);
				writeVar(i == 0 ? key : key - previous - 1);
				previous = key;
				shipBits(RPCCodecs.of(OtherShipB).__default(), world[slot].get(key));
			}
			previous = 0;
			for (i in 0...p.updatedCount) {
				final key:Int = p.updatedKey(i);
				writeVar(i == 0 ? key : key - previous - 1);
				previous = key;
				shipBits(world[from].get(key), world[slot].get(key));
			}
			final bytes:ByteArray = writer.finish();
			final body = streamed[o];
			body.position = 0;
			body.length = 0;
			body.writeBytes(bytes, 0, bytes.length);
			final c:Float = haxe.Timer.stamp();
			if (counting) {
				sectionWrite += b - a;
				streamWrite += c - b;
				sectionBytes += out.length;
				streamBytes += body.length;
			}
			argumentBytes += out.length;
		}
		frameBytes = argumentBytes;
	}

	function writeVar(value:Int):Void {
		var v:Int = value;
		while ((v & ~0x7F) != 0) {
			writer.writeBits((v & 0x7F) | 0x80, 8);
			v >>>= 7;
		}
		writer.writeBits(v, 8);
	}

	function readVar():Int {
		var shift:Int = 0;
		var result:Int = 0;
		while (true) {
			final b:Int = reader.readBits(8);
			result |= (b & 0x7F) << shift;
			if ((b & 0x80) == 0) {
				return result;
			}
			shift += 7;
		}
	}

	function shipBits(base:OtherShipB, current:OtherShipB):Void {
		final mask:Int = RPCCodecs.of(OtherShipB).__mask(base, current);
		writer.writeBits(mask, 8);
		if ((mask & 1) != 0) writer.writeBits(current.aimSteps, 16);
		if ((mask & 2) != 0) writer.writeBits(current.controls, 6);
		if ((mask & 4) != 0) writer.writeQuantized(current.engineHeat, 0, ShipRules.MAX_ENGINE_HEAT, 10);
		if ((mask & 8) != 0) writer.writeBool(current.engineLocked);
		if ((mask & 16) != 0) writer.writeQuantized(current.vx, -1024, 1024, 16);
		if ((mask & 32) != 0) writer.writeQuantized(current.vy, -1024, 1024, 16);
		if ((mask & 64) != 0) writer.writeQuantized(current.x, -8192, 8192, 16);
		if ((mask & 128) != 0) writer.writeQuantized(current.y, -8192, 8192, 16);
	}

	override public function read(t:Int):Void {
		final slot:Int = t & (ReplicationBench.WINDOW - 1);
		final base:Int = t - ReplicationBench.LAG;
		final from:Int = base & (ReplicationBench.WINDOW - 1);
		for (o in 0...ReplicationBench.SHIPS) {
			final a:Float = haxe.Timer.stamp();
			final out = sectioned[o];
			out.position = 0;
			readPatch.read(out);
			if (readPatch.isFull) {
				readPatch.applyKeys(null, null, framesB[o][slot], keysB[o][slot], true);
			} else {
				readPatch.applyKeys(framesB[o][from], keysB[o][from], framesB[o][slot], keysB[o][slot], true);
			}
			final b:Float = haxe.Timer.stamp();
			final body = streamed[o];
			reader.reset(body, 0, body.length);
			final into = framesS[o][slot];
			final was = framesS[o][from];
			final full:Bool = readVar() != 0;
			final added:Int = readVar();
			final updated:Int = readVar();
			if (!full) {
				// What the base holds, the same keys every tick here, copied in.
				for (key => value in was) {
					var v = into.get(key);
					if (v == null) {
						v = new OtherShipB();
						into.set(key, v);
					}
					RPCCodecs.of(OtherShipB).copy(value, v);
				}
			}
			for (group in 0...2) {
				var previous:Int = 0;
				for (i in 0...(group == 0 ? added : updated)) {
					final gap:Int = readVar();
					final key:Int = i == 0 ? gap : previous + 1 + gap;
					previous = key;
					var v = into.get(key);
					if (v == null) {
						v = new OtherShipB();
						into.set(key, v);
					}
					final mask:Int = reader.readBits(8);
					if ((mask & 1) != 0) v.aimSteps = reader.readBits(16);
					if ((mask & 2) != 0) v.controls = reader.readBits(6);
					if ((mask & 4) != 0) v.engineHeat = reader.readQuantized(0, ShipRules.MAX_ENGINE_HEAT, 10);
					if ((mask & 8) != 0) v.engineLocked = reader.readBool();
					if ((mask & 16) != 0) v.vx = reader.readQuantized(-1024, 1024, 16);
					if ((mask & 32) != 0) v.vy = reader.readQuantized(-1024, 1024, 16);
					if ((mask & 64) != 0) v.x = reader.readQuantized(-8192, 8192, 16);
					if ((mask & 128) != 0) v.y = reader.readQuantized(-8192, 8192, 16);
				}
			}
			final c:Float = haxe.Timer.stamp();
			if (counting) {
				sectionRead += b - a;
				streamRead += c - b;
			}
		}
	}

	override public function begin():Void {
		sectionBytes = streamBytes = sectionWrite = streamWrite = sectionRead = streamRead = 0;
		counting = true;
	}

	override public function end():Void {
		counting = false;
	}

	override public function extra(messages:Int):Dynamic {
		return {
			sectionBytes: sectionBytes / messages,
			streamBytes: streamBytes / messages,
			sectionWriteNs: sectionWrite / messages * 1e9,
			streamWriteNs: streamWrite / messages * 1e9,
			sectionReadNs: sectionRead / messages * 1e9,
			streamReadNs: streamRead / messages * 1e9
		};
	}
}

// ------------------------------------------------------- Yggdrasil today

interface SpaceContract {
	function spaceDelta(spaceId:Int, delta:Bytes):Void;
	function spaceInput(op:Int, payload:Bytes):Void;
}

@:rpcContract(SpaceContract)
class SpaceCommands extends RPCCommands {
	public function new() {}
}

class SpaceClient extends RPCHandler implements SpaceContract {
	public final snapshots:Array<Null<Snapshot>> = [for (_ in 0...ReplicationBench.WINDOW) null];
	public final own:ShipState = new ShipState();
	public final others:IntMap<ShipState> = new IntMap();
	public var applied:Int = -1;
	public var lastInput:Int = 0;
	public var self:Int = 0;

	public function new() {}

	public function spaceDelta(spaceId:Int, bytes:Bytes):Void {
		final delta:Delta = DeltaCodec.decode(new Reader(bytes));
		final base:Null<Snapshot> = delta.fromTick == 0 ? null : snapshots[delta.fromTick & (ReplicationBench.WINDOW - 1)];
		final next:Snapshot = DeltaApply.apply(base, delta);
		snapshots[delta.toTick & (ReplicationBench.WINDOW - 1)] = next;
		// What the game then does with it: each changed ship decoded.
		for (entry in delta.entries) {
			if (entry.op == DeltaOp.Add || entry.op == DeltaOp.Update) {
				if (entry.id == self) {
					ShipStateCodec.decodeOwn(entry.payload, own);
				} else {
					var ship = others.get(entry.id);
					if (ship == null) {
						ship = new ShipState();
						others.set(entry.id, ship);
					}
					ShipStateCodec.decodeOther(entry.payload, ship);
				}
			}
		}
		applied = delta.toTick;
	}

	public function spaceInput(op:Int, payload:Bytes):Void {
		lastInput = InputCodec.decode(payload).seq;
	}
}

/**
	Yggdrasil's way today: per tick each ship's payload encoded once
	(`ShipStateCodec.encodeOther`), each observer's snapshot made of them and
	its own ship's (`encodeOwn`), its delta against the snapshot of the tick
	it acknowledged computed and encoded, and sent as `spaceDelta`.
**/
class YggdrasilSystem extends System {
	final pairs:Array<Pair<SpaceCommands>> = [];
	final clients:Array<SpaceClient> = [];
	final snapshots:Array<Array<Null<Snapshot>>> = [];
	final writer = new Writer(1024);

	public function new() {
		for (o in 0...ReplicationBench.SHIPS) {
			final client = new SpaceClient();
			client.self = o + 1;
			clients.push(client);
			pairs.push(new Pair(new SpaceCommands(), client));
			snapshots.push([for (_ in 0...ReplicationBench.WINDOW) null]);
		}
	}

	override public function send(t:Int):Void {
		final others:Array<Bytes> = [for (i in 0...ReplicationBench.SHIPS) ShipStateCodec.encodeOther(ReplicationBench.state(t, i))];
		final base:Int = t - ReplicationBench.LAG;
		argumentBytes = 0;
		frameBytes = 0;
		for (o in 0...ReplicationBench.SHIPS) {
			final entities:Array<SnapshotEntity> = [];
			for (i in 0...ReplicationBench.SHIPS) {
				entities.push({id: i + 1, payload: i == o ? ShipStateCodec.encodeOwn(ReplicationBench.state(t, i)) : others[i]});
			}
			final current:Snapshot = Snapshots.create(t + 1, StellarProtocol.SNAPSHOT_SCHEMA, entities);
			final previous:Null<Snapshot> = base < 0 ? null : snapshots[o][base & (ReplicationBench.WINDOW - 1)];
			snapshots[o][t & (ReplicationBench.WINDOW - 1)] = current;
			final delta:Delta = DeltaCompute.compute(previous, current);
			writer.clear();
			DeltaCodec.encode(delta, writer);
			pairs[o].server.commands.spaceDelta(7, writer.bytes());
			argumentBytes += pairs[o].argumentBytes();
			frameBytes += pairs[o].out.keptLength;
		}
	}

	override public function read(t:Int):Void {
		for (o in 0...ReplicationBench.SHIPS) {
			pairs[o].deliver();
			if (clients[o].applied != t + 1) {
				throw "a tick was not applied";
			}
		}
	}

	override public function inputs(count:Int):{bytes:Float, ns:Float, fourBytes:Float, fourNs:Float} {
		var bytes:Float = 0;
		var time:Float = 0;
		var n:Int = 0;
		for (round in 0...2) {
			for (t in 4...count) {
				for (o in 0...ReplicationBench.SHIPS) {
					final a:Float = haxe.Timer.stamp();
					pairs[o].server.commands.spaceInput(1, InputCodec.encode(ReplicationBench.input(t, o)));
					pairs[o].deliver();
					final b:Float = haxe.Timer.stamp();
					if (round == 1) {
						bytes += pairs[o].argumentBytes();
						time += b - a;
						n++;
					}
				}
			}
		}
		return {bytes: bytes / n, ns: time / n * 1e9, fourBytes: 4 * bytes / n, fourNs: 4 * time / n * 1e9};
	}
}
