package crossbyte._internal.brotli.codec.decode.streams;
import haxe.ds.Vector;

/**
 * ...
 * @author 
 */
class BrotliMemOutput
{

	public var buffer:Array<UInt>;

	// Bytes this may accumulate, or 0 for no limit. The C this was ported
	// from carried a length here and the port commented the check out, which
	// left a decoder that expands as far as its input asks it to.
	public var limit:UInt;
    //public var length:UInt;
    public var pos:UInt;
	public function new() 
	{
		
	}
	
}
