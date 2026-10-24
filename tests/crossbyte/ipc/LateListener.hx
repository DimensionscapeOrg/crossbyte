package crossbyte.ipc;

#if (cpp && (windows || linux || mac || macos))
/**
	A bare native listener on `name`, made `delay` seconds from now on a
	thread of its own and kept until `stop()`: something that starts
	listening only after a connect has begun waiting for it. It takes each
	client (a connect waits for the listener's hello) and reads nothing.
**/
@:access(crossbyte.ipc.LocalConnection)
class LateListener {
	private final __stopping:sys.thread.Lock = new sys.thread.Lock();
	private final __stopped:sys.thread.Lock = new sys.thread.Lock();
	private var __done:Bool = false;

	public static function start(name:String, delay:Float):LateListener {
		return new LateListener(name, delay);
	}

	private function new(name:String, delay:Float) {
		var stopping = __stopping;
		var stopped = __stopped;
		sys.thread.Thread.create(() -> {
			crossbyte.sys.System.sleep(delay);
			var listener = LocalConnection.__listen(name);
			var taken:Array<Dynamic> = [];
			// Bounded, so a case that fails before stop() frees the name.
			var until = haxe.Timer.stamp() + 30;
			while (!stopping.wait(0.002) && haxe.Timer.stamp() < until) {
				if (listener != null) {
					var connection = LocalConnection.__accept(listener);
					if (connection != null) {
						taken.push(connection);
					}
				}
			}
			for (connection in taken) {
				LocalConnection.__close(connection);
			}
			if (listener != null) {
				LocalConnection.__close(listener);
			}
			stopped.release();
		});
	}

	/** Closes the listener, once it has been made. **/
	public function stop():Void {
		if (__done) {
			return;
		}
		__done = true;
		__stopping.release();
		__stopped.wait(30);
	}
}
#end
