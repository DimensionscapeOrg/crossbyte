package crossbyte._internal.socket.poll;

// Not built for JavaScript: there is one thread there, so nothing needs to end
// a wait from another, and no socket set is polled to end it in.
#if !js
import crossbyte._internal.socket.IPollableSocket;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;

/**
	A loopback connection whose reading end sits in a runtime's poll set, so
	that another thread can end a wait in poll by writing a byte to the other.

	A runtime's POLL loop spends each frame blocked in poll, which a
	descriptor becoming ready ends and nothing else does. Work handed over
	from another thread -- an RPC answer finished on a worker, a query result,
	a task's completion -- used to wait out the rest of the frame there: 38ms
	on average at the default twelve ticks a second, and up to a whole frame.
	Writing here makes the poll return at once, and the runtime runs what it
	was handed.

	A connected TCP pair rather than a datagram sent to itself: an idle UDP
	socket in a Windows poll set is what once made poll return immediately,
	over and over, which is the one thing this must not do.
**/
@:noCompletion
final class WakeSocket implements IPollableSocket {
	/** The end the registry polls. **/
	public var reader(default, null):Socket;

	@:noCompletion private var __writer:Socket;
	@:noCompletion private var __onWake:Void->Void;
	@:noCompletion private var __drain:Bytes;
	@:noCompletion private var __closed:Bool = false;
	#if target.threaded
	// Held while the writing end is written to or closed. Another thread
	// wakes the runtime -- a post, an exit, a parent exiting its children --
	// while the runtime's own thread may be closing the pair as it exits, and
	// the write then went to a descriptor already closed: on the interpreter
	// an error no catch sees, which ended the process, and natively a
	// descriptor the system may have handed to another socket by then.
	// Taken once per wake, when a runtime's queue goes from empty to not.
	@:noCompletion private final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	public var registryClosed(get, never):Bool;

	/**
		Makes the pair, or answers null when this process cannot open a
		loopback connection; the runtime then wakes as it did before, at the
		end of the frame.
	**/
	public static function create(?onWake:Void->Void):Null<WakeSocket> {
		var listener:Socket = null;
		var writer:Socket = null;
		var reader:Socket = null;

		try {
			listener = new Socket();
			listener.bind(new Host("127.0.0.1"), 0);
			listener.listen(1);

			writer = new Socket();
			writer.connect(new Host("127.0.0.1"), listener.host().port);
			reader = listener.accept();
			listener.close();
			listener = null;

			// One byte at a time, so the write goes at once rather than
			// waiting to be coalesced with a next one that may never come.
			writer.setFastSend(true);
			reader.setBlocking(false);
			writer.setBlocking(false);
		} catch (_:Dynamic) {
			for (socket in [listener, writer, reader]) {
				if (socket != null) {
					try {
						socket.close();
					} catch (_:Dynamic) {}
				}
			}
			return null;
		}

		return new WakeSocket(reader, writer, onWake);
	}

	@:noCompletion private function new(reader:Socket, writer:Socket, onWake:Void->Void) {
		this.reader = reader;
		__writer = writer;
		__onWake = onWake;
		__drain = Bytes.alloc(64);
		reader.custom = this;
	}

	/**
		Ends the poll the runtime is waiting in, or the next one it starts.
		Safe from any thread: the only thing touched is the writing end, and
		the runtime writes to it once per batch of work at most. A write that
		cannot go -- the byte before it is still unread -- changes nothing,
		since one byte waiting is already a wake.
	**/
	public function wake():Void {
		#if target.threaded
		__lock.acquire();
		#end
		if (!__closed) {
			try {
				__writer.output.writeByte(1);
			} catch (_:Dynamic) {}
		}
		#if target.threaded
		__lock.release();
		#end
	}

	public function registryOnReadable():Void {
		// Whatever is there, taken in one read: each byte is only "look",
		// and one look covers every one of them.
		try {
			reader.input.readBytes(__drain, 0, __drain.length);
		} catch (_:Dynamic) {}

		if (__onWake != null) {
			__onWake();
		}
	}

	public function registryOnWritable():Void {}

	public function registryHasBufferedInput():Bool {
		return false;
	}

	public function close():Void {
		// The writing end under the lock, so no wake is part way through a
		// write to it; the reading end is the runtime's own.
		#if target.threaded
		__lock.acquire();
		#end
		var closing:Bool = !__closed;
		__closed = true;
		if (closing) {
			try {
				__writer.close();
			} catch (_:Dynamic) {}
		}
		#if target.threaded
		__lock.release();
		#end
		if (closing) {
			try {
				reader.close();
			} catch (_:Dynamic) {}
		}
	}

	@:noCompletion private inline function get_registryClosed():Bool {
		return __closed;
	}
}
#end
