import LoadMain.Args;
import LoadMain.Children;
import LoadStats.Histogram;
import LoadStats.ProcessStats;
import LoadStats.Report;
import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.CongestionControl;
import crossbyte.net.DeliveryMode;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import haxe.Timer;

/**
	Scenario G: an authoritative game server over reliable UDP.

	Every tick the server sends each client a snapshot (100 to 400 bytes,
	varied, sequenced, with every `--reliable-every`th one reliable) naming
	the newest input it has from that client. Each client sends an input
	every tick (sequenced) and an action every tenth (reliable). What the
	server does between is nothing a real game would not do more of; the
	point is what the transport and the runtime cost per client per tick.

	```
	LoadMain game --clients 1000 --hz 60 --seconds 600 [--procs 4]
	              [--warmup 10] [--report 10] [--reliable-every 4]
	              [--bots <native exe>] [--rate 200]
	              [--world-mb 1024 --world-churn 0.0002]
	```

	The run: the server alone, measured after a full collection (the
	baseline); the clients started in `--procs` processes and connected;
	`--warmup` seconds; a full collection again, which with the baseline
	gives memory per session; `--seconds` measured, a window reported every
	`--report`; the clients closing; and a last full collection once every
	session has gone, which should be back at the baseline: a session's
	worth of anything left over per client is a leak.

	Per window and for the run: the server's processor time per tick (user
	and kernel); the tick handler's own time (`step`), the tick to its last
	datagram sent (`tick`), and the whole frame's work as the runtime's
	`cpuLoad` gives it (timers, the tick, sending, and reading every input
	that arrived);
	frames that overran their interval, how late the loop ran, input to
	acknowledgement as the clients see it, the gap from one tick's start to
	the next (where a collection's pause shows, with `--world-mb` of live
	world data held), snapshots lost or superseded,
	the transport's loss and timeout events on both ends, and heap, resident
	memory and handles.
**/
@:access(crossbyte.core.CrossByte)
class GameServer {
	public static inline var SNAPSHOT:Int = 1;
	public static inline var INPUT:Int = 2;
	public static inline var ACTION:Int = 3;
	public static inline var RELIABLE_SNAPSHOT:Int = 4;

	var runtime:CrossByte;
	var args:Args;
	var clients:Int;
	var hz:Int;
	var seconds:Float;
	var warmup:Float;
	var reportEvery:Float;
	var reliableEvery:Int;
	var world:Null<World> = null;

	var server:ReliableDatagramServerSocket;
	var sessions:Array<GameSession> = [];
	var children:Children;
	var scratch:ByteArray = new ByteArray();
	var tick:Int = 0;

	// What this window and the whole measured run have seen.
	var stepTimes:Histogram = new Histogram();
	var tickTimes:Histogram = new Histogram();
	var frameWork:Histogram = new Histogram();
	var runStep:Histogram = new Histogram();
	var runTick:Histogram = new Histogram();
	var runFrame:Histogram = new Histogram();
	var tickEnd:TickEnd;
	// Tick start to tick start: a frame held up by anything (a collection
	// above all) shows here, where cpuLoad stops at a whole frame.
	var tickGaps:Histogram = new Histogram();
	var runGaps:Histogram = new Histogram();
	var lastTickAt:Float = -1;
	var runLatency:Histogram = new Histogram();
	var windowLatency:Histogram = new Histogram();

	var windowTicks:Int = 0;
	var windowInputs:Int = 0;
	var windowActions:Int = 0;
	var windowSnapshots:Int = 0;
	var windowBytes:Float = 0;
	var windowClient:ClientTotals = new ClientTotals();
	var runClient:ClientTotals = new ClientTotals();
	var runTicks:Int = 0;
	var runSnapshots:Float = 0;
	var runInputs:Float = 0;

	var connects:Int = 0;
	var closes:Int = 0;
	var serverErrors:Int = 0;
	var overrunsAtStart:Int = 0;
	var debtAtStart:Float = 0;
	var maxLag:Float = 0;
	var runMaxLag:Float = 0;

