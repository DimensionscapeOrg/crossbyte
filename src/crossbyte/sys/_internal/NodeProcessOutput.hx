package crossbyte.sys._internal;

#if nodejs
import haxe.io.Bytes;
import haxe.io.Error;
import haxe.io.Output;
import js.node.Buffer;
import js.node.stream.Writable.IWritable;

/**
 * A `haxe.io.Output` over a Node writable stream, so that
 * `NativeProcess.standardInput` keeps its type and its meaning on Node.
 *
 * A child's stdin is the one of the three standard streams that survives the
 * move: writing is fire-and-forget, so Node's asynchronous stream sits under a
 * synchronous `Output` without having to pretend. Its stdout and stderr do not,
 * which is why there is no `Input` beside this -- a synchronous read cannot be
 * served by a stream that delivers through callbacks, and `NativeProcess`
 * refuses those accessors on Node rather than inventing one.
 *
 * `write` returning `false` means Node has buffered past its high-water mark
 * and would like the writer to wait for `drain`. There is nothing to do with
 * that here: the data is already accepted and will be sent, and an `Output` has
 * no way to say "later". It costs memory on a child that will not read, which
 * is the same trade a blocking pipe makes by stalling instead.
 */
class NodeProcessOutput extends Output {
	private var __stream:IWritable;

	public function new(stream:IWritable) {
		__stream = stream;
	}

	override public function writeByte(c:Int):Void {
		var buffer = Buffer.alloc(1);
		buffer.writeUInt8(c & 0xFF, 0);
		__stream.write(buffer);
	}

	override public function writeBytes(s:Bytes, pos:Int, len:Int):Int {
		if (s == null) {
			throw Error.Custom("Cannot write null bytes.");
		}

		// Difference, not sum: `pos + len` overflows for a large len.
		if (pos < 0 || len < 0 || pos > s.length || len > s.length - pos) {
			throw Error.OutsideBounds;
		}

		if (len == 0) {
			return 0;
		}

		// Copied rather than viewed. A Buffer over the caller's storage would
		// still be the caller's storage, and Node sends it whenever it gets
		// round to it -- so anything the caller wrote in the meantime would go
		// down the pipe instead of what it asked to send.
		__stream.write(Buffer.from(s.sub(pos, len).getData()));
		return len;
	}

	override public function flush():Void {}

	override public function close():Void {
		// Ends the pipe, which is what the child sees as EOF on stdin.
		__stream.end(null);
	}
}
#end
