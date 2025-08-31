package crossbyte.utils;

import sys.thread.Thread;

class ThreadUtil {
	private static final primordialThread:Thread = Thread.current();

	public static var isPrimordial(get, never):Bool;

	private static inline function get_isPrimordial():Bool {
		return Thread.current() == primordialThread;
	}
}
