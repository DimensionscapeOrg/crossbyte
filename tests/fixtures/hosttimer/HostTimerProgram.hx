import crossbyte.core.HostApplication;
import crossbyte.utils.GlobalTimer;

/**
	CrossByte hosted by a framework that has its own `haxe.Timer`
	(tests/fixtures/hosttimer/haxe/Timer.hx): HaxeTimerTest builds and runs
	it to see that the host's class is the one in the build, that
	`GlobalTimer` runs on it, and that the runtime's own timers still run on
	the runtime.
**/
class HostTimerProgram extends HostApplication {
	static function main():Void {
		var application = new HostTimerProgram();

		var once = 0;
		var every = 0;
		var cleared = 0;
		var direct = 0;
		var runtime = 0;

		GlobalTimer.setTimeout(0.05, () -> once++);
		var interval = GlobalTimer.setInterval(0.02, () -> every++);
		GlobalTimer.clearTimeout(GlobalTimer.setTimeout(0.05, () -> cleared++));
		var timer = new haxe.Timer(10);
		timer.run = () -> direct++;
		crossbyte.Timer.setTimeout(0.05, () -> runtime++);

		// The host's loop, ten frames of 10 ms: its own timers, then CrossByte's frame.
		for (_ in 0...10) {
			haxe.Timer.pump(10);
			application.advance(0.01, 0);
		}
		timer.stop();
		GlobalTimer.clearInterval(interval);
		haxe.Timer.pump(100);

		Sys.println('once=$once every=$every cleared=$cleared direct=$direct runtime=$runtime stamp=${haxe.Timer.stamp()}');
		Sys.exit(0);
	}

	function new() {
		super();
	}
}
