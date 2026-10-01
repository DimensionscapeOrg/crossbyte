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
	 * Returns an array of Bool representing a full list of processors that are accessible to the process.
	 */
	public static var processAffinity(get, never):Array<Bool>;

	/**
	 * Returns the number of processors, including logical processors, that are available to the system.
	 */
	public static var processorCount(get, never):Int;

	/* public static inline function setTicksPerSecond(value:Int):Void
		{
			CrossByte.current.tps = value;
		}

		public static inline function getTicksPerSecond():Int
		{
			return CrossByte.current.tps;
	}*/
	public static inline function getDeviceId():String {
		#if cpp
		return NativeSystem.getDeviceId();
		#else
		//no-op for now
		return "";
		#end
	}

	public static inline function currentThreadCpuUsage():Float {
		return CrossByte.current().cpuLoad;
	}

	public static inline function totalCpuUsage():Float {
		return 0.0;
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

	public static inline function totalSystemMemory():Float {
		#if nodejs
		// Node reports this directly, with no shell involved.
		return js.node.Os.totalmem();
		#elseif (js && !nodejs)
		// Reading physical memory means shelling out, and a browser has no shell nor any web API that reports it. Returning 0 would read as "no memory" rather than "cannot know".
		throw new crossbyte.errors.IllegalOperationError("System.totalSystemMemory() is not available on this target.");
		#else
		var cmd:String = switch (PLATFORM) {
			case "windows": "wmic computersystem get totalphysicalmemory";
			case "linux": "grep MemTotal /proc/meminfo";
			// No command for this platform. Returned an empty string to
			// Process before, which is a spawn failure rather than an answer.
			default: "";
		};

		if (cmd == "") {
			return 0;
		}

		var process:Process = new Process(cmd);
		var output:String = process.stdout.readAll().toString();

		// Before close(), not after: a closed process raises `process_exit`
		// when asked for its exit code on eval.
		var status:Int = process.exitCode();
		process.close();

		if (status > 0) {
			return 0;
		}

		var lines = output.split("\n");

		if (isWindows) {
			return Std.parseFloat(lines[1]);
		}

		// On Linux the total is on the first line, in kB.
		var parts = lines[0].split(":");

		if (parts.length != 2) {
			return 0;
		}

		return Std.parseFloat(StringTools.trim(parts[1])) * 1024;
		#end
	}

	public static inline function freeSystemMemory():Float {
		#if nodejs
		// Node reports this directly; the sys path shells out through a Process hxnodejs has no runtime for, so it compiled and then failed with "sys is not defined".
		return js.node.Os.freemem();
		#elseif (js && !nodejs)
		// Same as totalSystemMemory: no shell, and no browser equivalent.
		throw new crossbyte.errors.IllegalOperationError("System.freeSystemMemory() is not available on this target.");
		#else
		var cmd:String = switch (PLATFORM) {
			case "windows": "wmic OS get FreePhysicalMemory";
			case "linux": "grep MemAvailable /proc/meminfo";
			default: "";
		};

		if (cmd == "") {
			return 0;
		}

		var process:Process = new Process(cmd);
		var output:String = process.stdout.readAll().toString();
		var status:Int = process.exitCode();
		process.close();

		if (status > 0) {
			return 0;
		}

		var lines = output.split("\n");

		// Both report kB; both are returned as bytes.
		if (isWindows) {
			return Std.parseFloat(lines[1]) * 1024;
		}

		var parts = lines[0].split(":");

		if (parts.length != 2) {
			return 0;
		}

		return Std.parseFloat(StringTools.trim(parts[1])) * 1024;
		#end
	}

	/**
	 * Sets the affinity of a specific processor by it's index from 0 to processorCount
	 * 
	 * Returns false if polling fails to retrieve a value
	 */
	public static inline function setProcessAffinity(index:Int, value:Bool):Bool {
		#if cpp
		return NativeSystem.setProcessAffinity(index, value);
		#else
		// no-op for now
		return false;
		#end
	}

	/**
	 * Returns an a Boolean that reflects whether or not the processor at the supplied index is accessible to the process.
	 */
	public static inline function hasProcessAffinity(index:Int):Bool {
		#if cpp
		return NativeSystem.hasProcessAffinity(index);
		#else 
		//no-op for now
		return false;
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

	@:noCompletion private static inline function get_processAffinity():Array<Bool> {
		#if cpp
		return NativeSystem.getProcessAffinity();
		#else
		// no op for now
		return [false];
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
