package crossbyte.sys;

import crossbyte.io.File;
import haxe.io.Path;

#if cpp
import cpp.vm.Gc;
import crossbyte._internal.native.sys.NativeSystem;
#end

import crossbyte.core.CrossByte;
#if !(js && !nodejs)
import sys.io.Process;
#end

#if cpp
#if windows
@:access(crossbyte._internal.native.sys.win.WinNativeSystem)
#elseif linux
@:access(crossbyte._internal.native.sys.linux.LinuxNativeSystem)
#elseif (mac || macos)
@:access(crossbyte._internal.native.sys.mac.MacNativeSystem)
#else
@:access(crossbyte._internal.native.sys.NativeSystem)
#end
#end
/** Cross-platform system information and process-level utility accessors. */
class System {
	/**
		The operating system this process is running on: `"windows"`,
		`"linux"`, `"mac"`, `"browser"`, or whatever `Sys.systemName()` reports
		lowercased.

		This was `#if windows ... #elseif linux ... #else "undefined"`, which
		is a question about the build rather than about the machine. Haxe
		sets `windows` for no target. A native build gets it from Lime or
		Aedifex, or from CrossByte's `HostPlatform` macro, which names the
		machine doing the building; hl, neko, eval, the JVM and Node get none.
		So every target but native reported `"undefined"` while running on
		Windows, and every conditional in this class that followed the same
		pattern took the branch written for somebody else.
	**/
	public static var PLATFORM(get, never):String;

	/**
		Whether this process is running on Windows.

		Ask this rather than `#if windows` for anything decided while running.
		The define is still right for choosing types and native includes at
		compile time, and still wrong for choosing a command, an environment
		variable or a path separator.
	**/
	public static var isWindows(get, never):Bool;

	@:noCompletion private static var __platform:String;

	@:noCompletion private static function get_PLATFORM():String {
		if (__platform == null) {
			#if (js && !nodejs)
			__platform = "browser";
			#else
			__platform = switch (Sys.systemName()) {
				case "Windows": "windows";
				case "Linux": "linux";
				case "Mac": "mac";
				case other: other.toLowerCase();
			};
			#end
		}

		return __platform;
	}

	@:noCompletion private static inline function get_isWindows():Bool {
		return PLATFORM == "windows";
	}

	/**
		Pauses the calling thread for `seconds`, as `Sys.sleep` does, except
		that it comes back on the interpreter on Windows.

		There `Sys.sleep` can sleep for 49 days. Haxe 4.3's eval times a
		`Thread.yield()` first and sleeps for `seconds` less what that took,
		measured in the process's CPU time -- which Windows counts in 15.6ms
		ticks, so a tick landing inside the yield leaves a negative remainder,
		and OCaml's Windows `Unix.sleepf` hands it to `Sleep()` unchecked, as
		an unsigned count of milliseconds. Any sleep under about 15ms can do
		it, the more often the busier the process's other threads are. It is
		what hung the interpreter suite now and then, in a different test
		each time. Here the interpreter on Windows sleeps through an empty
		`select`, which OCaml turns into one plain `Sleep()` of the whole
		duration.

		Anywhere else this is `Sys.sleep`, with a negative or NaN duration
		taken as zero. CrossByte itself sleeps through nothing else. Not in a
		browser, which has no way to block a thread.
	**/
	#if !(js && !nodejs)
	public static inline function sleep(seconds:Float):Void {
		crossbyte._internal.system.Sleep.sleep(seconds);
	}
	#end

	/**
		The directory the program is in, which `File.applicationDirectory`
		refers to and `Resources` finds its `resources` directory in: the
		executable's natively and on HashLink/C, the jar's on the jvm, the
		script's on Node, and the bytecode file's on neko and HashLink.

		Not the working directory, which is wherever the program happened to
		be started from: `C:\Windows\System32` for a Windows service, `/` for
		many daemons. It was that, so a program started from anywhere but its
		own directory found none of its files.

		On the interpreter (`--interp`), which runs from source and has no
		program file of its own, it is the working directory -- the one the
		compiler ran in, where its `-cp` and `resources` paths are read from.

		@throws IllegalOperationError In a browser.
	**/
	public static var appDir(get, never):String;

	/**
		The name this application's data is kept under: the last part of
		`appStorageDir`, so what keeps one application's `Store` apart from
		another's.

		The `crossbyte_app_id` define when the build sets one --
		`-D crossbyte_app_id=com.example.chat` -- which may hold letters,
		digits, `.`, `-`, `_` and spaces, starting with a letter or a digit;
		the build refuses anything else. Otherwise the main class's full
		name, as `com.example.Chat`, which is the same whichever target the
		application is built for, so its native, jvm and Node builds share
		their data. Built with Aedifex, which starts every application at a
		generated `ProgramMain`, it is the class `ProgramMain` starts: the
		project's own main class. A build with no main class -- a library
		loaded by something else -- uses the program's file name without its
		extension.

		Two applications whose main classes have one name -- `Main` is a
		common one -- share their storage. Give each a name of its own with
		the define.
	**/
	public static var applicationId(get, never):String;

