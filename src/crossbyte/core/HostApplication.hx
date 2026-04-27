package crossbyte.core;

/**
 * A main-thread primordial CrossByte application that is driven by an
 * external host framework rather than by CrossByte's own internal loop.
 *
 * `HostApplication` is the canonical way to embed CrossByte into another
 * application framework that already owns the main thread and frame/update
 * cycle, such as a UI toolkit, game framework, or editor shell.
 *
 * Unlike `Application` and `ServerApplication`, this class does not allow
 * CrossByte to take ownership of the host's outer event loop. Instead, the
 * host framework is expected to call `advance()` regularly, usually once per
 * frame or update tick, to progress CrossByte timers, events, and socket work.
 *
 * Typical usage:
 *
 * ```haxe
 * class Main extends HostApplication {
 *     public function new() {
 *         super();
 *     }
 *
 *     public function onHostFrame(delta:Float):Void {
 *         advance(delta);
 *     }
 * }
 * ```
 *
 * Use this class when:
 * - another framework already owns the process main thread
 * - you still want CrossByte to be the primordial application context
 * - CrossByte should advance in lockstep with the host app's update loop
 *
 * Use `ServerApplication` instead when CrossByte should own a dedicated
 * poll-based server loop directly.
 */
class HostApplication extends Application {
	/**
	 * Creates the primordial CrossByte application in host-driven mode.
	 *
	 * This constructor must still be called on the process main thread, just
	 * like other primordial CrossByte application types.
	 */
	private function new():Void {
		super(DEFAULT, true);
	}

	/**
	 * Advances the embedded CrossByte runtime by one host-driven step.
	 *
	 * This should usually be called once per host update/frame using the host
	 * framework's delta time in seconds.
	 *
	 * During each call, CrossByte:
	 * - advances its thread-local timer scheduler
	 * - dispatches a `TickEvent`
	 * - processes socket work using the supplied polling budget
	 *
	 * @param delta The elapsed time in seconds since the previous host update.
	 * @param socketTimeout The maximum socket polling budget for this step, in seconds.
	 */
	public inline function advance(delta:Float, socketTimeout:Float = 0.0):Void {
		if (crossByte != null) {
			crossByte.pump(delta, socketTimeout);
		}
	}
}