	var phase:String = "connecting";
	var baseline:ProcessStats;
	var steady:ProcessStats;
	var measuredFrom:Float = 0;
	var windowFrom:Float = 0;
	var windowSample:ProcessStats;
	var runSample:ProcessStats;
	var started:Float;
	var windows:Array<Dynamic> = [];

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		this.args = args;
		clients = args.int("clients", 100);
		hz = args.int("hz", 60);
		seconds = args.float("seconds", 60);
		warmup = args.float("warmup", 10);
		reportEvery = args.float("report", 10);
		reliableEvery = args.int("reliable-every", 4);
	}

	public function start():Void {
		started = Timer.stamp();
		runtime.tps = hz;

		server = new ReliableDatagramServerSocket();
		// One CONNECT per client, all at once: the default 256 is for a
		// server facing strangers, and these are expected.
		server.maxPendingConnections = clients + 256;
		server.congestionControlFor = (_, _) -> new CountingCongestion();
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, __onConnect);
		server.bind(0, args.string("host", "127.0.0.1"));
		server.listen();

		var worldMb:Float = args.float("world-mb", 0);
		if (worldMb > 0) {
			var built:Float = Timer.stamp();
			world = new World(worldMb, args.float("world-churn", 0.0002));
			Report.emit({kind: "game-world", entities: world.entities.length, seconds: round(Timer.stamp() - built)});
		}

		var baselineGcMs:Float = cpp_gc();
		baseline = ProcessStats.sample();
		Report.emit({
			kind: "game-start",
			fullCollectionMs: round(baselineGcMs),
			port: server.localPort,
			clients: clients,
			hz: hz,
			seconds: seconds,
			heapLiveMB: ProcessStats.mb(baseline.heapLive),
			rssMB: ProcessStats.mb(baseline.rss),
			handles: baseline.handles
		});

		tickEnd = new TickEnd(runtime, (elapsed) -> {
			if (phase == "measuring") {
				tickTimes.add(elapsed * 1000);
			}
		});
		runtime.addEventListener(TickEvent.TICK, __onTick);

		// The clients, in processes of their own.
		var procs:Int = args.int("procs", Std.int(Math.max(1, Math.ceil(clients / 250))));
		children = new Children(__onRecord);
		var botSeconds:Float = seconds + warmup + 30 + clients / 200;
		var assigned:Int = 0;
		for (i in 0...procs) {
			var share:Int = Std.int(clients / procs) + (i < clients % procs ? 1 : 0);
			assigned += share;
			children.spawnSelf("bots" + i, "game-bots", [
				"--host", server.localAddress == "0.0.0.0" ? "127.0.0.1" : server.localAddress,
				"--port", Std.string(server.localPort),
				"--count", Std.string(share),
				"--hz", Std.string(hz),
				"--seconds", Std.string(botSeconds),
				"--report", Std.string(reportEvery),
				"--rate", Std.string(args.int("rate", 200))
			], args.string("bots", null));
		}

		// Connected, or given up on, within a minute.
		var giveUpAt:Float = Timer.stamp() + 60 + clients / 100;
		var waiting:Int = -1;
		waiting = crossbyte.Timer.setInterval(0.25, 0.25, () -> {
			if (phase != "connecting") {
				return;
			}
			if (sessions.length >= clients || Timer.stamp() > giveUpAt) {
				crossbyte.Timer.clear(waiting);
				phase = "warmup";
				Report.emit({kind: "game-connected", sessions: sessions.length, of: clients, seconds: round(Timer.stamp() - started)});
				crossbyte.Timer.setTimeout(warmup, __beginMeasuring);
			}
		});
	}

	function __beginMeasuring():Void {
		var gcMs:Float = cpp_gc();
		steady = ProcessStats.sample();
		var n:Int = sessions.length > 0 ? sessions.length : 1;
		Report.emit({
			kind: "game-steady",
			sessions: sessions.length,
			fullCollectionMs: round(gcMs),
			heapLiveMB: ProcessStats.mb(steady.heapLive),
			rssMB: ProcessStats.mb(steady.rss),
			privateMB: ProcessStats.mb(steady.privateBytes),
			handles: steady.handles,
			heapPerSessionKB: Math.round((steady.heapLive - baseline.heapLive) / n / 102.4) / 10,
			rssPerSessionKB: Math.round((steady.rss - baseline.rss) / n / 102.4) / 10
		});

		// After the collection's pause, and what it held up, has passed.
		crossbyte.Timer.setTimeout(3.0, __startWindows);
	}

	function __startWindows():Void {
		phase = "measuring";
		measuredFrom = windowFrom = Timer.stamp();
		windowSample = runSample = ProcessStats.sample();
		overrunsAtStart = runtime.frameOverruns;
		debtAtStart = runtime.droppedScheduleDebt;
		__clearWindow();
		crossbyte.Timer.setInterval(reportEvery, reportEvery, __report);
		crossbyte.Timer.setTimeout(seconds, __endMeasuring);
	}

	function __endMeasuring():Void {
		__report();
		phase = "closing";
		var end:ProcessStats = ProcessStats.sample();
		var wall:Float = Timer.stamp() - measuredFrom;
		var cpu:Float = (end.cpu - runSample.cpu);
		var summary:Dynamic = {
			kind: "game-summary",
			clients: clients,
			sessions: sessions.length,
			hz: hz,
			seconds: round(wall),
			ticks: runTicks,
			ticksPerSecond: round(runTicks / wall),
			cpuCores: round(cpu / wall),
			cpuMsPerTick: round(cpu * 1000 / Math.max(1, runTicks)),
			// What Windows' tick-sampled accounting charged, beside the exact
			// figure above: the two part where a tick is shorter than the clock's.
			sampledCpuMsPerTick: round(((end.user - runSample.user) + (end.kernel - runSample.kernel)) * 1000 / Math.max(1, runTicks)),
			userMsPerTick: round((end.user - runSample.user) * 1000 / Math.max(1, runTicks)),
			kernelMsPerTick: round((end.kernel - runSample.kernel) * 1000 / Math.max(1, runTicks)),
			cpuUsPerClientTick: round(cpu * 1e6 / Math.max(1, runTicks) / Math.max(1, sessions.length)),
			step: runStep.summary(),
			tick: runTick.summary(),
			tickGap: runGaps.summary(),
			worldEntities: world != null ? world.entities.length : 0,
			frameWork: runFrame.summary(),
			overruns: runtime.frameOverruns - overrunsAtStart,
			droppedScheduleSeconds: round(runtime.droppedScheduleDebt - debtAtStart),
			loopLagMaxMs: round(runMaxLag * 1000),
			snapshotsPerSecond: Math.round(runSnapshots / wall),
			inputsPerSecond: Math.round(runInputs / wall),
			inputToAck: runLatency.summary(),
			client: runClient.toRecord(wall),
			serverLosses: CountingCongestion.losses,
			serverTimeouts: CountingCongestion.timeouts,
			connects: connects,
			closes: closes,
			serverErrors: serverErrors,
			heapLiveMB: ProcessStats.mb(end.heapLive),
			heapNowMB: ProcessStats.mb(end.heapNow),
			rssMB: ProcessStats.mb(end.rss),
			privateMB: ProcessStats.mb(end.privateBytes),
			handles: end.handles,
			baselineHeapLiveMB: ProcessStats.mb(baseline.heapLive),
			baselineRssMB: ProcessStats.mb(baseline.rss),
			steadyHeapLiveMB: ProcessStats.mb(steady.heapLive),
			steadyRssMB: ProcessStats.mb(steady.rss),
			heapPerSessionKB: Math.round((steady.heapLive - baseline.heapLive) / Math.max(1, clients) / 102.4) / 10,
			rssPerSessionKB: Math.round((steady.rss - baseline.rss) / Math.max(1, clients) / 102.4) / 10
		};
		Report.emit(summary);

		// The clients close on their own deadline; once every session has
		// gone, and a little after, what is left is compared with the start.
		// Long enough for the clients' own deadline and then the idle timeout
		// of any session whose close never got through: the last to go.
		var giveUpAt:Float = Timer.stamp() + 45 + clients / 200 + server.idleTimeout + 30;
		var watch:Int = -1;
		watch = crossbyte.Timer.setInterval(0.5, 0.5, () -> {
			if ((sessions.length > 0 || children.running > 0) && Timer.stamp() < giveUpAt) {
				return;
			}
			crossbyte.Timer.clear(watch);
			crossbyte.Timer.setTimeout(2.0, __afterClose);
		});
	}

	function __afterClose():Void {
		cpp_gc();
		var after:ProcessStats = ProcessStats.sample();
		var clean:Bool = children.failed == 0 && runClient.ioErrors == 0 && runClient.unexpectedCloses == 0 && runClient.connectFailures == 0
			&& sessions.length == 0;
		Report.emit({
			kind: "game-after",
			sessionsLeft: sessions.length,
			lastCloseAfterSeconds: round(lastCloseAt - measuredFrom - seconds),
			children: children.running,
			childFailures: children.failed,
			heapLiveMB: ProcessStats.mb(after.heapLive),
			heapReservedMB: ProcessStats.mb(after.heapReserved),
			baselineHeapLiveMB: ProcessStats.mb(baseline.heapLive),
			heapLeftPerClientB: Math.round((after.heapLive - baseline.heapLive) / Math.max(1, clients)),
			rssMB: ProcessStats.mb(after.rss),
			baselineRssMB: ProcessStats.mb(baseline.rss),
			privateMB: ProcessStats.mb(after.privateBytes),
			baselinePrivateMB: ProcessStats.mb(baseline.privateBytes),
			handles: after.handles,
			baselineHandles: baseline.handles,
			timers: runtime.__timer.size,
			clean: clean
		});
		children.killAll();
		Sys.exit(clean ? 0 : 1);
	}

	var lastCloseAt:Float = 0;

	function __onConnect(event:ReliableDatagramSocketConnectEvent):Void {
		var socket:ReliableDatagramSocket = event.socket;
		var session = new GameSession(socket, sessions.length);
		sessions.push(session);
		connects++;
		socket.addEventListener(DatagramSocketDataEvent.DATA, (e:DatagramSocketDataEvent) -> {
			var data:ByteArray = e.data;
			data.position = 0;
			var type:Int = data.readUnsignedByte();
			var seq:Int = data.readInt();
			if (type == INPUT) {
				if (seq - session.lastInput > 0) {
					session.lastInput = seq;
				}
				windowInputs++;
			} else if (type == ACTION) {
				windowActions++;
			}
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> serverErrors++);
		socket.addEventListener(Event.CLOSE, _ -> {
			closes++;
			lastCloseAt = Timer.stamp();
			sessions.remove(session);
		});
	}

	function __onTick(_:TickEvent):Void {
		var started:Float = Timer.stamp();
		tick++;
		if (phase == "measuring" && lastTickAt >= 0) {
			tickGaps.add((started - lastTickAt) * 1000);
		}
		lastTickAt = started;
		if (world != null) {
			world.step(tick);
		}

		// The frame before this one: everything the loop did in it but wait.
		if (phase == "measuring") {
			var interval:Float = 1 / hz;
			frameWork.add(runtime.cpuLoad / 100 * interval * 1000);
			var lag:Float = runtime.loopLag;
			if (lag > maxLag) {
				maxLag = lag;
			}
		}

		var reliable:Bool = reliableEvery > 0 && tick % reliableEvery == 0;
		for (session in sessions) {
			// 100 to 400 bytes, different for each client and each tick.
			var size:Int = 100 + ((tick * 7 + session.index * 13) % 301);
			scratch.position = 0;
			scratch.writeByte(reliable ? RELIABLE_SNAPSHOT : SNAPSHOT);
			scratch.writeInt(tick);
			scratch.writeInt(session.lastInput);
			scratch.length = size;
			try {
				session.socket.send(scratch, 0, size, reliable ? DeliveryMode.RELIABLE : DeliveryMode.sequenced(0));
				windowSnapshots++;
				windowBytes += size;
			} catch (_:Dynamic) {
				serverErrors++;
			}
		}

		if (phase == "measuring") {
			stepTimes.add((Timer.stamp() - started) * 1000);
			windowTicks++;
		}
		tickEnd.arm(started);
	}

	function __onRecord(record:Dynamic):Void {
		if (record.kind != "game-bots") {
			return;
		}
		if (phase != "measuring") {
			return;
		}
		var latency = Histogram.decode(record.latency);
		windowLatency.merge(latency);
		windowClient.add(record);
	}

	function __report():Void {
		if (phase != "measuring") {
			return;
		}
		var now:Float = Timer.stamp();
		var wall:Float = now - windowFrom;
		if (wall < 0.5) {
			// The interval's report and the run's last, at the same moment.
			return;
		}
		var sample:ProcessStats = ProcessStats.sample();
		var cpu:Float = (sample.cpu - windowSample.cpu);
		var record:Dynamic = {
			kind: "game-window",
			t: round(now - measuredFrom),
			sessions: sessions.length,
			ticks: windowTicks,
			cpuCores: round(cpu / wall),
			cpuMsPerTick: round(cpu * 1000 / Math.max(1, windowTicks)),
			kernelShare: round((sample.kernel - windowSample.kernel) / Math.max(1e-9, (sample.user - windowSample.user) + (sample.kernel - windowSample.kernel))),
			step: stepTimes.summary(),
			tick: tickTimes.summary(),
			tickGap: tickGaps.summary(),
			frameWork: frameWork.summary(),
			overruns: runtime.frameOverruns - overrunsAtStart,
			loopLagMaxMs: round(maxLag * 1000),
			snapshotsPerSecond: Math.round(windowSnapshots / wall),
			inputsPerSecond: Math.round(windowInputs / wall),
			actionsPerSecond: Math.round(windowActions / wall),
			kbPerClientSecond: round(windowBytes / Math.max(1, sessions.length) / wall / 1024),
			inputToAck: windowLatency.summary(),
			client: windowClient.toRecord(wall),
			serverLosses: CountingCongestion.losses,
			serverTimeouts: CountingCongestion.timeouts,
			serverErrors: serverErrors,
			heapLiveMB: ProcessStats.mb(sample.heapLive),
			heapNowMB: ProcessStats.mb(sample.heapNow),
			heapReservedMB: ProcessStats.mb(sample.heapReserved),
			rssMB: ProcessStats.mb(sample.rss),
			privateMB: ProcessStats.mb(sample.privateBytes),
			handles: sample.handles,
			timers: runtime.__timer.size
		};
		Report.emit(record);

		runStep.merge(stepTimes);
		runTick.merge(tickTimes);
		runGaps.merge(tickGaps);
		runFrame.merge(frameWork);
		runLatency.merge(windowLatency);
		runClient.merge(windowClient);
		runTicks += windowTicks;
		runSnapshots += windowSnapshots;
		runInputs += windowInputs;
		if (maxLag > runMaxLag) {
			runMaxLag = maxLag;
		}
		windowSample = sample;
		windowFrom = now;
		__clearWindow();
	}

	function __clearWindow():Void {
		stepTimes.clear();
		tickTimes.clear();
		tickGaps.clear();
		frameWork.clear();
		windowLatency.clear();
		windowClient = new ClientTotals();
		windowTicks = 0;
		windowInputs = 0;
		windowActions = 0;
		windowSnapshots = 0;
		windowBytes = 0;
		maxLag = 0;
	}

	static inline function round(value:Float):Float {
		return Math.round(value * 1000) / 1000;
	}

	/** A full collection, and how long it held the process, in ms. **/
	static function cpp_gc():Float {
		var started:Float = Timer.stamp();
		#if cpp
		cpp.vm.Gc.run(true);
		#elseif (java || jvm)
		java.lang.System.gc();
		#end
		return (Timer.stamp() - started) * 1000;
	}
}

