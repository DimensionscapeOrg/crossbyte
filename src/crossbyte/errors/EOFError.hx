package crossbyte.errors;

/**
	An EOFError exception is thrown when you attempt to read past the end of
	the available data. For example, an EOFError is thrown when one of the read
	methods in the IDataInput interface is called and there is insufficient
	data to satisfy the read request.
**/
#if !debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class EOFError extends IOError {
	/**
		Creates a new EOFError object.
		@param message A string associated with the error object. Without one,
			   the message is Flash's: "End of file was encountered".
		@param id A reference number to associate with the error. `0`, the
			   default, gives Flash's number for this error, 2030.
	**/
	public function new(message:String = null, id:Int = 0) {
		// Either is kept as given, so a reader's account of what ran out
		// ("Asked for 8 bytes with 3 left in the file") reaches the caller.
		super(message == null || message == "" ? "End of file was encountered" : message);

		name = "EOFError";
		errorID = id != 0 ? id : 2030;
	}
}
