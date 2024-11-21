package crossbyte.core;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.TickEvent;
import haxe.EntryPoint;
import haxe.Timer;
import sys.thread.EventLoop;

/**
 * ...
 * @author Christopher Speciale
 */
#if (cpp && windows)
@:cppInclude("Windows.h")
@:cppNamespaceCode('#pragma comment(lib, "winmm.lib")')
#end
class CrossByte extends EventDispatcher
{
	public static var current(get, null):CrossByte;
	@:noCompletion private static inline var DEFAULT_TICKS_PER_SECOND:UInt = 12;
	@:noCompletion private static var __current:CrossByte;	
	
	public var tps(get, set):UInt;
	public var cpuLoad(get, null):Float;
	
	@:noCompletion private var __tickInterval:Float;
	@:noCompletion private var __isRunning:Bool = true;
	@:noCompletion private var __tps:UInt;
	@:noCompletion private var __time:Float;
	@:noCompletion private var __timer:Timer;
	@:noCompletion private var __dt:Float = 0.0;
	@:noCompletion private var __cpuTime:Float = 0.0;
	@:noCompletion private var __sleepAccuracy:Float = 0.0;
	
	@:noCompletion private static function get_current():CrossByte
	{
		return __current;
	}
	
	@:noCompletion private function get_tps():UInt
	{
		return __tps;
	}
	
	@:noCompletion private function set_tps(value:UInt):UInt
	{
		__tickInterval = 1 / (__tps = value);
		
		return value;
	}
	
	private function new() 
	{
		super(this);
		
		#if (cpp && windows)
		untyped __cpp__ ("HANDLE hThread = GetCurrentThread();");		
		untyped __cpp__ ("SetThreadPriority(hThread, THREAD_PRIORITY_TIME_CRITICAL);");
		untyped __cpp__ ("timeBeginPeriod(1);");
		
		untyped __cpp__ ("HANDLE hProcess = GetCurrentProcess();");	
		untyped __cpp__ ("SetPriorityClass(hProcess, HIGH_PRIORITY_CLASS)");
		#end
		
		Sys.println("Initializing CrossByte Instance");
		
		__current = this;
		tps = DEFAULT_TICKS_PER_SECOND;		
		
		#if precision_tick
		__getSleepAccuracy();
		#end
		
		EntryPoint.runInMainThread(__runEventLoop);
	}
	
	@:noCompletion private function get_cpuLoad():Float{
		var free:Float = ((__tickInterval - __cpuTime) / __tickInterval) * 100;
		
		return Math.min(Math.floor((100 - free) * 100) / 100, 100);
	}
	
	#if precision_tick
	@:noCompletion private function __getSleepAccuracy():Void{
		var time:Float = Timer.stamp();
		var dtTotal:Float = 0.0;
		
		for (i in 0...100){
			Sys.sleep(0.001);
			dtTotal += (Timer.stamp() - time);
			
			time = Timer.stamp();
		}
		
		__sleepAccuracy = dtTotal / 100;
	}
	#end
	
	@:noCompletion private function __runEventLoop():Void
	{
		while (true)
		{
			var currentTime:Float = Timer.stamp();

			var e:TickEvent = new TickEvent(TickEvent.TICK, __dt);

			dispatchEvent(e);
			__cpuTime = __dt = Timer.stamp() - currentTime;
			#if precision_tick
			var minSleep = 0.001;
			#end
			while (__dt < __tickInterval)
			{
				#if precision_tick
				if (__dt + __sleepAccuracy > __tickInterval){
					minSleep = 0;
				}				
				
				Sys.sleep(minSleep);
				#else
				Sys.sleep(0.001);
				#end
				__dt = Timer.stamp() - currentTime;
				
			}

			__time += __dt;
		}
	}	
}
