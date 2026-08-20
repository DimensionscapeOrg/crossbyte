package crossbyte.utils;

import crossbyte.core.CrossByte;
#if !js
import sys.thread.Thread;
#end

@:access(crossbyte.core.CrossByte)
/** Thread-related helpers for interrogating the active CrossByte runtime. */
class ThreadUtil {
	/** `true` when called from the primordial/runtime-owning thread. */
	public static var isPrimordial(get, never):Bool;

	private static inline function get_isPrimordial():Bool {
		#if (js && !nodejs)
		// One thread, so the runtime that exists is the primordial one.
		return CrossByte.__primordial != null;
		#elseif cpp
		return CrossByte.__primordialThread != null && Thread.current() == CrossByte.__primordialThread;
		#else
		return CrossByte.__primordial != null && CrossByte.current() == CrossByte.__primordial;
		#end
	}
}
