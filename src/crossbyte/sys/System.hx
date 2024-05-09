package crossbyte.sys;
import cpp.vm.Gc;
import crossbyte.core.CrossByte;
import sys.io.Process;

/**
 * ...
 * @author Christopher Speciale
 */
class System
{
	public static inline var PLATFORM:String =
		#if windows
		"windows";
		#end

	public static inline function setTicksPerSecond(value:Int):Void
	{
		CrossByte.current.tps = value;
	}

	public static inline function getTicksPerSecond():Int
	{
		return CrossByte.current.tps;
	}

	public static inline function cpuLoad():Float
	{
		return CrossByte.current.cpuLoad;
	}

	public static inline function memoryUsage():Int
	{
		return Gc.memInfo(Gc.MEM_INFO_CURRENT);
	}

	public static inline function totalSystemMemory():Float
	{
		var cmd:String;
		#if windows
		cmd = "wmic computersystem get totalphysicalmemory";
		#end
		var process:Process = new Process(cmd);
		var output:String = process.stdout.readAll().toString();
		process.close();

		if (process.exitCode() > 0)
		{
			return 0;
		}

		var lines = output.split("\n");
		return Std.parseFloat(lines[1]);
	}

	public static inline function freeSystemMemory():Float
	{
		var cmd: String;
		#if windows
		cmd = "wmic OS get FreePhysicalMemory";
		#end
		var process: Process = new Process(cmd);
		var output: String = process.stdout.readAll().toString();
		process.close();

		if (process.exitCode() > 0)
		{
			return 0;
		}

		var lines = output.split("\n");
		var availableMemory: Float = Std.parseFloat(lines[1]);

		// Convert available memory to bytes (assuming the value is in kilobytes)
		availableMemory *= 1024;

		return availableMemory;

	}

}