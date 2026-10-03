package crossbyte._internal.deflatex;

#if ((java || jvm) && !macro)
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;

/**
	`Inflater.inflate` on the jvm, through `java.util.zip.Inflater`, the
	JDK's zlib, where the Haxe `InflateImpl` built its tables and a 64 KB
	window as objects for every call.
**/
@:noCompletion
class JvmZlib {
	/**
		The raw DEFLATE, or zlib stream, `input` is at, never more than
		`maxOutputSize` bytes of it (`0` for no limit), `input` left just past
		the stream.
	**/
	public static function inflate(input:BytesInput, zlib:Bool, maxOutputSize:Int, format:String):Bytes {
		var data:haxe.io.BytesData = @:privateAccess input.b;
		var start:Int = @:privateAccess input.pos;
		var available:Int = @:privateAccess input.len;

		if (available <= 0) {
			throw new IOError("Invalid " + format + " data: the stream ends early");
		}

		var inflater:JavaInflater = new JavaInflater(!zlib);
		var size:Int = available * 4 + 256;
		var chunk:Bytes = Bytes.alloc(size > 65536 ? 65536 : size);
		var output:BytesBuffer = new BytesBuffer();
		var produced:Int = 0;

		try {
			inflater.setInput(data, start, available);

			while (!inflater.finished()) {
				var count:Int = inflater.inflate(chunk.getData(), 0, chunk.length);

				if (count > 0) {
					produced += count;

					if (maxOutputSize > 0 && produced > maxOutputSize) {
						throw new RangeError("Inflated stream exceeded " + maxOutputSize + " bytes");
					}

					output.addBytes(chunk, 0, count);
				} else if (inflater.finished()) {
					// An empty stream ends on a call that writes nothing.
					break;
				} else if (inflater.needsInput()) {
					throw new IOError("Invalid " + format + " data: the stream ends early");
				} else if (inflater.needsDictionary()) {
					throw new IOError("Invalid " + format + " data: a preset dictionary is needed");
				}
			}
		} catch (e:DataFormatException) {
			inflater.end();
			throw new IOError("Invalid " + format + " data: " + e.getMessage());
		} catch (e:Dynamic) {
			inflater.end();
			throw e;
		}

		var consumed:Int = available - inflater.getRemaining();
		inflater.end();

		@:privateAccess {
			input.pos += consumed;
			input.len -= consumed;
		}

		return output.getBytes();
	}
}

@:native("java.util.zip.Inflater")
private extern class JavaInflater {
	function new(nowrap:Bool):Void;
	function setInput(input:haxe.io.BytesData, offset:Int, length:Int):Void;
	function inflate(output:haxe.io.BytesData, offset:Int, length:Int):Int;
	function finished():Bool;
	function needsInput():Bool;
	function needsDictionary():Bool;
	function getRemaining():Int;
	function end():Void;
}

@:native("java.util.zip.DataFormatException")
private extern class DataFormatException extends java.lang.Exception {}
#end
