package crossbyte._internal.http.h2;

/**
 * Frame flags. The same bit means different things on different frame types,
 * which is why these are named per type rather than as one set: `0x1` is
 * END_STREAM on DATA and HEADERS but ACK on SETTINGS and PING.
 */
class H2Flags {
	public static inline var END_STREAM:Int = 0x1;
	public static inline var ACK:Int = 0x1;
	public static inline var END_HEADERS:Int = 0x4;
	public static inline var PADDED:Int = 0x8;
	public static inline var PRIORITY:Int = 0x20;
}