	/**
		The application storage directory, which
		`File.applicationStorageDirectory` refers to and `Store` keeps its
		files in: `applicationId` inside the directory each operating system
		keeps applications' data in.

		- Windows: `%APPDATA%\<id>`, as
		  `C:\Users\<user>\AppData\Roaming\<id>`.
		- macOS: `~/Library/Application Support/<id>`.
		- Linux and other POSIX systems: `$XDG_DATA_HOME/<id>`, or
		  `~/.local/share/<id>` where that is not set to an absolute path.

		Created, with any parent it needs, the first time it is asked for.

		@throws IOError The environment names no such directory -- no
		`APPDATA` or `USERPROFILE` on Windows, no `HOME` elsewhere -- or it
		cannot be created.
		@throws IllegalOperationError In a browser, which has no file
		system; `Store` keeps its data in IndexedDB there.
	**/
	public static var appStorageDir(get, never):String;

	/** The user's documents directory, as `File.documentsDirectory` describes it. **/
	public static var documentsDir(get, never):String;

	/** The user's desktop directory, as `File.desktopDirectory` describes it. **/
	public static var desktopDir(get, never):String;

	public static var userDir(get, never):String;

	/**
		Which of the machine's processors this process may run on: one entry
		per processor, as `processorCount` counts them, `true` where the
		process may use it.

		Natively on Windows and Linux. A Windows process's mask covers one
		processor group, at most 64 processors.

		@throws IllegalOperationError Anywhere else: natively on macOS, which
		has no process affinity, and on the jvm, Node, the interpreter, neko,
		HashLink and in a browser, which have no call to ask. It reported
		`[false]` there, every processor unusable, and `[]` on macOS.
	**/
	public static var processAffinity(get, never):Array<Bool>;

	/**
	 * Returns the number of processors, including logical processors, that are available to the system.
	 */
	public static var processorCount(get, never):Int;

	/**
		An identifier of this machine, the same for every program on it and
		across restarts: Windows' `MachineGuid` -- in capitals, without
		braces -- Linux's `/etc/machine-id` (or D-Bus's copy of it in
		`/var/lib/dbus`), and macOS's `IOPlatformUUID`. The same on every
		target on one machine; read once, then kept.

		`null` where there is none: in a browser, which lets a page read no
		such thing, on a Linux system without a machine id (some containers),
		and on any other system. It answered `""` everywhere but native, and
		`null` natively on Linux and macOS.

		It identifies the machine to anyone who sees it. systemd's advice for
		its machine id holds for all three: to tell machines apart from a
		server, send a keyed hash of it -- an HMAC under a key of your
		application's own -- rather than the identifier itself.
	**/
	public static function getDeviceId():Null<String> {
		if (!__deviceIdRead) {
			__deviceId = __readDeviceId();
			__deviceIdRead = true;
		}

		return __deviceId;
	}

	/**
		The share of the runtime thread's last frame spent working, as a
		percentage from 0 to 100: `CrossByte.current().cpuLoad`.

		@throws IllegalOperationError Off a runtime's thread, where there is
		no runtime to ask.
	**/
	public static inline function currentThreadCpuUsage():Float {
		return CrossByte.current().cpuLoad;
	}

	/**
		How much of the machine's processing this process has used -- all of
		its threads, in user and kernel time -- since the previous call, as a
		percentage of all its processors from 0 to 100: a process keeping one
		of eight processors busy reads 12.5. The first call measures from the
		start: of the process on Node, of the JVM on the jvm, and elsewhere of
		the program, when its classes were set up.

		Meant to be read now and then, a second or more apart. Processor time
		is counted in steps -- 15.6 ms on Windows, 10 ms on Linux -- so a
		reading over a few milliseconds is mostly the step; a call within
		10 ms of the previous one returns the previous reading and leaves the
		next to measure from where that one did. It returned 0.

		@throws IllegalOperationError In a browser, which reports no
		processor time, and on a JVM that does not report the process's
		(the HotSpot JVMs do, through `com.sun.management`).
	**/
	public static function totalCpuUsage():Float {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser reports no processor time, so System.totalCpuUsage() is not available there.");
		#else
		var elapsed:Float = __processSeconds();
		var used:Float = __processCpuSeconds();

		if (__cpuMarked && elapsed - __cpuMarkElapsed < 0.01) {
			return __cpuReading;
		}

		var window:Float = __cpuMarked ? elapsed - __cpuMarkElapsed : elapsed;
		var spent:Float = __cpuMarked ? used - __cpuMarkUsed : used;
		var reading:Float = window > 0 ? spent / window / processorCount * 100 : 0;

		// Two clocks, each counted in steps: a short window can put the
		// ratio a step past either end.
		__cpuReading = reading < 0 ? 0 : (reading > 100 ? 100 : reading);
		__cpuMarkElapsed = elapsed;
		__cpuMarkUsed = used;
		__cpuMarked = true;
		return __cpuReading;
		#end
	}

