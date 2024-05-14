package crossbyte.sys;
import cpp.vm.Gc;
import crossbyte.core.CrossByte;
import crossbyte._internal.native.sys.NativeSystem;
import sys.io.Process;

/**
 * ...
 * @author Christopher Speciale
 */
@:access(crossbyte._internal.native.sys.NativeSystem)
class System
{
	public static inline var PLATFORM:String =
		#if windows
		"windows";
		#end
		
	/**
	 * Returns an array of Bool representing a full list of processors that are accessible to the process.
	 */
	public static var processAffinity(get, never):Array<Bool>;
	
	/**
	 * Returns the number of processors, including logical processors, that are available to the system.
	 */
	public static var processorCount(get, never):Int;
	
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
	
	/**
	 * Sets the affinity of a specific processor by it's index from 0 to processorCount
	 * 
	 * Returns false if polling fails to retrieve a value
	 */
	public static inline function setProcessAffinity(index:Int, value:Bool):Bool{
		return NativeSystem.setProcessAffinity(index, value);
	}
	
	/**
	 * Returns an a Boolean that reflects whether or not the processor at the supplied index is accessible to the process.
	 */
	public static inline function hasProcessAffinity(index:Int):Bool{
		return NativeSystem.hasProcessAffinity(index);
	}
	
	private static inline function get_processAffinity():Array<Bool>{
		return NativeSystem.getProcessAffinity();
	}
	
	private static inline function get_processorCount():Int{
		return NativeSystem.getProcessorCount();
	}	

}