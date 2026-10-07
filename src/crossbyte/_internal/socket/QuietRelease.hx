package crossbyte._internal.socket;

/**
	A socket holding buffer storage from its traffic, which its registry asks
	every few seconds whether it has been quiet since it was last asked; one
	that has lets go of what it holds. See `crossbyte.net.Socket`'s buffers.
**/
@:noCompletion
interface QuietRelease {
	/**
		Asked once a sweep: lets go of the storage of a socket that has read
		and written nothing since the sweep before. Whether to go on asking,
		false once it holds nothing more, or has closed.
	**/
	function __releaseIfQuiet():Bool;
}
