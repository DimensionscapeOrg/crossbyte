package crossbyte.sys;

import crossbyte.io.File;
import haxe.io.Path;

#if cpp
import cpp.vm.Gc;
import crossbyte._internal.native.sys.NativeSystem;
#end

import crossbyte.core.CrossByte;
import sys.io.Process;

/**
 * ...
 * @author Christopher Speciale
 */
 #if cpp
#if windows
@:access(crossbyte._internal.native.sys.win.WinNativeSystem)
#elseif linux
@:access(crossbyte._internal.native.sys.linux.LinuxNativeSystem)
#else
@:access(crossbyte._internal.native.sys.NativeSystem)
#end
#end
class System {
	public static inline var PLATFORM:String =
		#if windows
		"windows";
		#elseif linux
		"linux";
		#else
		"undefined";
		#end

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
		var cmd:String = "";
		#if windows
		cmd = "wmic computersystem get totalphysicalmemory";
		#elseif linux
		cmd = "grep MemTotal /proc/meminfo";
		#end
		var process:Process = new Process(cmd);
		var output:String = process.stdout.readAll().toString();
		process.close();

		if (process.exitCode() > 0) {
			return 0;
		}

		var lines = output.split("\n");
		#if windows
		return Std.parseFloat(lines[1]);
		#elseif linux
		var memLine = lines[0]; // On Linux, the total memory info is in the first line
		var parts = memLine.split(":");
		if (parts.length != 2) {
			return 0;
		}

		// Extract memory size in kB and convert to bytes
		var memoryInKB = Std.parseFloat(StringTools.trim(parts[1]));
		var memoryInBytes = memoryInKB * 1024;

		return memoryInBytes;
		#end
		return 0;
	}

	public static inline function freeSystemMemory():Float {
		var cmd:String = "";
		#if windows
		cmd = "wmic OS get FreePhysicalMemory";
		#elseif linux
		cmd = "grep MemAvailable /proc/meminfo";
		#end
		var process:Process = new Process(cmd);
		var output:String = process.stdout.readAll().toString();
		process.close();

		if (process.exitCode() > 0) {
			return 0;
		}

		var lines = output.split("\n");

		#if windows
		var availableMemory:Float = Std.parseFloat(lines[1]);

		availableMemory *= 1024;

		return availableMemory;
		#elseif linux
		var memLine = lines[0];
		var parts = memLine.split(":");

		if (parts.length != 2) {
			return 0;
		}

		var availableMemoryInKB = Std.parseFloat(StringTools.trim(parts[1]));
		var availableMemoryInBytes = availableMemoryInKB * 1024;

		return availableMemoryInBytes;
		#end

		return 0;
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
		if (__appDirPath == null) {
			__appDirPath = Path.removeTrailingSlashes(Sys.getCwd());
		}

		return __appDirPath;
	}

	@:noCompletion private static inline function get_appStorageDir():String {
		if (__appStorageDirPath == null) {
			#if windows
			__appStorageDirPath = Sys.getEnv("APPDATA");
			#else
			__appStorageDirPath = Sys.getEnv("HOME");
			#end
		}

		return __appStorageDirPath;
	}

	@:noCompletion private static inline function get_desktopDir():String {
		if (__desktopDirPath == null) {
			__documentsDirPath = userDir + File.separator + "Desktop";
		}

		return __desktopDirPath;
	}

	@:noCompletion private static inline function get_documentsDir():String {
		if (__documentsDirPath == null) {
			__documentsDirPath = userDir + File.separator + "Documents";
		}

		return __documentsDirPath;
	}

	@:noCompletion private static inline function get_userDir():String {
		if (__userDirPath == null) {
			#if windows
			__userDirPath = Sys.getEnv("USERPROFILE");
			#else
			__userDirPath = Sys.getEnv("HOME");
			#end
		}

		return __userDirPath;
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
