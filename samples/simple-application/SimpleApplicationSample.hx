import crossbyte.core.Application;
import crossbyte.events.Event;
import crossbyte.events.TickEvent;

class SimpleApplicationSample extends Application {
	private var ticks:Int = 0;

	public static function main():Void {
		new SimpleApplicationSample();
	}

	public function new() {
		super();
		addEventListener(Event.INIT, __handleInit);
		addEventListener(Event.EXIT, __handleExit);
	}

	private function __handleInit(_event:Event):Void {
		Sys.println("SimpleApplication init");
		crossByte.addEventListener(TickEvent.TICK, __handleTick);
	}

	private function __handleTick(event:TickEvent):Void {
		ticks++;
		Sys.println('tick #$ticks delta=${event.delta}');
		if (ticks >= 3) {
			crossByte.removeEventListener(TickEvent.TICK, __handleTick);
			shutdown();
		}
	}

	private function __handleExit(_event:Event):Void {
		Sys.println("SimpleApplication exit");
	}
}
