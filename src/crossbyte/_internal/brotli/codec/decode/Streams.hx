package crossbyte._internal.brotli.codec.decode;
import crossbyte._internal.brotli.codec.DefaultFunctions;
import crossbyte._internal.brotli.codec.decode.streams.BrotliInput;
import crossbyte._internal.brotli.codec.decode.streams.BrotliMemInput;
import crossbyte._internal.brotli.codec.decode.streams.BrotliMemOutput;
import crossbyte._internal.brotli.codec.decode.streams.BrotliOutput;
import haxe.ds.Vector;
import haxe.io.Bytes;
import streams.*;
#if !(js && !nodejs)
import sys.io.FileInput;
import sys.io.FileOutput;
#end

/**
 * ...
 * @author 
 */
class Streams
{
//h
//38
/* Reads len bytes into buf, using the in callback. */
	static public function BrotliRead(input:BrotliInput, buf:Vector<UInt>, buf_off:Int, len:Int):Int {
	  return input.cb_(input.data_, buf, buf_off, len);
	}

//53
/* Writes len bytes into buf, using the out callback. */
	static public function BrotliWrite(out:BrotliOutput,
                                     buf:Vector<UInt>, buf_off:Int, len:Int):Int {
	return out.cb_(out.data_, buf, buf_off, len);
	}
static public function BrotliMemInputFunction(data, buf:Vector<UInt>, buf_off:Int, count:Int):Int {//void* 
  var input:BrotliMemInput = data;//*(BrotliMemInput*)
  if (input.pos > input.length) {
    return -1;
  }
  if (input.pos + count > input.length) {
    count = input.length - input.pos;
  }
  DefaultFunctions.memcpyVectorArray(buf, buf_off, input.buffer, 0 + input.pos, count);
  input.pos += count;
  return count;
}

static public function BrotliInitMemInput(buffer:Array<UInt>, length:Int):BrotliInput {
  var input:BrotliInput = new BrotliInput();
  var mem_input:BrotliMemInput = new BrotliMemInput();
  mem_input.buffer = buffer;
  mem_input.length = length;
  mem_input.pos = 0;
  input.cb_ = BrotliMemInputFunction;//&
  input.data_ = mem_input;
  return input;
}

static public function BrotliMemOutputFunction(data, buf:Vector<UInt>, buf_off:Int, count:Int):Int {
  var output:BrotliMemOutput = data;
  // Every decoded byte arrives here, so this is where a ceiling costs one
  // comparison and stops the expansion rather than measuring it afterwards.
  // Written as a difference because pos is already inside the buffer and
  // the sum would not be.
  if (output.limit > 0 && count > output.limit - output.pos) {
    // An exception rather than a string: a caller that throws the coding
    // token itself to mean "cannot decode this" would otherwise read a
    // size failure as an unrecognised coding.
    throw new haxe.Exception("Brotli stream exceeded " + output.limit + " bytes");
  }
  DefaultFunctions.memcpyArrayVector(output.buffer, 0 + output.pos, buf, buf_off, count);
  output.pos += count;
  return count;
}

static public function BrotliInitMemOutput(buffer:Array<UInt>, limit:UInt = 0):BrotliOutput {
  var output:BrotliOutput=new BrotliOutput();
  var mem_output:BrotliMemOutput=new BrotliMemOutput();
  mem_output.buffer = buffer;
  mem_output.limit = limit;
  mem_output.pos = 0;
  output.cb_ = BrotliMemOutputFunction;//&
  output.data_ = mem_output;
  return output;
}
#if (js && !nodejs)
#else
static public function BrotliFileInputFunction(data:FileInput, buf:Vector<UInt>, buf_off:Int, count:Int):Int {
	var bytes:Bytes = Bytes.alloc(count);
	var size:Int=data.readBytes(bytes,0,count);
	for (i in 0...size)
	buf[buf_off+i] = bytes.get(i);
  return size;
}

static public function BrotliFileInput(f):BrotliInput {
  var input:BrotliInput=new BrotliInput();
  input.cb_ = BrotliFileInputFunction;
  input.data_ = f;
  return input;
}

static public function BrotliFileOutputFunction(data:FileOutput, buf:Vector<UInt>, buf_off:Int, count:Int):Int {
	var bytes:Bytes = Bytes.alloc(count);
	for (i in 0...count)
	bytes.set(i,buf[i]);
	data.write(bytes);
  return bytes.length;
}

static public function BrotliFileOutput(f):BrotliOutput {
  var out:BrotliOutput=new BrotliOutput();
  out.cb_ = BrotliFileOutputFunction;
  out.data_ = f;
  return out;
}
#end

	public function new() 
	{
		
	}
	
}