/**
	The end of a tick's pass: once the snapshots it queued are on the wire.

	Queued for the pass flush after the tick's sends, it queues itself once
	more when its turn comes, which puts it behind the datagram socket's own
	flush (queued during the walk, when the first session handed it a
	datagram), so what it records runs from the tick handler's start to
	the last `sendto` or `sendmmsg`.
**/
@:access(crossbyte.core.CrossByte)
class TickEnd implements crossbyte.core._internal.PassFlush {
	var runtime:CrossByte;
	var record:Float->Void;
	var started:Float = -1;
	var requeued:Bool = false;

	public function new(runtime:CrossByte, record:Float->Void) {
		this.runtime = runtime;
		this.record = record;
	}

	public function arm(started:Float):Void {
		this.started = started;
		requeued = false;
		runtime.__queuePassFlush(this);
	}

	public function __flushPass():Void {
		if (!requeued) {
			requeued = true;
			runtime.__queuePassFlush(this);
			return;
		}
		if (started >= 0) {
			record(Timer.stamp() - started);
			started = -1;
		}
	}
}

/**
	Live world data, as a game server holds it: `--world-mb` megabytes of
	entities, each a handful of numbers, a component array and a name,
	listed and indexed by id: millions of small objects, which is what a
	collector that stops the world has to mark. Every tick some move, and
	`--world-churn` of them are despawned and replaced, so the heap keeps
	making garbage the way a world does, and collections keep happening
	with all of it live.
**/
class World {
	public var entities:Array<WorldEntity> = [];