	/**
		Bytes of heap the process is using: natively the collector's figure,
		uncollected garbage included; on the jvm the heap in use; on Node the
		V8 heap in use. Zero where nothing reports it (the interpreter, hl,
		neko, a browser).

		A `Float`, since a heap outgrows an `Int`: this was the collector's
		32-bit figure, which wrapped negative past 2GiB, and 0 on every target
		but native.
	**/
	public static function memoryUsage():Float {
		#if cpp
		return Gc.memInfo64(Gc.MEM_INFO_CURRENT);
		#elseif (java || jvm)
		var runtime = java.lang.Runtime.getRuntime();
		return __longToFloat(runtime.totalMemory()) - __longToFloat(runtime.freeMemory());
		#elseif nodejs
		return js.Node.process.memoryUsage().heapUsed;
		#else
		return 0;
		#end
	}

	#if (java || jvm)
	// Haxe 4 has no Int64 to Float; the halves are joined as doubles, as
	// Timer.stamp does with nanoTime.
	@:noCompletion private static function __longToFloat(value:haxe.Int64):Float {
		var low:Float = haxe.Int64.getLow(value);
		if (low < 0) {
			low += 4294967296.0;
		}
		return haxe.Int64.getHigh(value) * 4294967296.0 + low;
	}
	#end

	@:noCompletion private static var __appDirPath:String;
	@:noCompletion private static var __applicationId:String;
	@:noCompletion private static var __appStorageDirPath:String;
	@:noCompletion private static var __appStorageDirMade:Bool = false;
	@:noCompletion private static var __desktopDirPath:String;
	@:noCompletion private static var __documentsDirPath:String;
	@:noCompletion private static var __userDirPath:String;
	@:noCompletion private static var __deviceId:Null<String> = null;
	@:noCompletion private static var __deviceIdRead:Bool = false;
	@:noCompletion private static var __cpuMarked:Bool = false;
	@:noCompletion private static var __cpuMarkElapsed:Float = 0;
	@:noCompletion private static var __cpuMarkUsed:Float = 0;
	@:noCompletion private static var __cpuReading:Float = 0;
	#if !(js || jvm || java)
	// The program's start, near enough: statics are set up before main. The
	// processor time too, because on the interpreter the process is the
	// compiler, and its compiling is not the program's.
	@:noCompletion private static var __startStamp:Float = haxe.Timer.stamp();
	@:noCompletion private static var __startCpu:Float = Sys.cpuTime();
	#end

	#if !(js && !nodejs)
	/** Seconds since the start a first `totalCpuUsage()` measures from. **/
	@:noCompletion private static function __processSeconds():Float {
		#if nodejs
		return js.Syntax.code("process.uptime()");
		#elseif (jvm || java)
		return __longToFloat(java.lang.management.ManagementFactory.getRuntimeMXBean().getUptime()) / 1000;
		#else
		return haxe.Timer.stamp() - __startStamp;
		#end
	}

	/** The processor time the process has used, all threads, user and kernel, in seconds. **/
	@:noCompletion private static function __processCpuSeconds():Float {
		#if nodejs
		// Not Sys.cpuTime(), which hxnodejs answers with the process's age.
		return js.Syntax.code("(function (u) { return (u.user + u.system) / 1e6; })(process.cpuUsage())");
		#elseif (jvm || java)
		// Not Sys.cpuTime(), which the jvm answers with System.nanoTime(),
		// the wall clock. The HotSpot bean's own interface is not one Haxe
		// can name here, so it is asked by reflection.
		try {
			var bean:Dynamic = java.lang.management.ManagementFactory.getOperatingSystemMXBean();
			var method = java.lang.Class.forName("com.sun.management.OperatingSystemMXBean").getMethod("getProcessCpuTime");
			var nanos:java.lang.Number = cast method.invoke(bean);
			var value:Float = nanos.doubleValue();

			if (value >= 0) {
				return value / 1e9;
			}
		} catch (_:Dynamic) {}

		throw new crossbyte.errors.IllegalOperationError("This JVM does not report the process's processor time, so System.totalCpuUsage() is not available on it.");
		#else
		// User and kernel time of every thread: GetProcessTimes on Windows,
		// times() elsewhere.
		return Sys.cpuTime() - __startCpu;
		#end
	}

