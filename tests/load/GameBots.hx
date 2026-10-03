import GameServer.CountingCongestion;
import LoadMain.Args;
import LoadStats.Histogram;
import LoadStats.ProcessStats;
import LoadStats.Report;
import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DeliveryMode;
import crossbyte.net.ReliableDatagramSocket;
import haxe.Timer;

/**
	Game clients for scenario G, a process of them: each a
	`ReliableDatagramSocket` of its own, as a player's is, sending an input
	every tick and an action every tenth, and reading the server's
	snapshots.

	```
	LoadMain game-bots --host 127.0.0.1 --port P --count 250 --hz 60
	                   --seconds 120 [--report 10] [--rate 200]
	```

	Input to acknowledgement is measured here, on one clock: from an input
	going out to the first snapshot naming it or a later one. (Not a
	snapshot's age from the server's clock: hxcpp's `Timer.stamp()` counts
	from each process's start on Windows, so two processes' stamps do not
	compare.) A snapshot missing is one whose tick never arrived: lost, or
	overtaken by a newer one on its sequenced channel.
**/
class GameBots {
	static inline var RING:Int = 256;

	var runtime:CrossByte;
	var host:String;
	var port:Int;
	var count:Int;
	var hz:Int;
	var seconds:Float;
	var reportEvery:Float;
	var rate:Int;

	var bots:Array<Bot> = [];
	var input:ByteArray = new ByteArray();
	var action:ByteArray = new ByteArray();
	var tick:Int = 0;
	var closing:Bool = false;

