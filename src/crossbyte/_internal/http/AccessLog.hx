package crossbyte._internal.http;

// Server-side, like the server whose responses it records.
#if !(js && !nodejs)
import crossbyte.utils.LogCategory;
import crossbyte.utils.LogLevel;
import crossbyte.utils.LogRecord;
import crossbyte.utils.Logger;
#if target.threaded
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
	The HTTP server's access log: a line per response, written to standard
	output by a thread of its own rather than by the runtime that answered.

	The runtime formats each line (as `Logger` would, text or JSON, with or
	without a time) and queues it, and the writer thread takes everything
	queued at once, a few times a second or sooner once a good deal has
	gathered, and writes it in one write: the runtime never waits on the
	console. To a Windows console a write is flushed and drawn before it
	returns; written per response, that costs an HTTP/1.1 server answering
	as fast as it can 85% of its rate, and 10% to a file.

	**Bounded.** The queue holds at most `CAP_CHARACTERS` of text. Past that a
	line is counted and dropped (the runtime neither waits nor holds more),
	and the next write says how many were, once. A console slower than the
	server can only fall behind by that much.

	**Flushed** by `flush()`, which `HTTPServer.close()` calls, and so
	`drain()` as it finishes; and as each runtime that logged a line exits.
	`Sys.exit` skips that, as it skips the rest of a runtime's exit.

	**One queue for the process**, under a lock, so the runtimes of a server
	spread over several, and several servers, log through it in the order
	their lines were made: a connection's lines stay in its order.

	Where `Logger` has a `sink` or a `recordSink`, the line goes there, on
	the runtime's thread: the application's sink is its own, and nothing
	here calls it from another thread. Likewise on targets without threads;
	on Node, `Logger` already gathers a turn's lines into one write.
**/
@:noCompletion
class AccessLog {
	/** The access log's category: `Logger.setLevel("http.access", WARN)` turns it off. */
	public static final CATEGORY:LogCategory = Logger.category("http.access");

	/** Characters the queue may hold before lines are dropped. */
	public static inline var CAP_CHARACTERS:Int = 1024 * 1024;

	/** Seconds between the writer's writes while lines come slowly. */
	public static inline var INTERVAL_SECONDS:Float = 0.1;

	/** Characters queued that wake the writer at once. */
	private static inline var EAGER_CHARACTERS:Int = 64 * 1024;

	/**
		Records the access log line for a response, if the category lets it
		through. On the runtime's thread.

		The line is fields and no message: `method`, `path`, `status` and
		`client`, in that order, as logfmt pairs in text mode and as members
		of the object in JSON. A value holding a space, a quote or an equals
		sign is quoted, as `Logger` quotes any field value: the path is the
		client's text, decoded, and `/a%20status=500` must not read to a
		logfmt collector as a `status` of its own. A `Logger.recordSink` is
		handed the four as the record's fields.
	**/
	public static function write(method:Null<String>, path:Null<String>, status:Int, client:Null<String>):Void {
		if (!CATEGORY.isEnabled(LogLevel.INFO)) {
			return;
		}
		var methodText:String = method == null ? "" : method;
		var pathText:String = path == null ? "" : path;
		var clientText:String = client == null ? "" : client;
		var records:Null<LogRecord->Void> = Logger.recordSink;
		var time:Float = (Logger.timestamps || records != null) ? @:privateAccess Logger.__now() : 0.0;
		var line:String = __format(methodText, pathText, status, clientText, time);

		if (records != null) {
			var fields:Map<String, String> = [
				"method" => methodText,
				"path" => pathText,
				"status" => Std.string(status),
				"client" => clientText
			];
			records(@:privateAccess new LogRecord(LogLevel.INFO, CATEGORY.name, "", fields, time, line));
			return;
		}
		#if target.threaded
		if (Logger.sink == null) {
			__queue(line);
			return;
		}
		#end
		@:privateAccess Logger.__emit(line);
	}

	/**
		The line for a response, framed as `Logger` frames a record (text or
		JSON, with or without a time). Its fields are written here, in a fixed
		order and with no `Map`, whose order differs by target.
	**/
	private static function __format(method:String, path:String, status:Int, client:String, time:Float):String {
		var buffer:StringBuf = new StringBuf();
		if (Logger.json) {
			@:privateAccess Logger.__jsonHead(buffer, LogLevel.INFO, CATEGORY.name, "", time);
			buffer.add(',"method":');
			@:privateAccess Logger.__jsonString(buffer, method);
			buffer.add(',"path":');
			@:privateAccess Logger.__jsonString(buffer, path);
			buffer.add(',"status":"');
			buffer.add(status);
			buffer.add('","client":');
			@:privateAccess Logger.__jsonString(buffer, client);
			buffer.add("}");
		} else {
			@:privateAccess Logger.__textHead(buffer, LogLevel.INFO, CATEGORY.name, time);
			buffer.add("method=");
			buffer.add(@:privateAccess Logger.__quoteIfNeeded(method));
			buffer.add(" path=");
			buffer.add(@:privateAccess Logger.__quoteIfNeeded(path));
			buffer.add(" status=");
			buffer.add(status);
			buffer.add(" client=");
			buffer.add(@:privateAccess Logger.__quoteIfNeeded(client));
		}
		return buffer.toString();
	}

