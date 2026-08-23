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
		is a question about the compiler rather than about the machine. Haxe
		sets `windows` for cpp, hl and neko; it does not set it for eval, the
		JVM or Node. So three of CrossByte's targets reported `"undefined"`
		while running on Windows, and every conditional in this class that
		followed the same pattern took the branch written for somebody else.
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

	public static var appDir(get, never):String;

	public static var appStorageDir(get, never):String;

	public static var documentsDir(get, never):String;

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

	public static inline function memoryUsage():Int {
		#if cpp
		return Gc.memInfo(Gc.MEM_INFO_CURRENT);
		#else
		// no-op for now
		return 0;
		#end
	}

	private static inline var APPLICATION_DIR:String = "Crossbyte";
	@:noCompletion private static var __appDirPath:String;
	@:noCompletion private static var __appStorageDirPath:String;
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

	@:noCompletion private static inline function get_appDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__appDirPath == null) {
			__appDirPath = Path.removeTrailingSlashes(Sys.getCwd());
		}

		return __appDirPath;
		#end
	}

	@:noCompletion private static inline function get_appStorageDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__appStorageDirPath == null) {
			// This decides where `Store` keeps its files, so getting it wrong
			// is not cosmetic: on Node under Windows the old `#if windows`
			// was false, so it read HOME. With HOME set -- Git Bash sets it --
			// that is the profile root rather than AppData, so a store written
			// by a native build was invisible to a Node one on the same
			// machine. With HOME unset, which is the normal state for a
			// Windows service, `getEnv` returns null and the path became the
			// literal string "undefined", relative to the working directory.
			__appStorageDirPath = isWindows ? Sys.getEnv("APPDATA") : Sys.getEnv("HOME");
		}

		return __appStorageDirPath;
		#end
	}

	@:noCompletion private static inline function get_desktopDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__desktopDirPath == null) {
			__desktopDirPath = userDir + File.separator + "Desktop";
		}

		return __desktopDirPath;
		#end
	}

	@:noCompletion private static inline function get_documentsDir():String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no working directory and no environment, so there is no such path to report.");
		#else
		if (__documentsDirPath == null) {
			__documentsDirPath = userDir + File.separator + "Documents";
		}

		return __documentsDirPath;
		#end
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

	@:noCompletion private static inline function get_processorCount():Int {
		#if cpp
		return NativeSystem.getProcessorCount();
		#else
		return 0;
		#end
	}
}
