package crossbyte.utils;

import crossbyte.core.CrossByte;
import sys.thread.Thread;

@:access(crossbyte.core.CrossByte)
class ThreadUtil {
	public static var isPrimordial(get, never):Bool;

	private static inline function get_isPrimordial():Bool {
		#if cpp
		return CrossByte.__primordialThread != null && Thread.current() == CrossByte.__primordialThread;
		#else
		return CrossByte.__primordial != null && CrossByte.current() == CrossByte.__primordial;
		#end
	}
}