	var latency:Histogram = new Histogram();
	var snapshots:Float = 0;
	var reliableSnapshots:Float = 0;
	var inputs:Float = 0;
	var ioErrors:Int = 0;
	var unexpectedCloses:Int = 0;
	var connectFailures:Int = 0;
	var lossesReported:Int = 0;
	var timeoutsReported:Int = 0;
	var lastSample:ProcessStats;

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		host = args.string("host", "127.0.0.1");
		port = args.int("port", 0);
		count = args.int("count", 100);
		hz = args.int("hz", 60);
		seconds = args.float("seconds", 60);
		reportEvery = args.float("report", 10);
		rate = args.int("rate", 200);
	}

	public function start():Void {
		runtime.tps = hz;
		input.length = 25;
		action.length = 45;
		lastSample = ProcessStats.sample();

		// At `rate` a second, so a thousand clients are not one burst of
		// CONNECTs: a real server's players arrive over time.
		var opened:Int = 0;
		var perStep:Int = Std.int(Math.max(1, rate / 20));
		var opener:Int = -1;
		opener = crossbyte.Timer.setInterval(0.0, 0.05, () -> {
			for (_ in 0...perStep) {
				if (opened >= count) {
					crossbyte.Timer.clear(opener);
					return;
				}
				__open(opened++);
			}
		});

		runtime.addEventListener(TickEvent.TICK, __onTick);
		crossbyte.Timer.setInterval(reportEvery, reportEvery, __report);
		crossbyte.Timer.setTimeout(seconds, __close);
	}

	function __open(index:Int):Void {
		var bot = new Bot(index);
		var socket = new ReliableDatagramSocket();
		bot.socket = socket;
		socket.congestionControl = new CountingCongestion();
		socket.addEventListener(Event.CONNECT, _ -> {
			bot.connected = true;
		});
		socket.addEventListener(DatagramSocketDataEvent.DATA, (e:DatagramSocketDataEvent) -> __onSnapshot(bot, e.data));
		socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> {
			if (!bot.connected) {
				connectFailures++;
			} else if (!closing) {
				ioErrors++;
			}
			if (ioErrors + connectFailures <= 3) {
				Report.say("bot " + index + ": " + e.text);
			}
		});
		socket.addEventListener(Event.CLOSE, _ -> {
			if (!closing) {
				unexpectedCloses++;
			}
			bot.connected = false;
			bot.closed = true;
		});
		bots.push(bot);
		try {
			socket.connect(host, port);
		} catch (error:Dynamic) {
			connectFailures++;
			Report.say("bot " + index + " connect: " + Std.string(error));
		}
	}

	function __onTick(_:TickEvent):Void {
		if (closing) {
			return;
		}
		tick++;
		var now:Float = Timer.stamp();
		var withAction:Bool = tick % 10 == 0;
		for (bot in bots) {
			if (!bot.connected) {
				continue;
			}
			bot.inputSeq++;
			bot.sentAt[bot.inputSeq & (RING - 1)] = now;
			input.position = 0;
			input.writeByte(GameServer.INPUT);
			input.writeInt(bot.inputSeq);
			try {
				bot.socket.send(input, 0, 25, DeliveryMode.sequenced(1));
				inputs++;
				if (withAction) {
					action.position = 0;
					action.writeByte(GameServer.ACTION);
					action.writeInt(tick);
					bot.socket.send(action, 0, 45, DeliveryMode.RELIABLE);
				}
			} catch (error:Dynamic) {
				ioErrors++;
			}
		}
	}

	function __onSnapshot(bot:Bot, data:ByteArray):Void {
		var now:Float = Timer.stamp();
		data.position = 0;
		var type:Int = data.readUnsignedByte();
		if (type != GameServer.SNAPSHOT && type != GameServer.RELIABLE_SNAPSHOT) {
			return;
		}
		if (type == GameServer.RELIABLE_SNAPSHOT) {
			reliableSnapshots++;
		}
		var snapshotTick:Int = data.readInt();
		var acknowledged:Int = data.readInt();
		snapshots++;

		if (bot.firstTick < 0) {
			bot.firstTick = snapshotTick;
		}
		if (snapshotTick > bot.lastTick) {
			bot.lastTick = snapshotTick;
		}
		bot.received++;

		// The newest input the server has, timed from when it went out --
		// if it is recent enough to be in the ring, which every one acked
		// within four seconds at sixty a second is.
		if (acknowledged > bot.lastAcked && bot.inputSeq - acknowledged < RING) {
			latency.add((now - bot.sentAt[acknowledged & (RING - 1)]) * 1000);
			bot.lastAcked = acknowledged;
		}
	}

	function __report():Void {
		var connected:Int = 0;
		var expected:Float = 0;
		var received:Float = 0;
		for (bot in bots) {
			if (bot.connected) {
				connected++;
			}
			if (bot.firstTick >= 0) {
				expected += bot.lastTick - bot.firstTick + 1;
				received += bot.received;
			}
		}
		// Missing since the last report: what the ticks span less what came.
		var missingNow:Float = expected - received;
		var sample:ProcessStats = ProcessStats.sample();
		Report.emit({
			kind: "game-bots",
			connected: connected,
			snapshots: snapshots,
			reliableSnapshots: reliableSnapshots,
			missing: missingNow - missingReported,
			inputs: inputs,
			ioErrors: ioErrors,
			unexpectedCloses: unexpectedCloses,
			connectFailures: connectFailures,
			losses: CountingCongestion.losses - lossesReported,
			timeouts: CountingCongestion.timeouts - timeoutsReported,
			cpu: (sample.cpu - lastSample.cpu),
			rssMB: ProcessStats.mb(sample.rss),
			latency: latency.encode()
		});
		missingReported = missingNow;
		lossesReported = CountingCongestion.losses;
		timeoutsReported = CountingCongestion.timeouts;
		lastSample = sample;
		latency.clear();
		snapshots = 0;
		reliableSnapshots = 0;
		inputs = 0;
		ioErrors = 0;
		unexpectedCloses = 0;
		connectFailures = 0;
	}

	var missingReported:Float = 0;

	/** Every client closes gracefully, and the process goes once they have. **/
	function __close():Void {
		__report();
		closing = true;
		for (bot in bots) {
			try {
				if (bot.socket.connected) {
					bot.socket.close();
				}
			} catch (_:Dynamic) {}
		}
		var giveUpAt:Float = Timer.stamp() + 15;
		crossbyte.Timer.setInterval(0.1, 0.1, () -> {
			var open:Int = 0;
			for (bot in bots) {
				if (!bot.closed && bot.socket.connected) {
					open++;
				}
			}
			if (open == 0 || Timer.stamp() > giveUpAt) {
				Report.emit({kind: "game-bots-closed", stillOpen: open});
				Sys.exit(0);
			}
		});
	}
}

class Bot {
	public var index:Int;
	public var socket:ReliableDatagramSocket;
	public var connected:Bool = false;
	public var closed:Bool = false;
	public var inputSeq:Int = 0;
	public var lastAcked:Int = 0;
	public var sentAt:Array<Float> = [for (_ in 0...256) 0.0];
	public var firstTick:Int = -1;
	public var lastTick:Int = -1;
	public var received:Float = 0;

	public function new(index:Int) {
		this.index = index;
	}
}
