package crossbyte._internal.socket;

/**
	What a connection a server counted against its `maxConnections` tells as
	it closes, so the count is let go of whichever way the connection ends.
	A `ServerSocket` in practice; an interface so `Socket`, which a page
	builds too, need not name it.
**/
@:noCompletion
interface OpenCounter {
	/** A connection this counted has closed. **/
	function __releaseOpen():Void;
}
