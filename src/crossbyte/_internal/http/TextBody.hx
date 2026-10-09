package crossbyte._internal.http;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;

/**
	What text a response sends is encoded into before it is written (a
	String body, `HTTPResponseStream.writeText`), kept a thread at a time.
	Nothing holds it past the write: a writer copies what it is given, and a
	body too large to write at once is copied before it is streamed. A write
	begun while one holds it (a status listener answering another
	connection) is given a buffer of its own, and one grown past 64 KB is
	not kept.
**/
@:noCompletion
class TextBody {
	static inline var KEEP:Int = 64 * 1024;

	#if target.threaded
	static final __spare:sys.thread.Tls<ByteArray> = new sys.thread.Tls();
	#else
	static var __spareOnly:Null<ByteArray> = null;
	#end

	public static function take():ByteArray {
		#if target.threaded
		var spare:Null<ByteArray> = __spare.value;
		__spare.value = null;
		#else
		var spare:Null<ByteArray> = __spareOnly;
		__spareOnly = null;
		#end
		if (spare == null) {
			return new ByteArray();
		}
		spare.length = 0;
		spare.position = 0;
		return spare;
	}

	public static function give(bytes:ByteArray):Void {
		if (@:privateAccess (bytes : ByteArrayData).__length > KEEP) {
			return;
		}
		#if target.threaded
		__spare.value = bytes;
		#else
		__spareOnly = bytes;
		#end
	}
}
