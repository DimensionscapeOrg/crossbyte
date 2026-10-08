package crossbyte.utils;

import crossbyte.core.CrossByte;
#if target.threaded
import sys.thread.Thread;
#end

@:access(crossbyte.core.CrossByte)
/** Thread-related helpers for interrogating the active CrossByte runtime. */
class ThreadUtil {
	/**
		`true` when called from the primordial/runtime-owning thread.

		Decided by the thread itself on every threaded target, rather than
		asked of the runtime, which off native answers the primordial one on
		every thread.
	**/
	public static var isPrimordial(get, never):Bool;

	private static inline function get_isPrimordial():Bool {
		#if target.threaded
		var primordialThread:Thread = CrossByte.__primordialThread;
		return primordialThread != null && Thread.current() == primordialThread;
		#else
		// One thread, so the runtime that exists is the primordial one.
		return CrossByte.__primordial != null;
		#end
	}
}