	/** Writes what is queued now, on the calling thread, after anything the writer is writing. */
	public static function flush():Void {
		#if target.threaded
		__writeQueued();
		#end
	}

	#if target.threaded
	// The queue: lines, their characters counted, and lines dropped since the
	// last write. Taken whole by each write.
	@:noCompletion private static final __lock:Mutex = new Mutex();
	@:noCompletion private static var __lines:Array<String> = [];
	@:noCompletion private static var __characters:Int = 0;
	@:noCompletion private static var __dropped:Int = 0;

	/** Lines dropped since the process started, and lines queued: for measuring. */
	@:noCompletion public static var __droppedTotal:Float = 0;

	@:noCompletion public static var __queuedTotal:Float = 0;

	// Held across a write, so the writer and a flush write in turn and in order.
	@:noCompletion private static final __writing:Mutex = new Mutex();

	// The writer: started with the first line, woken early once a good deal
	// has gathered.
	@:noCompletion private static var __writer:Null<Thread> = null;
	@:noCompletion private static final __wake:Lock = new Lock();
	@:noCompletion private static var __wakePending:Bool = false;

	// Runtimes that have logged here, each flushing as it exits.
	@:noCompletion private static final __watched:Array<crossbyte.core.CrossByte> = [];

	/**
		For tests: where written text goes instead of standard output, the
		cap in characters, and the writer's interval. Null and zero for the
		defaults.
	**/
	@:noCompletion public static var __output:Null<String->Void> = null;

	@:noCompletion public static var __capOverride:Int = 0;
	@:noCompletion public static var __intervalOverride:Float = 0;

	private static function __queue(line:String):Void {
		var cap:Int = __capOverride > 0 ? __capOverride : CAP_CHARACTERS;
		var wake:Bool = false;
		var start:Bool = false;
		__lock.acquire();
		if (__characters + line.length + 1 > cap) {
			__dropped++;
			__droppedTotal++;
		} else {
			__queuedTotal++;
			__lines.push(line);
			__characters += line.length + 1;
			if (__characters >= EAGER_CHARACTERS && !__wakePending) {
				__wakePending = true;
				wake = true;
			}
		}
		if (__writer == null) {
			__writer = Thread.create(__writerLoop);
			start = true;
		}
		__lock.release();

		if (wake) {
			__wake.release();
		}
		if (start) {
			__watchExit();
		}
	}

	/**
		Flushes as the runtime that logged exits: lines queued in its last
		moments are written, not left behind. The first line from each
		runtime registers its runtime.
	**/
	private static function __watchExit():Void {
		var runtime:Null<crossbyte.core.CrossByte> = null;
		try {
			runtime = crossbyte.core.CrossByte.current();
		} catch (_:Dynamic) {}
		if (runtime == null) {
			return;
		}
		__lock.acquire();
		var known:Bool = __watched.indexOf(runtime) >= 0;
		if (!known) {
			__watched.push(runtime);
		}
		__lock.release();
		if (!known) {
			runtime.addEventListener(crossbyte.events.Event.EXIT, _ -> flush());
		}
	}

	// Not __run: hxcpp's Object has a virtual __run, and GCC refuses a static
	// of that name (MSVC let it pass).
	private static function __writerLoop():Void {
		while (true) {
			var interval:Float = __intervalOverride > 0 ? __intervalOverride : INTERVAL_SECONDS;
			__wake.wait(interval);
			__writeQueued();
		}
	}

	private static function __writeQueued():Void {
		__writing.acquire();
		__lock.acquire();
		var lines:Array<String> = __lines;
		var dropped:Int = __dropped;
		if (lines.length > 0) {
			__lines = [];
		}
		__characters = 0;
		__dropped = 0;
		__wakePending = false;
		__lock.release();

		if (lines.length > 0 || dropped > 0) {
			var text:StringBuf = new StringBuf();
			for (line in lines) {
				text.add(line);
				text.add("\n");
			}
			if (dropped > 0) {
				// Once per write, after the lines that were kept.
				var note:String = '$dropped access log line${dropped == 1 ? " was" : "s were"} dropped: the output could not keep up';
				var time:Float = Logger.timestamps ? @:privateAccess Logger.__now() : 0.0;
				text.add(Logger.json ? @:privateAccess Logger.__formatJson(LogLevel.WARN, CATEGORY.name, note, null,
					time) : @:privateAccess Logger.__formatText(LogLevel.WARN, CATEGORY.name, note, null, time));
				text.add("\n");
			}
			try {
				var output:Null<String->Void> = __output;
				if (output != null) {
					output(text.toString());
				} else {
					var stdout = Sys.stdout();
					stdout.writeString(text.toString());
					stdout.flush();
				}
			} catch (_:Dynamic) {
				// Standard output closed under it: nothing can be said, and the
				// writer goes on for whatever comes next.
			}
		}
		__writing.release();
	}

	/** For tests: lines queued and not yet written. */
	@:noCompletion public static function __pending():Int {
		__lock.acquire();
		var count:Int = __lines.length;
		__lock.release();
		return count;
	}
	#end
}
#end
