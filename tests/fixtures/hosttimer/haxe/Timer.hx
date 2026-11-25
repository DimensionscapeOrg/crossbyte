package haxe;

/**
	A host's own `haxe.Timer`, standing in for the one Lime's native backend
	has: the host's loop runs the timers (`pump` here, where Lime's reads the
	class's private fields), so CrossByte must leave the class in place and
	keep to its public members. HaxeTimerTest builds this folder with it
	ahead of CrossByte's source on the class path, as a Lime project has
	Lime's.
**/
class Timer {
	/** The host's clock, in milliseconds, which only the host moves. **/
	public static var now:Float = 0;

	static var running:Array<Timer> = [];

	var interval:Float;
	var due:Float;

	// A Float, as Lime's takes; the standard library's takes an Int.
	public function new(time:Float) {
		interval = time;
		due = now + time;
		running.push(this);
	}

	public dynamic function run():Void {}

	public function stop():Void {
		running.remove(this);
	}

	public static function delay(f:Void->Void, time:Int):Timer {
		var timer = new Timer(time);
		timer.run = function() {
			timer.stop();
			f();
		};
		return timer;
	}

	public static function measure<T>(f:Void->T, ?pos:haxe.PosInfos):T {
		return f();
	}

	public static function stamp():Float {
		return now / 1000;
	}

	/** A frame of the host's loop, `ms` later: every timer due by then runs. **/
	public static function pump(ms:Float):Void {
		now += ms;
		for (timer in running.copy()) {
			if (running.indexOf(timer) >= 0 && now >= timer.due) {
				timer.due += timer.interval;
				timer.run();
			}
		}
	}
}
