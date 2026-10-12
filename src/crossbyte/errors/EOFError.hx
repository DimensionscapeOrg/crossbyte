package crossbyte.errors;

/**
	A read past the end of the data there is: a `ByteArray`, a `FileStream`
	or a socket's input asked for more bytes than it holds.
**/
#if !debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class EOFError extends IOError {
	/**
		@param message What ran out. Without one, the message is "End of file
			   was encountered".
		@param id The error's number, 0 unless given; see `Error.errorId`.
	**/
	public function new(message:String = null, id:Int = 0) {
		// Either is kept as given, so a reader's account of what ran out
		// ("Asked for 8 bytes with 3 left in the file") reaches the caller.
		super(message == null || message == "" ? "End of file was encountered" : message);

		name = "EOFError";
		errorId = id;
	}
}