	var byId:Map<Int, WorldEntity> = new Map();
	var churn:Float;
	var nextId:Int = 0;
	var seed:Int = 0x2545F491;

	public function new(megabytes:Float, churn:Float) {
		this.churn = churn;
		// About 300 bytes each as hxcpp lays them out, measured: the object,
		// its eight-slot component array, its name, and its slot in the index.
		var count:Int = Std.int(megabytes * 1048576 / 300);
		for (_ in 0...count) {
			spawn(entities.length);
		}
	}

	function spawn(slot:Int):Void {
		var e = new WorldEntity(nextId++, random(4096), random(4096));
		e.name = "e" + e.id;
		for (i in 0...8) {
			e.components.push(random(1000));
		}
		entities[slot] = e;
		byId.set(e.id, e);
	}

	public function step(tick:Int):Void {
		var n:Int = entities.length;
		// A thousand move a tick; churn of the world is despawned and spawned.
		for (_ in 0...1000) {
			var e = entities[random(n)];
			e.x += e.vx;
			e.y += e.vy;
		}
		var replace:Int = Std.int(n * churn);
		for (_ in 0...replace) {
			var slot:Int = random(n);
			byId.remove(entities[slot].id);
			spawn(slot);
		}
	}

	inline function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}
}

class WorldEntity {
	public var id:Int;
	public var x:Float;
	public var y:Float;
	public var z:Float = 0;
	public var vx:Float = 0.5;
	public var vy:Float = -0.25;
	public var hp:Int = 100;
	public var name:String;
	public var components:Array<Int> = [];

