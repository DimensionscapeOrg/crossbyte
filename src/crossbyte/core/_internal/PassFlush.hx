package crossbyte.core._internal;

/**
	Something that holds its output until the runtime's loop finishes a
	pass, and sends it then, all at once, rather than a piece at a time as it
	was produced. It asks to be flushed with `CrossByte.__queuePassFlush`,
	once per pass it has something held in.
**/
interface PassFlush {
	/** Sends whatever is held. Called once for each time it asked. **/
	function __flushPass():Void;
}