	/**
		What `command` prints, run directly rather than through a shell, or
		null if it cannot be run or fails.
	**/
	@:noCompletion private static function __programOutput(command:String, args:Array<String>):Null<String> {
		#if nodejs
		try {
			return js.Syntax.code("require('child_process').execFileSync({0}, {1}, {encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore']})", command, args);
		} catch (_:Dynamic) {
			return null;
		}
		#else
		try {
			var process:Process = new Process(command, args);
			var output:String = process.stdout.readAll().toString();
			// Before close(): eval refuses the exit code of a closed process.
			var status:Int = process.exitCode();
			process.close();
			return status == 0 ? output : null;
		} catch (_:Dynamic) {
			return null;
		}
		#end
	}
	#end

	@:noCompletion private static function __readDeviceId():Null<String> {
		#if (js && !nodejs)
		return null;
		#else
		try {
			switch (PLATFORM) {
				case "windows":
					#if cpp
					return __parseMachineGuid("MachineGuid REG_SZ " + NativeSystem.getDeviceId());
					#else
					// The 64-bit view: a 32-bit process is shown another,
					// which has no MachineGuid.
					return __parseMachineGuid(__programOutput("reg", ["query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid", "/reg:64"]));
					#end
				case "mac":
					return __parseIoregUuid(__programOutput("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]));
				default:
					for (path in ["/etc/machine-id", "/var/lib/dbus/machine-id"]) {
						if (sys.FileSystem.exists(path)) {
							var id:String = StringTools.trim(sys.io.File.getContent(path));

							if (~/^[0-9a-f]{32}$/.match(id)) {
								return id;
							}
						}
					}

					return null;
			}
		} catch (_:Dynamic) {
			return null;
		}
		#end
	}

	/**
		The `MachineGuid` in `reg query`'s output, in capitals and without
		braces, as the native build reads it from the registry; null if
		there is none.
	**/
	@:noCompletion private static function __parseMachineGuid(output:Null<String>):Null<String> {
		if (output == null) {
			return null;
		}

		var guid:EReg = ~/MachineGuid\s+REG_SZ\s+\{?([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\}?/;
		return guid.match(output) ? guid.matched(1).toUpperCase() : null;
	}

	/** The `IOPlatformUUID` in `ioreg`'s output, in capitals; null if there is none. **/
	@:noCompletion private static function __parseIoregUuid(output:Null<String>):Null<String> {
		if (output == null) {
			return null;
		}

		var uuid:EReg = ~/"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"/;
		return uuid.match(output) ? uuid.matched(1).toUpperCase() : null;
	}

	/**
		The machine's physical memory, in bytes.

		Asked of the system directly natively, on the jvm and on Node:
		`GlobalMemoryStatusEx` on Windows, `/proc/meminfo`'s `MemTotal` on
		Linux. On macOS `sysctl hw.memsize` is run. The interpreter, neko and
		HashLink under Windows have no call for it and run `wmic` -- or
		PowerShell, where Windows no longer has wmic -- which takes half a
		second or more.

		@throws IllegalOperationError In a browser, which reports no such
		thing, and on a system none of these answer on. It answered 0 on
		macOS, and on a Windows without wmic.
	**/
	public static function totalSystemMemory():Float {
		#if nodejs
		// Node reports this directly, with no shell involved.
		return js.node.Os.totalmem();
		#elseif (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser reports no physical memory, so System.totalSystemMemory() is not available there.");
		#else
		var bytes:Float = __systemMemory(false);

		if (bytes > 0) {
			return bytes;
		}

		throw new crossbyte.errors.IllegalOperationError('Nothing on $PLATFORM answered how much physical memory there is.');
		#end
	}

	/**
		The physical memory available to start programs without swapping, in
		bytes: Windows' available physical memory, Linux's `MemAvailable`,
		macOS's free, inactive and speculative pages, and on Node
		`os.freemem()`. Asked where `totalSystemMemory()` is, at the same
		cost: on macOS `vm_stat` is run.

		@throws IllegalOperationError As `totalSystemMemory()` does. It
		answered 0 on macOS, and on a Windows without wmic.
	**/
	public static function freeSystemMemory():Float {
		#if nodejs
		// Node reports this directly; the sys path shells out through a Process hxnodejs has no runtime for, so it compiled and then failed with "sys is not defined".
		return js.node.Os.freemem();
		#elseif (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser reports no physical memory, so System.freeSystemMemory() is not available there.");
		#else
		var bytes:Float = __systemMemory(true);

		if (bytes >= 0) {
			return bytes;
		}

		throw new crossbyte.errors.IllegalOperationError('Nothing on $PLATFORM answered how much physical memory is available.');
		#end
	}

	#if !(js && !nodejs)
	/**
		The machine's physical memory in bytes, or what is available of it;
		-1 if nothing answered. Each figure was a process: `wmic`, half a
		second on Windows natively and on the jvm too, and `grep` on Linux;
		macOS had none, and answered 0.
	**/
	@:noCompletion private static function __systemMemory(available:Bool):Float {
		try {
			switch (PLATFORM) {
				case "windows":
					#if cpp
					return crossbyte.io._internal.NativeFileSync.systemMemory(available);
					#else
					#if (jvm || java)
					var bytes:Float = __beanBytes(available ? "getFreePhysicalMemorySize" : "getTotalPhysicalMemorySize");

					if (bytes >= 0) {
						return bytes;
					}
					#end
					return __windowsMemory(available);
					#end
				case "linux":
					return __parseMeminfo(__readProcFile("/proc/meminfo"), available ? "MemAvailable" : "MemTotal");
				case "mac":
					if (available) {
						return __parseVmStat(__programOutput("vm_stat", []));
					}

					var total:Null<Float> = __parseFirstNumber(__programOutput("sysctl", ["-n", "hw.memsize"]));
					return total == null ? -1 : total;
				default:
					return -1;
			}
		} catch (_:Dynamic) {
			return -1;
		}
	}

	/**
		A /proc file's text, read through to its end. Such a file reports a
		size of 0, and hxcpp's getContent reads the size a file reports: it
		answered "" for /proc/meminfo.
	**/
	@:noCompletion private static function __readProcFile(path:String):String {
		var input = sys.io.File.read(path, false);

		try {
			var text:String = input.readAll().toString();
			input.close();
			return text;
		} catch (e:Dynamic) {
			input.close();
			throw e;
		}
	}

	#if (jvm || java)
	/** A figure from the HotSpot OperatingSystemMXBean, or -1 where it has none. **/
	@:noCompletion private static function __beanBytes(getter:String):Float {
		try {
			var bean:Dynamic = java.lang.management.ManagementFactory.getOperatingSystemMXBean();
			var method = java.lang.Class.forName("com.sun.management.OperatingSystemMXBean").getMethod(getter);
			var value:java.lang.Number = cast method.invoke(bean);
			return value.doubleValue();
		} catch (_:Dynamic) {
			return -1;
		}
	}
	#end

	/**
		Windows' figures from wmic, or from PowerShell where Windows no longer
		ships wmic; -1 if neither answers.
	**/
	@:noCompletion private static function __windowsMemory(available:Bool):Float {
		// Total in bytes; free in kilobytes.
		var scale:Float = available ? 1024 : 1;
		var wmic:Null<Float> = __parseFirstNumber(available ? __programOutput("wmic", ["OS", "get", "FreePhysicalMemory"]) : __programOutput("wmic",
			["computersystem", "get", "totalphysicalmemory"]));

		if (wmic != null) {
			return wmic * scale;
		}

		var query:String = available ? "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" : "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory";
		var shell:Null<Float> = __parseFirstNumber(__programOutput("powershell", ["-NoProfile", "-NonInteractive", "-Command", query]));
		return shell == null ? -1 : shell * scale;
	}
	#end

	/** The first line of `output` that is a whole number, or null. **/
	@:noCompletion private static function __parseFirstNumber(output:Null<String>):Null<Float> {
		if (output == null) {
			return null;
		}

		for (line in output.split("\n")) {
			var text:String = StringTools.trim(line);

			if (~/^[0-9]+$/.match(text)) {
				return Std.parseFloat(text);
			}
		}

		return null;
	}

	/** `key`'s figure in /proc/meminfo's text, in bytes, or -1. **/
	@:noCompletion private static function __parseMeminfo(content:String, key:String):Float {
		var line:EReg = new EReg("^" + key + ":\\s*([0-9]+)\\s*kB", "m");
		return line.match(content) ? Std.parseFloat(line.matched(1)) * 1024 : -1;
	}

	/**
		Free, inactive and speculative pages in vm_stat's output, in bytes, or
		-1: what macOS can hand a program without swapping.
	**/
	@:noCompletion private static function __parseVmStat(output:Null<String>):Float {
		if (output == null) {
			return -1;
		}

		var pageSize:EReg = ~/page size of ([0-9]+) bytes/;

		if (!pageSize.match(output)) {
			return -1;
		}

		var pages:Float = 0;

		for (kind in ["free", "inactive", "speculative"]) {
			var line:EReg = new EReg("Pages " + kind + ":\\s*([0-9]+)", "");

			if (!line.match(output)) {
				return -1;
			}

			pages += Std.parseFloat(line.matched(1));
		}

		return pages * Std.parseFloat(pageSize.matched(1));
	}

	/**
		Lets this process run on the processor at `index`, from 0 to
		`processorCount - 1`, or stops it running there.

		Natively on Windows and Linux; see `processAffinity`.

		@return Whether the system accepted the change: it refuses one that
		would leave the process no processor at all.
		@throws RangeError `index` names no processor -- or, on Windows, one
		past the 64 a process's mask can hold.
		@throws IllegalOperationError Anywhere else, as for `processAffinity`.
		It answered `false` there.
	**/
	public static function setProcessAffinity(index:Int, value:Bool):Bool {
		__checkAffinityIndex(index);
		#if cpp
		return NativeSystem.setProcessAffinity(index, value);
		#else
		return false;
		#end
	}

	/**
		Whether this process may run on the processor at `index`, from 0 to
		`processorCount - 1`.

		Natively on Windows and Linux; see `processAffinity`.

		@throws RangeError `index` names no processor -- or, on Windows, one
		past the 64 a process's mask can hold.
		@throws IllegalOperationError Anywhere else, as for `processAffinity`.
		It answered `false` there: no processor usable.
	**/
	public static function hasProcessAffinity(index:Int):Bool {
		__checkAffinityIndex(index);
		#if cpp
		return NativeSystem.hasProcessAffinity(index);
		#else
		return false;
		#end
	}

	/** Refuses a target with no process affinity, then an index out of range. **/
	@:noCompletion private static function __checkAffinityIndex(index:Int):Void {
		__requireAffinity();

		// The native calls shift a bit by it: past the mask, that is
		// undefined behaviour, not an answer.
		var limit:Int = processorCount;
		if (isWindows && limit > 64) {
			limit = 64;
		}

		if (index < 0 || index >= limit) {
			throw new crossbyte.errors.RangeError('Processor $index is not one of this machine\'s $limit.');
		}
	}

	@:noCompletion private static function __requireAffinity():Void {
		#if cpp
		if (PLATFORM == "windows" || PLATFORM == "linux") {
			return;
		}

		throw new crossbyte.errors.IllegalOperationError(PLATFORM == "mac" ? "macOS has no process affinity: no processor can be granted or denied to a process there." : 'Process affinity is not available natively on $PLATFORM; only Windows and Linux have it.');
		#else
		throw new crossbyte.errors.IllegalOperationError('Process affinity is not available on ${__targetName()}: only native builds for Windows and Linux can ask for it or set it.');
		#end
	}

	/** The target, as an error message names it. **/
	@:noCompletion private static function __targetName():String {
		#if cpp
		return "native " + PLATFORM;
		#elseif (jvm || java)
		return "the jvm";
		#elseif nodejs
		return "Node";
		#elseif js
		return "a browser";
		#elseif eval
		return "the interpreter";
		#elseif neko
		return "neko";
		#elseif hl
		return "HashLink";
		#else
		return "this target";
		#end
	}

	@:noCompletion private static function get_appDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__appDirPath == null) {
			__appDirPath = __programDirectory();
		}

		return __appDirPath;
		#end
	}

	#if !(js && !nodejs)
	/**
		The directory of the program's own file, absolute and normalized; on
		the interpreter, the working directory. The working directory was
		used everywhere, and a service started from System32 looked for its
		files there.
	**/
	@:noCompletion private static function __programDirectory():String {
		#if eval
		// Sys.programPath() is the main class's source file here, which is
		// not where the program's files are: those are read from where the
		// compiler ran.
		return Path.removeTrailingSlashes(Sys.getCwd());
		#else
		var program:Null<String> = null;

		try {
			program = Sys.programPath();
		} catch (_:Dynamic) {}

		if (program == null || program == "") {
			return Path.removeTrailingSlashes(Sys.getCwd());
		}

		var windows:Bool = isWindows;
		var parts = crossbyte.io._internal.FilePath.parse(sys.FileSystem.absolutePath(program), windows);
		var segments:Array<String> = crossbyte.io._internal.FilePath.walk([], parts.segments, parts.root != "", 0);
		segments.pop();
		return crossbyte.io._internal.FilePath.join(parts.root, segments, windows);
		#end
	}
	#end

	@:noCompletion private static function get_applicationId():String {
		if (__applicationId == null) {
			var id:Null<String> = crossbyte.io._internal.ApplicationIdentity.defined;

			if (id == null) {
				id = crossbyte.io._internal.ApplicationIdentity.mainClass();
			}

			#if !(js && !nodejs)
			if (id == null) {
				id = __programName();
			}
			#end

			if (id == null || id == "") {
				throw new crossbyte.errors.IllegalOperationError("Nothing names this application: there is no main class and no program file. Build it with -D crossbyte_app_id=<name>.");
			}

			__applicationId = id;
		}

		return __applicationId;
	}

	#if !(js && !nodejs)
	/** The program's file name without its extension, or null. **/
	@:noCompletion private static function __programName():Null<String> {
		try {
			var name:String = Path.withoutExtension(Path.withoutDirectory(Sys.programPath()));
			return name == "" ? null : name;
		} catch (_:Dynamic) {
			return null;
		}
	}
	#end

	@:noCompletion private static function get_appStorageDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		var path:String = __storagePath();

		if (!__appStorageDirMade) {
			// AIR's "created when you first access it", which nothing did:
			// this was the profile root itself, which exists anyway.
			try {
				if (!sys.FileSystem.exists(path)) {
					sys.FileSystem.createDirectory(path);
				}
			} catch (e:Dynamic) {
				throw new crossbyte.errors.IOError('Could not create the application storage directory $path: ${Std.string(e)}');
			}

			__appStorageDirMade = true;
		}

		return path;
		#end
	}

	/**
		The application storage directory's path, worked out once, without
		creating it.

		It was `APPDATA`, or `HOME`, itself: the account's root, shared by
		every CrossByte program on it, so two applications that opened a
		`Store` of the same name opened one store -- where `Store` promised
		each its own. It is the application's own directory inside that now.

		Before that it had been wrong on Node: under Windows the old
		`#if windows` was false there, so it read HOME -- the profile root
		when Git Bash had set it, a different place than a native build used
		for the same data, and the literal string "undefined" when nothing
		had. The platform is asked at run time.
	**/
	@:noCompletion private static function __storagePath():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__appStorageDirPath == null) {
			var base:Null<String> = __storageBase(PLATFORM, Sys.getEnv);

			if (base == null) {
				var wanted:String = isWindows ? "APPDATA or USERPROFILE" : "HOME, or XDG_DATA_HOME";
				throw new crossbyte.errors.IOError('There is no application storage directory: the environment sets neither $wanted.');
			}

			__appStorageDirPath = Path.removeTrailingSlashes(base) + (isWindows ? "\\" : "/") + applicationId;
		}