	public function new(id:Int, x:Float, y:Float) {
		this.id = id;
		this.x = x;
		this.y = y;
	}
}

class GameSession {
	public var socket:ReliableDatagramSocket;
	public var index:Int;
	public var lastInput:Int = 0;

	public function new(socket:ReliableDatagramSocket, index:Int) {
		this.socket = socket;
		this.index = index;
	}
}

/**
	TCP's Reno, as every session gets by default, counting what it is told:
	each loss found from what arrived after it, and each frame that waited
	out its whole timeout. Each is at least one frame sent again.
**/
class CountingCongestion extends CongestionControl {
	public static var losses:Int = 0;
	public static var timeouts:Int = 0;

	override public function onLoss(session:ReliableDatagramSocket, now:Float):Void {
		losses++;
		super.onLoss(session, now);
	}

	override public function onTimeout(session:ReliableDatagramSocket, now:Float):Void {
		timeouts++;
		super.onTimeout(session, now);
	}
}

/** What the client processes reported, added up. **/
class ClientTotals {
	public var connected:Int = 0;
	public var snapshots:Float = 0;
	public var reliableSnapshots:Float = 0;
	public var duplicates:Float = 0;
	public var reliableDuplicates:Float = 0;
	public var missing:Float = 0;
	public var inputs:Float = 0;
	public var ioErrors:Int = 0;
	public var unexpectedCloses:Int = 0;
	public var connectFailures:Int = 0;
	public var losses:Int = 0;
	public var timeouts:Int = 0;
	public var cpu:Float = 0;
	public var rssMB:Float = 0;

