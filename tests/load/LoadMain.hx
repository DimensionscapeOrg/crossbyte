import IdleServer.IdleBots;
import LoadStats.Report;
import crossbyte.core.ServerApplication;
import crossbyte.events.Event;
import crossbyte.events.NativeProcessEvent;
import crossbyte.sys.NativeProcess;
import crossbyte.sys.NativeProcessStartupInfo;

/**
	Load and churn, run the way a server and a game server run: for minutes,
	at scale, with the clients in other processes, measuring what the server
	costs and whether what it holds comes back down. `ci/soak.hxml` asks
	whether a long-running process survives; this asks what it costs and
	where it gives out. The README's Testing section says how to run each.

	One executable plays every part, by its first argument. The three
	scenarios each start their server in this process and their clients as
	children, this executable again, or Node for the churn's TLS clients,
	so the clients' processor time and memory are never counted as the
	server's, and gather the children's reports into their own.

	```
	LoadMain game  --clients 1000 --hz 60 --seconds 600
	LoadMain churn --plan 50:300,200:300,1000:300,0:120 --client node
	LoadMain idle  --clients 10000 --seconds 60
	```

	Every process prints `LOAD {json}` lines: a window every `--report`
	seconds, and a summary (`"kind":"...-summary"`) at the end. A run's exit
	status is 0 when it finished and every client saw what it should have;
	the numbers are for reading, not gating, as the benchmarks' are.

	The parts the scenarios start themselves, `game-bots`, `churn-bots`,
	`idle-bots`: can also be started by hand against a server on another
	machine, with `--host` and `--port`.
**/
class LoadMain extends ServerApplication {
	static var args:Args;

	public static function main():Void {
		args = new Args(Sys.args());
		#if crossbyte_libuv_native
		if (args.flag("libuv") && !crossbyte.libuv.LibuvPoll.install()) {
			Report.say("the libuv backend did not install");
			Sys.exit(2);
		}
		#end
		new LoadMain();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __init);
	}

	function __init(_:Event):Void {
		try {
			switch (args.role) {
				case "game":
					new GameServer(crossByte, args).start();
				case "game-bots":
					new GameBots(crossByte, args).start();
				case "churn":
					new ChurnServer(crossByte, args).start();
				case "churn-bots":
					new ChurnBots(crossByte, args).start();
				case "idle":
					new IdleServer(crossByte, args).start();
				case "idle-bots":
					new IdleBots(crossByte, args).start();
				default:
					Report.say("usage: LoadMain <game|churn|idle|game-bots|churn-bots|idle-bots> [--name value]...");
					Report.say("see tests/load/LoadMain.hx and the README's Testing section");
					Sys.exit(2);
			}
		} catch (error:Dynamic) {
			Report.say("load: " + args.role + " failed to start: " + Std.string(error));
			Sys.exit(3);
		}
	}
}

/** `role --name value --flag ...`, read once. **/
class Args {
	public var role(default, null):String;

	var values:Map<String, String> = new Map();

	public function new(raw:Array<String>) {
		role = raw.length > 0 ? raw[0] : "";
		var i:Int = 1;
		while (i < raw.length) {
			var name:String = raw[i];
			if (StringTools.startsWith(name, "--")) {
				name = name.substr(2);
				if (i + 1 < raw.length && !StringTools.startsWith(raw[i + 1], "--")) {
					values.set(name, raw[i + 1]);
					i += 2;
					continue;
				}
				values.set(name, "true");
			}
			i++;
		}
	}

	public function string(name:String, fallback:String):String {
		var value:Null<String> = values.get(name);
		return value == null ? fallback : value;
	}

	public function int(name:String, fallback:Int):Int {
		var value:Null<Int> = Std.parseInt(string(name, ""));
		return value == null ? fallback : value;
	}

	public function float(name:String, fallback:Float):Float {
		var value:Float = Std.parseFloat(string(name, ""));
		return Math.isNaN(value) ? fallback : value;
	}

	public function flag(name:String):Bool {
		return values.get(name) == "true";
	}
}

/**
	The children a scenario starts, and what they report. Each line a child
	prints is passed to `onRecord` once parsed; anything that is not a
	`LOAD` line is echoed with the child's name, so a client's failure shows
	in the server's output. `onExit` gets each child's exit code.
**/
class Children {
	public var running(default, null):Int = 0;
	public var failed(default, null):Int = 0;

	var processes:Array<NativeProcess> = [];
	var onRecord:Dynamic->Void;
	var echo:Bool;

	public function new(onRecord:Dynamic->Void, echo:Bool = true) {
		this.onRecord = onRecord;
		this.echo = echo;
	}

	/** This executable again, with `role` and `arguments`. **/
	public function spawnSelf(name:String, role:String, arguments:Array<String>, ?executable:String):Void {
		var self:String = executable != null ? executable : Sys.programPath();
		if (StringTools.endsWith(self, ".jar")) {
			spawn(name, "java", ["-jar", self, role].concat(arguments));
		} else {
			spawn(name, self, [role].concat(arguments));
		}
	}

	public function spawn(name:String, executable:String, arguments:Array<String>):Void {
		var process = new NativeProcess();
		var pending:String = "";
		process.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, (event:NativeProcessEvent) -> {
			pending += event.text;
			var newline:Int = pending.indexOf("\n");
			while (newline >= 0) {
				var line:String = StringTools.trim(pending.substr(0, newline));
				pending = pending.substr(newline + 1);
				__line(name, line);
				newline = pending.indexOf("\n");
			}
		});
		process.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, (event:NativeProcessEvent) -> {
			if (echo) {
				for (line in event.text.split("\n")) {
					if (StringTools.trim(line) != "") {
						Report.say("[" + name + " stderr] " + StringTools.trim(line));
					}
				}
			}
		});
		process.addEventListener(NativeProcessEvent.EXIT, (event:NativeProcessEvent) -> {
			if (pending != "") {
				__line(name, StringTools.trim(pending));
				pending = "";
			}
			running--;
			if (event.exitCode != 0) {
				failed++;
				Report.say("[" + name + "] exited " + event.exitCode);
			}
		});
		processes.push(process);
		running++;
		process.start(new NativeProcessStartupInfo(executable, arguments));
	}

	function __line(name:String, line:String):Void {
		if (line == "") {
			return;
		}
		var record:Null<Dynamic> = Report.parse(line);
		if (record != null) {
			record.from = name;
			onRecord(record);
		} else if (echo) {
			Report.say("[" + name + "] " + line);
		}
	}

	/** Ends every child still running. **/
	public function killAll():Void {
		for (process in processes) {
			try {
				process.exit();
			} catch (_:Dynamic) {}
		}
	}
}
