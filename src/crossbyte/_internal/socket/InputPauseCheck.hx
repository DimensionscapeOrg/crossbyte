package crossbyte._internal.socket;

/**
	A socket that has stopped reading at its input limit (see
	`crossbyte.net.Socket.maxInputBufferSize`), out of the poll set's reads,
	which its registry asks once a pass whether to read again. Asked by the
	registry rather than from a tick or a pass flush: a tick listener per
	socket costs a copy of the runtime's listeners to add, and a pass flush
	that asks again for the next pass keeps the loop from ever waiting.
**/
@:noCompletion
interface InputPauseCheck {
	/**
		Whether the socket still waits for its application to read: false
		once it reads again, or has closed, and the registry stops asking.
	**/
	function __inputStillPaused():Bool;
}