	public function new() {}

	public function add(record:Dynamic):Void {
		connected += Std.int(record.connected);
		snapshots += record.snapshots;
		reliableSnapshots += record.reliableSnapshots;
		if (record.duplicates != null) {
			duplicates += record.duplicates;
			reliableDuplicates += record.reliableDuplicates;
		}
		missing += record.missing;
		inputs += record.inputs;
		ioErrors += Std.int(record.ioErrors);
		unexpectedCloses += Std.int(record.unexpectedCloses);
		connectFailures += Std.int(record.connectFailures);
		losses += Std.int(record.losses);
		timeouts += Std.int(record.timeouts);
		cpu += record.cpu;
		rssMB += record.rssMB;
	}

	public function merge(other:ClientTotals):Void {
		connected = other.connected;
		snapshots += other.snapshots;
		reliableSnapshots += other.reliableSnapshots;
		duplicates += other.duplicates;
		reliableDuplicates += other.reliableDuplicates;
		missing += other.missing;
		inputs += other.inputs;
		ioErrors += other.ioErrors;
		unexpectedCloses += other.unexpectedCloses;
		connectFailures += other.connectFailures;
		losses += other.losses;
		timeouts += other.timeouts;
		cpu += other.cpu;
		rssMB = other.rssMB;
	}

	public function toRecord(wall:Float):Dynamic {
		return {
			connected: connected,
			snapshotsPerSecond: Math.round(snapshots / wall),
			reliableSnapshotsPerSecond: Math.round(reliableSnapshots / wall),
			missing: missing,
			duplicates: duplicates,
			reliableDuplicates: reliableDuplicates,
			missingShare: snapshots + missing > 0 ? Math.round(missing / (snapshots + missing) * 1e6) / 1e6 : 0,
			inputsPerSecond: Math.round(inputs / wall),
			ioErrors: ioErrors,
			unexpectedCloses: unexpectedCloses,
			connectFailures: connectFailures,
			losses: losses,
			timeouts: timeouts,
			cpuCores: Math.round(cpu / wall * 1000) / 1000,
			rssMB: rssMB
		};
	}
}
