package crossbyte._internal.http;

// Server-side, like the static files it keeps.
#if !(js && !nodejs)
import haxe.io.Bytes;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	Bodies kept by path, each with the size and modification time of the file
	it was made from, under one byte budget, the least recently used let go
	first. What `HTTPCompression` keeps compressed static files in, a slot
	per coding, and the server its small static files.

	Most recent use is a link in a list, moved in constant time, and a
	lookup builds no key.

	A lock is taken per call: a configuration, and so this, can be shared by
	servers on several runtimes' threads.
**/
@:noCompletion
final class KeptBodies {
	/** Bytes kept at most; see `budget`. */
	public var budget:Int;

	// A map of path to body per slot: a coding's number, for HTTPCompression.
	private final __slots:Array<Map<String, KeptBody>> = [];
	// Most recently used first.
	private var __head:Null<KeptBody> = null;
	private var __tail:Null<KeptBody> = null;
	private var __bytes:Int = 0;
	#if target.threaded
	private final __lock:Mutex = new Mutex();
	#end

	public function new(budget:Int) {
		this.budget = budget;
	}

	/** Bytes kept now. */
	public var bytes(get, never):Int;

	private function get_bytes():Int {
		__acquire();
		var kept:Int = __bytes;
		__release();
		return kept;
	}

	/**
		The body kept for `path`, if the file still has `size` bytes and was
		last modified at `modified`; null otherwise, and one kept for an older
		version of the file is let go.
	**/
	public function get(slot:Int, path:String, size:Float, modified:Float):Null<Bytes> {
		__acquire();
		var entries:Null<Map<String, KeptBody>> = __slots[slot];
		var entry:Null<KeptBody> = entries == null ? null : entries.get(path);
		var found:Null<Bytes> = null;
		if (entry != null) {
			if (entry.size == size && entry.modified == modified) {
				found = entry.body;
				__touch(entry);
			} else {
				__drop(entry);
			}
		}
		__release();
		return found;
	}

	/** Keeps `body` for `path`, if it fits the budget, letting the least recently used go to make room. */
	public function put(slot:Int, path:String, size:Float, modified:Float, body:Bytes):Void {
		if (budget <= 0 || body.length > budget) {
			return;
		}
		__acquire();
		var entries:Null<Map<String, KeptBody>> = __slots[slot];
		if (entries == null) {
			entries = new Map();
			__slots[slot] = entries;
		}
		var old:Null<KeptBody> = entries.get(path);
		if (old != null) {
			__drop(old);
		}
		while (__bytes + body.length > budget && __tail != null) {
			__drop(__tail);
		}
		var entry:KeptBody = new KeptBody(slot, path, size, modified, body);
		entries.set(path, entry);
		__link(entry);
		__bytes += body.length;
		__release();
	}

	/** Lets every kept body go. */
	public function clear():Void {
		__acquire();
		for (entries in __slots) {
			if (entries != null) {
				entries.clear();
			}
		}
		__head = null;
		__tail = null;
		__bytes = 0;
		__release();
	}

	private function __touch(entry:KeptBody):Void {
		if (__head == entry) {
			return;
		}
		__unlink(entry);
		__link(entry);
	}

	private function __link(entry:KeptBody):Void {
		entry.previous = null;
		entry.next = __head;
		if (__head != null) {
			__head.previous = entry;
		}
		__head = entry;
		if (__tail == null) {
			__tail = entry;
		}
	}

	private function __unlink(entry:KeptBody):Void {
		if (entry.previous != null) {
			entry.previous.next = entry.next;
		} else {
			__head = entry.next;
		}
		if (entry.next != null) {
			entry.next.previous = entry.previous;
		} else {
			__tail = entry.previous;
		}
		entry.previous = null;
		entry.next = null;
	}

	private function __drop(entry:KeptBody):Void {
		__unlink(entry);
		__slots[entry.slot].remove(entry.path);
		__bytes -= entry.body.length;
	}

	private inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	private inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
	}
}

private final class KeptBody {
	public final slot:Int;
	public final path:String;
	public final size:Float;
	public final modified:Float;
	public final body:Bytes;
	public var previous:Null<KeptBody> = null;
	public var next:Null<KeptBody> = null;

	public function new(slot:Int, path:String, size:Float, modified:Float, body:Bytes) {
		this.slot = slot;
		this.path = path;
		this.size = size;
		this.modified = modified;
		this.body = body;
	}
}
#end
