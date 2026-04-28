package crossbyte.utils;

/** Abstract priority hints accepted by `CrossByte.setThreadPriority`. */
enum ThreadPriority {
	/** Lowest possible scheduling priority. */
	IDLE;
	/** Lower than `LOW`. */
	LOWEST;
	/** Below normal scheduling priority. */
	LOW;
	/** Default scheduling priority. */
	NORMAL;
	/** Above normal scheduling priority. */
	HIGH;
	/** Higher than `HIGH`. */
	HIGHEST;
	/** Best-effort critical priority. */
	CRITICAL;
}