		return __appStorageDirPath;
		#end
	}

	/**
		Where `platform` keeps applications' data, read from `env`, or null
		when the environment does not say. Separate so that every platform's
		rule is tested on whichever one runs the test.
	**/
	@:noCompletion private static function __storageBase(platform:String, env:String->Null<String>):Null<String> {
		inline function given(name:String):Null<String> {
			var value:Null<String> = env(name);
			return value == null || StringTools.trim(value) == "" ? null : value;
		}

		switch (platform) {
			case "windows":
				var appData:Null<String> = given("APPDATA");
				if (appData != null) {
					return appData;
				}

				var profile:Null<String> = given("USERPROFILE");
				return profile == null ? null : Path.removeTrailingSlashes(profile) + "\\AppData\\Roaming";

			case "mac":
				var home:Null<String> = given("HOME");
				return home == null ? null : Path.removeTrailingSlashes(home) + "/Library/Application Support";

			default:
				// XDG: a relative value is invalid and is to be ignored.
				var data:Null<String> = given("XDG_DATA_HOME");
				if (data != null && StringTools.startsWith(data, "/")) {
					return data;
				}

				var home:Null<String> = given("HOME");
				return home == null ? null : Path.removeTrailingSlashes(home) + "/.local/share";
		}
	}

	/**
		The application storage directory's path, or null where there is
		none, without creating it and without throwing: what
		`File.resolvePath` asks to know where its `..` stops.
	**/
	@:noCompletion private static function __storageRootOrNull():Null<String> {
		#if (js && !nodejs)
		return null;
		#else
		try {
			return __storagePath();
		} catch (_:Dynamic) {
			return null;
		}
		#end
	}

	@:noCompletion private static inline function get_desktopDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__desktopDirPath == null) {
			var configured:Null<String> = __xdgUserDir("XDG_DESKTOP_DIR");
			__desktopDirPath = configured != null ? configured : userDir + File.separator + "Desktop";
		}

		return __desktopDirPath;
		#end
	}

	@:noCompletion private static inline function get_documentsDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__documentsDirPath == null) {
			// xdg-user-dirs, as File.documentsDirectory documents, which was
			// never read: a desktop in another language, or one moved, keeps
			// its documents somewhere other than ~/Documents.
			var configured:Null<String> = __xdgUserDir("XDG_DOCUMENTS_DIR");
			__documentsDirPath = configured != null ? configured : userDir + File.separator + "Documents";
		}

		return __documentsDirPath;
		#end
	}

	#if !(js && !nodejs)
	/**
		`key` from the user's xdg-user-dirs file, on Linux and the BSDs, or
		null: elsewhere, with no such file, or with the key unset.
	**/
	@:noCompletion private static function __xdgUserDir(key:String):Null<String> {
		if (isWindows || PLATFORM == "mac") {
			return null;
		}

		var home:Null<String> = Sys.getEnv("HOME");
		if (home == null || home == "") {
			return null;
		}

		var config:Null<String> = Sys.getEnv("XDG_CONFIG_HOME");
		if (config == null || !StringTools.startsWith(config, "/")) {
			config = Path.removeTrailingSlashes(home) + "/.config";
		}

		try {
			var file:String = config + "/user-dirs.dirs";
			return sys.FileSystem.exists(file) ? __parseUserDirs(sys.io.File.getContent(file), key, home) : null;
		} catch (_:Dynamic) {
			return null;
		}
	}
	#end

	/**
		The directory `key` names in the text of a user-dirs.dirs file, with
		`$HOME` expanded, or null. Lines are `KEY="$HOME/Name"` or
		`KEY="/absolute/path"`, as xdg-user-dirs writes them.
	**/
	@:noCompletion private static function __parseUserDirs(content:String, key:String, home:String):Null<String> {
		for (line in content.split("\n")) {
			var text:String = StringTools.trim(line);

			if (StringTools.startsWith(text, "#") || !StringTools.startsWith(text, key + "=")) {
				continue;
			}

			var value:String = StringTools.trim(text.substr(key.length + 1));

			if (value.length >= 2 && StringTools.startsWith(value, "\"") && StringTools.endsWith(value, "\"")) {
				value = value.substr(1, value.length - 2);
			}

			if (StringTools.startsWith(value, "$HOME")) {
				value = Path.removeTrailingSlashes(home) + value.substr(5);
			}

			if (!StringTools.startsWith(value, "/")) {
				// Neither form the file has: not ours to guess at.
				return null;
			}

			var directory:String = Path.removeTrailingSlashes(value);
			return directory == "" ? "/" : directory;
		}

		return null;
	}

	@:noCompletion private static inline function get_userDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__userDirPath == null) {
			__userDirPath = isWindows ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
		}

		return __userDirPath;
		#end
	}

	@:noCompletion private static function get_processAffinity():Array<Bool> {
		__requireAffinity();
		#if cpp
		return NativeSystem.getProcessAffinity();
		#else
		return null;
		#end
	}

	/**
		Asked of the platform wherever it will say: the native call, the JVM's
		own count, Node's list of CPUs, a browser's `hardwareConcurrency`.
		This returned 0 everywhere but native, so `new TaskPool(processorCount)`
		-- the obvious way to size a pool -- threw on the jvm, Node and the
		interpreter. Where nothing reports it, the environment and
		`/proc/cpuinfo` are asked, and the answer is never below 1: a process
		running this code has at least one processor to run it on.
	**/
	@:noCompletion private static function get_processorCount():Int {
		#if cpp
		var count:Int = NativeSystem.getProcessorCount();
		#elseif (java || jvm)
		var count:Int = java.lang.Runtime.getRuntime().availableProcessors();
		#elseif nodejs
		var count:Int = js.node.Os.cpus().length;
		#elseif js
		var reported:Null<Int> = js.Syntax.code("(typeof navigator !== 'undefined' && navigator.hardwareConcurrency) || 0");
		var count:Int = reported == null ? 0 : reported;
		#else
		if (__probedProcessorCount < 1) {
			__probedProcessorCount = __probeProcessorCount();
		}
		var count:Int = __probedProcessorCount;
		#end
		return count > 0 ? count : 1;
	}

	#if !(cpp || java || jvm || js)
	@:noCompletion private static var __probedProcessorCount:Int = 0;

	// For targets with no call of their own for it: the interpreter, hl and
	// neko. Read once; a count that changes under a running process is rare
	// enough not to be worth a file read per question.
	@:noCompletion private static function __probeProcessorCount():Int {
		// Windows sets this for every process.
		var fromEnvironment:Int = crossbyte.utils.IntParse.decimal(StringTools.trim(Sys.getEnv("NUMBER_OF_PROCESSORS") ?? ""), 65536);
		if (fromEnvironment > 0) {
			return fromEnvironment;
		}

		// Linux lists one "processor" entry per logical processor.
		try {
			if (sys.FileSystem.exists("/proc/cpuinfo")) {
				var count:Int = 0;
				for (line in sys.io.File.getContent("/proc/cpuinfo").split("\n")) {
					if (StringTools.startsWith(line, "processor")) {
						count++;
					}
				}
				if (count > 0) {
					return count;
				}
			}
		} catch (_:Dynamic) {}

		return 1;
	}
	#end
}
