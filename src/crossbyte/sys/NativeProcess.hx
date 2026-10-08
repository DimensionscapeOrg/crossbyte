package crossbyte.sys;

// Not built for a browser: a page has no processes to launch and no API that
// could stand in for one. Node does, and gets a real implementation below.
#if !(js && !nodejs)

import crossbyte.events.EventDispatcher;
import crossbyte.events.NativeProcessEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.io.Output;

// Every target with sys.io.Process and threads but the interpreter: cpp, hl,
// neko and the jvm. Only cpp names an OS when it is built (the others'
// bytecode runs unchanged on any), and none is needed, since their Process
// and threads work wherever they run. Asking for an OS would have hl, neko
// and the jvm refuse to start a process anywhere, so this asks for threads.
// The interpreter is left out for the reason `isSupported` gives.
import crossbyte.errors.IllegalOperationError;
#if nodejs
import crossbyte.sys._internal.NodeProcessOutput;
import js.node.ChildProcess as ChildProcessModule;
import js.node.child_process.ChildProcess as ChildProcessObject;
#elseif (sys && target.threaded && !eval)
import sys.io.Process;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

#if !nodejs
/**
	What a reader thread hands the runtime: a typed message rather than an
	anonymous object read back with eight `Reflect.field` calls.
**/
private enum ProcessOutput {
	Chunk(stream:String, text:String, isError:Bool);
	Closed(stream:String);
	Exited(exitCode:Int, pid:Int);
}
#end

/**
	Launches and monitors a native operating-system process.

	A child's output is read as it comes and handed to the runtime, which
	dispatches it. Natively, on the jvm, hl and neko at most
	`MAX_OUTPUT_AHEAD` bytes of it are held ahead of the runtime, for each
	process: past that the readers stop reading, and a child that goes on
	writing waits on its pipe until the runtime has caught up, rather than a
	chatty child of a busy server having its whole output held in this
	process.
**/
class NativeProcess extends EventDispatcher {
	/**
		How much of a child's output is held ahead of the runtime before the
		readers wait for it: 256 KB, in the 4 KB pieces they read.
	**/
	public static inline var MAX_OUTPUT_AHEAD:Int = MAX_CHUNKS_AHEAD * OUTPUT_BUFFER_SIZE;

	/**
		Whether this build can start a process: natively, on the jvm, hl,
		neko and Node.

		Not on the interpreter (`--interp`). Its process natives (a read of
		the child's output, the wait for it to end) hold every thread while
		they wait, so a child with nothing to say would stop the whole program
		until it spoke or ended, and one that waits for input before writing
		anything could never be given any. `start` throws there, saying so.
		Not in a browser either, which has no processes; the class is not built
		for one.
	**/
	public static inline var isSupported:Bool = #if (nodejs || (sys && target.threaded && !eval)) true #else false #end;

	public var standardInput(get, never):Output;
	public var standardOutput(get, never):Input;
	public var standardError(get, never):Input;
	public var running(get, never):Bool;

	/**
		The child's process id while it runs, and on the `EXIT` event; -1 before
		one has started.

		On the jvm the id needs Java 9 or later, or Linux or macOS: Java 8 on
		Windows keeps the child's handle and gives no way to learn its id, and
		there this stays -1.
	**/
	public var pid(get, never):Int;
	public var exitCode(get, never):Int;

	#if !nodejs
	@:noCompletion private var __worker:Worker;
	#end
	#if nodejs
	@:noCompletion private var __process:ChildProcessObject;
	@:noCompletion private var __standardInput:NodeProcessOutput;
	#elseif (sys && target.threaded && !eval)
	@:noCompletion private var __process:Process;
	#else
	@:noCompletion private var __process:Dynamic;
	#end
	@:noCompletion private var __running:Bool = false;
	@:noCompletion private var __exitCode:Int = -1;
	@:noCompletion private var __pid:Int = -1;
	@:noCompletion private var __stdoutClosed:Bool = false;
	@:noCompletion private var __stderrClosed:Bool = false;
	#if (sys && target.threaded && !eval && !nodejs)
	/**
		For a test: run on the worker's thread once the completion has gone to
		the runtime, the moment the runtime may be dispatching `EXIT`.
	**/
	@:noCompletion private static var __afterCompleteForTest:Null<Void->Void> = null;
	#end

	@:noCompletion private static inline var OUTPUT_BUFFER_SIZE:Int = 4096;
	@:noCompletion private static inline var MAX_CHUNKS_AHEAD:Int = 64;

	#if (sys && target.threaded && !eval && !nodejs)
	// Pieces of output the readers have sent and the runtime has not yet
	// dispatched, under __flowLock; __flowWake lets a waiting reader go.
	@:noCompletion private var __chunksAhead:Int = 0;
	@:noCompletion private var __flowLock:Mutex = null;
	@:noCompletion private var __flowWake:Lock = null;
	#end
	@:noCompletion private static inline var STREAM_STDOUT:String = "stdout";
	@:noCompletion private static inline var STREAM_STDERR:String = "stderr";

	public function new() {
		super();
	}

	/**
		Starts the process `info` describes.

		Natively, on the jvm and on Node a child inherits none of this
		program's sockets. On neko it inherits every one that is open, and
		probably on HashLink too, whose process natives are built the same
		way, though that has not been run: a listener the child
		holds stays bound until the child exits, and a connection it holds is
		not closed by this program closing it. Nothing a Haxe program can do
		changes that there; start children before opening sockets, or prefer
		another target for a server that starts processes.

		@throws IllegalOperationError Where processes cannot be started: the
				interpreter (see `isSupported`).
	**/
	public function start(info:NativeProcessStartupInfo):Void {
		__requireSupported();

		if (info == null || info.executable == null || info.executable == "") {
			throw new ArgumentError("You must supply a process startup descriptor with an executable path.");
		}

		if (__running) {
			throw new ArgumentError("NativeProcess is already running.");
		}

		__exitCode = -1;
		__pid = -1;
		__running = true;
		__stdoutClosed = false;
		__stderrClosed = false;

		#if nodejs
		__startNode(info);
		#else
		#if (sys && target.threaded && !eval)
		try {
			var args = info.arguments == null ? [] : info.arguments;
			__process = new Process(info.executable, args, false);
			__pid = __resolvePid();
		} catch (e:Dynamic) {
			__process = null;
			__running = false;
			throw e;
		}
		#end

		#if (sys && target.threaded && !eval)
		__chunksAhead = 0;
		__flowLock = new Mutex();
		__flowWake = new Lock();
		#end

		__worker = new Worker();
		__worker.addEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__worker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__worker.addEventListener(ThreadEvent.ERROR, __onWorkerError);
		__worker.doWork = function(_:Dynamic):Void {
			__execute(info);
		};

		__worker.run(info);
		#end
	}

	public function exit():Void {
		if (!__running) {
			return;
		}

		// Signal shutdown and terminate the child, but do NOT close the process
		// here. On the threaded targets the worker closes it (in __execute) only
		// after both reader threads have drained, and closing under the
		// in-flight reads would be a use-after-close race; on Node the runtime
		// owns the handle. Either way killing the child is enough, and the
		// ordinary completion path is what dispatches EXIT.
		__running = false;

		if (__process != null) {
			try {
				__process.kill();
			} catch (_:Dynamic) {}
		}
	}

	public function close():Void {
		exit();
	}

	public function closeInput():Void {
		if (__process == null || __process.stdin == null) {
			return;
		}

		try {
			#if nodejs
			__process.stdin.end(null);
			#else
			__process.stdin.close();
			#end
		} catch (_:Dynamic) {}
	}

	#if !nodejs
	@:noCompletion private function __execute(info:NativeProcessStartupInfo):Void {
		#if (sys && target.threaded && !eval)
		// The child, held here rather than read from the field each time: the
		// runtime clears the field when it dispatches EXIT, which the
		// completion below can lead to while this thread is still running.
		var process:Process = __process;
		try {
			var readerCompletion = new Deque<String>();
			Thread.create(() -> {
				__readStream(STREAM_STDOUT, process.stdout);
				readerCompletion.add(STREAM_STDOUT);
			});
			Thread.create(() -> {
				__readStream(STREAM_STDERR, process.stderr);
				readerCompletion.add(STREAM_STDERR);
			});

			// The output to its end first, then the exit code. The jvm's
			// exitCode() reads whatever output is left into a buffer of its
			// own before it waits, racing the readers above for it: what it
			// took would never be delivered. Elsewhere the order changes
			// nothing, since both have to finish before the completion goes
			// out.
			readerCompletion.pop(true);
			readerCompletion.pop(true);

			__exitCode = __waitForExit();

			// Closed before the completion goes, not after it through the
			// field. The runtime clears the field as it dispatches EXIT, and
			// one that got there first left this closing null: natively an
			// access violation, which no catch takes, and elsewhere the
			// child's handles left for the collector to close. A game server
			// supervising its client processes died of it in three runs of
			// four when a thousand clients' processes ended at once. The output
			// has been read to its end and the exit code taken, so nothing
			// needs the child after this.
			try {
				process.close();
			} catch (_:Dynamic) {}

			__worker.sendComplete(Exited(__exitCode, __pid));
			if (__afterCompleteForTest != null) {
				__afterCompleteForTest();
			}
		} catch (e:Dynamic) {
			__exitCode = -1;
			// Whether or not exit() asked for the end, it has come, and EXIT is
			// owed, even once exit() has cleared __running, so a child stopped
			// that way is reported as gone.
			var worker:Worker = __worker;
			if (worker != null) {
				worker.sendError(Std.string(e));
			}
		}
		__running = false;
		#else
		__worker.sendError("NativeProcess is not supported on this target.");
		__running = false;
		#end
	}

	@:noCompletion private function __readStream(streamName:String, stream:Input):Void {
		if (__worker == null) {
			return;
		}

		if (stream == null) {
			__worker.sendProgress(Closed(streamName));
			return;
		}

		var buffer:Bytes = Bytes.alloc(OUTPUT_BUFFER_SIZE);
		// The first bytes of a character the last read cut in two, kept at
		// the front of the buffer for the next read to finish, so a UTF-8
		// character split across two reads is not decoded as replacement
		// characters; Node decodes across reads already.
		var carried:Int = 0;
		#if hl
		var handle = @:privateAccess __process.p;
		#end
		while (true) {
			try {
				#if hl
				var bytesRead = __hlRead(handle, streamName == STREAM_STDOUT, buffer, carried, OUTPUT_BUFFER_SIZE - carried);
				#else
				var bytesRead = stream.readBytes(buffer, carried, OUTPUT_BUFFER_SIZE - carried);
				#end
				if (bytesRead <= 0) {
					if (!__running) {
						break;
					}
					crossbyte._internal.system.Sleep.sleep(0.001);
					continue;
				}

				var length:Int = carried + bytesRead;
				var whole:Int = __wholeCharacters(buffer, length);
				if (whole > 0 && __worker != null) {
					__worker.sendProgress(Chunk(streamName, buffer.getString(0, whole), streamName == STREAM_STDERR));
					__awaitRoom();
				}
				carried = length - whole;
				if (carried > 0) {
					buffer.blit(0, buffer, whole, carried);
				}
			} catch (e:Eof) {
				break;
			} catch (_:Dynamic) {
				break;
			}
		}

		// Output that ends inside a character ends there: what there is of it
		// goes as it is.
		if (carried > 0 && __worker != null) {
			__worker.sendProgress(Chunk(streamName, buffer.getString(0, carried), streamName == STREAM_STDERR));
		}

		if (__worker != null) {
			__worker.sendProgress(Closed(streamName));
		}
	}

	/**
		On a reader's thread, after it has sent a piece: counts it, and waits
		while `MAX_CHUNKS_AHEAD` are with the runtime undispatched. Each wait is
		short, so a reader stops waiting once the process is exited.
	**/
	@:noCompletion private function __awaitRoom():Void {
		#if (sys && target.threaded && !eval)
		var flow:Mutex = __flowLock;
		var wake:Lock = __flowWake;
		if (flow == null || wake == null) {
			return;
		}
		flow.acquire();
		__chunksAhead++;
		var full:Bool = __chunksAhead >= MAX_CHUNKS_AHEAD;
		flow.release();
		while (full && __running && !__runtimeGone()) {
			wake.wait(0.05);
			flow.acquire();
			full = __chunksAhead >= MAX_CHUNKS_AHEAD;
			flow.release();
		}
		#end
	}

	/**
		Whether the runtime that dispatches this process's output has exited,
		so nothing will ever make room: the readers then read on, as they did
		before, rather than wait for good.
	**/
	@:noCompletion private function __runtimeGone():Bool {
		var worker:Worker = __worker;
		if (worker == null) {
			return true;
		}
		var runtime:crossbyte.core.CrossByte = @:privateAccess worker.__runtime;
		return runtime == null || @:privateAccess runtime.__postClosed;
	}

	/**
		On the runtime's thread, as a piece is dispatched: lets the readers go
		on once the runtime has caught up below the limit.
	**/
	@:noCompletion private function __chunkDispatched():Void {
		#if (sys && target.threaded && !eval)
		var flow:Mutex = __flowLock;
		if (flow == null) {
			return;
		}
		flow.acquire();
		var wasFull:Bool = __chunksAhead >= MAX_CHUNKS_AHEAD;
		if (__chunksAhead > 0) {
			__chunksAhead--;
		}
		flow.release();
		if (wasFull) {
			// Once for each reader that may be waiting.
			__flowWake.release();
			__flowWake.release();
		}
		#end
	}

	/**
		How many of the first `length` bytes of `bytes` end on a whole UTF-8
		character: all of them, unless the last few begin a character whose
		remaining bytes the next read will bring.
	**/
	@:noCompletion private static function __wholeCharacters(bytes:Bytes, length:Int):Int {
		// Back over up to three continuation bytes to the last lead byte.
		var lead:Int = length - 1;
		var back:Int = 0;
		while (lead >= 0 && back < 3 && (bytes.get(lead) & 0xC0) == 0x80) {
			lead--;
			back++;
		}
		if (lead < 0) {
			return length;
		}
		var first:Int = bytes.get(lead);
		var size:Int = if (first < 0x80) 1 else if ((first & 0xE0) == 0xC0) 2 else if ((first & 0xF0) == 0xE0) 3 else if ((first & 0xF8) == 0xF0) 4 else 1;
		return length - lead < size ? lead : length;
	}

	/** The child's exit code, once it has one. **/
	@:noCompletion private function __waitForExit():Int {
		#if hl
		var handle = @:privateAccess __process.p;
		hl.Gc.blocking(true);
		var code:Int = __hlExit(handle, null);
		hl.Gc.blocking(false);
		return code;
		#elseif (jvm && !macro)
		// The JDK's wait, not Haxe's exitCode(), which first reads whatever
		// output is left into a buffer of its own: the readers have read it
		// all by now, and on Linux the JDK's destroy() closes the streams, so
		// after exit() that read would throw "Stream closed" and EXIT never
		// come.
		var process:java.lang.Process = @:privateAccess __process.proc;
		process.waitFor();
		return process.exitValue();
		#else
		return __process.exitCode();
		#end
	}

	#if hl
	/**
		The child's output, read inside a blocking section.

		HashLink reads a child's output with a bare ReadFile or read, and waits
		for it to exit with WaitForSingleObject or waitpid, none of which tells
		its collector the thread is waiting, and the collector stops every
		thread until each reaches a safe point. Outside a blocking section, a
		child that said nothing for five seconds would hold the whole runtime
		for five (5,212 ms between two ticks of a runtime that ticks sixty
		times a second). Its socket reads mark the wait, and these do the
		same. Nothing inside a blocking section may allocate, and these
		natives do not; the buffer is resolved before entering, and the
		answer interpreted after leaving.
	**/
	@:noCompletion private static function __hlRead(handle:hl.Abstract<"hl_process">, stdout:Bool, buffer:Bytes, offset:Int, length:Int):Int {
		var data:hl.Bytes = buffer;
		hl.Gc.blocking(true);
		var read:Int = stdout ? __hlStdoutRead(handle, data, offset, length) : __hlStderrRead(handle, data, offset, length);
		hl.Gc.blocking(false);
		if (read < 0) {
			throw new Eof();
		}
		return read;
	}

	@:hlNative("std", "process_stdout_read") private static function __hlStdoutRead(p:hl.Abstract<"hl_process">, bytes:hl.Bytes, pos:Int, len:Int):Int {
		return 0;
	}

	@:hlNative("std", "process_stderr_read") private static function __hlStderrRead(p:hl.Abstract<"hl_process">, bytes:hl.Bytes, pos:Int, len:Int):Int {
		return 0;
	}

	@:hlNative("std", "process_exit") private static function __hlExit(p:hl.Abstract<"hl_process">, running:hl.Ref<Bool>):Int {
		return 0;
	}
	#end

	/**
		`getPid()`, which `sys.io.Process` has on every target.
	**/
	@:noCompletion private function __resolvePid():Int {
		try {
			if (__process != null) {
				#if (jvm && !macro)
				var pid:Null<Int> = __jvmPid(@:privateAccess __process.proc);
				#else
				var pid:Null<Int> = __process.getPid();
				#end
				if (pid != null && pid > 0) {
					return pid;
				}
			}
		} catch (_:Dynamic) {}

		return -1;
	}

	#if (jvm && !macro)
	/**
		The child's id on the jvm. Its `sys.io.Process.getPid()` looks for a
		`pid` field, which no JDK's `Process` has, and answers -1. Java 9 added
		a `pid()` method; before it only the POSIX implementation kept the id,
		in a private field. Java 8 on Windows keeps a handle and no id at all.
	**/
	@:noCompletion private static function __jvmPid(process:java.lang.Process):Int {
		try {
			// Looked up on Process, the public class, rather than on the
			// child's own class, which no code outside java.base may call into.
			var method = java.lang.Class.forName("java.lang.Process").getMethod("pid");
			var id:java.lang.Long = cast method.invoke(process);
			return id.intValue();
		} catch (_:Dynamic) {}

		try {
			var field = java.Lib.getNativeType(process).getDeclaredField("pid");
			field.setAccessible(true);
			return field.getInt(process);
		} catch (_:Dynamic) {}

		return -1;
	}
	#end
	#end

	#if !nodejs
	@:noCompletion private function __onWorkerProgress(event:ThreadEvent):Void {
		var output:Null<ProcessOutput> = event.message;
		if (output == null) {
			return;
		}

		switch (output) {
			case Chunk(stream, text, isError):
				__chunkDispatched();
				__emitData(stream, text == null ? "" : text, isError);
			case Closed(stream):
				__emitClose(stream);
			case Exited(_, _):
		}
	}

	@:noCompletion private function __onWorkerComplete(event:ThreadEvent):Void {
		__running = false;
		var output:Null<ProcessOutput> = event.message;
		if (output != null) {
			switch (output) {
				case Exited(exitCode, pid):
					__pid = pid;
					__exitCode = exitCode;
				default:
			}
		}

		__emitExit();
		__worker = null;
	}

	@:noCompletion private function __onWorkerError(event:ThreadEvent):Void {
		__running = false;
		__exitCode = -1;
		__emitExit();
		__worker = null;
	}
	#end

	/**
	 * The three event shapes both implementations report through, so that a
	 * caller cannot tell a threaded reader from a Node stream by what arrives.
	 */
	@:noCompletion private function __emitData(stream:Null<String>, text:String, isError:Bool):Void {
		if (stream == null || stream == STREAM_STDOUT || !isError) {
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_DATA, text, __exitCode, __pid));
		} else if (stream == STREAM_STDERR) {
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_DATA, text, __exitCode, __pid));
		}
	}

	@:noCompletion private function __emitClose(stream:Null<String>):Void {
		if (stream == STREAM_STDOUT && !__stdoutClosed) {
			__stdoutClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, "", __exitCode, __pid));
		} else if (stream == STREAM_STDERR && !__stderrClosed) {
			__stderrClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_CLOSE, "", __exitCode, __pid));
		}
	}

	/**
	 * Both stream closes then EXIT, in that order. A caller that has not seen a
	 * close for one of the streams gets it here rather than never: the child is
	 * gone, so no more of its output is coming either way.
	 */
	@:noCompletion private function __emitExit():Void {
		__emitClose(STREAM_STDOUT);
		__emitClose(STREAM_STDERR);
		dispatchEvent(new NativeProcessEvent(NativeProcessEvent.EXIT, "", __exitCode, __pid));
		__process = null;
		#if nodejs
		__standardInput = null;
		#end
	}

	#if nodejs
	/**
	 * Node's child_process, which is asynchronous to begin with, so there is
	 * no worker here. `Worker` exists on the threaded targets to keep a blocking
	 * read off the runtime's thread, and neither the spawn nor the reads block.
	 *
	 * One difference is visible to a caller and cannot be hidden: an executable
	 * that does not exist throws out of `start` on the threaded targets, because
	 * the spawn fails there and then. Node reports it as an `error` event some
	 * time later, so it arrives here as an EXIT with an exit code of -1, the
	 * same shape a worker failure takes.
	 */
	@:noCompletion private function __startNode(info:NativeProcessStartupInfo):Void {
		var child:ChildProcessObject;

		try {
			child = ChildProcessModule.spawn(info.executable, info.arguments == null ? [] : info.arguments);
		} catch (e:Dynamic) {
			__running = false;
			throw e;
		}

		__process = child;
		__pid = child.pid == null ? -1 : child.pid;
		__standardInput = child.stdin == null ? null : new NodeProcessOutput(child.stdin);

		__readNodeStream(child.stdout, STREAM_STDOUT);
		__readNodeStream(child.stderr, STREAM_STDERR);

		child.on("error", function(_:Dynamic):Void {
			if (__process == null) {
				return;
			}

			__running = false;
			__exitCode = -1;
			__emitExit();
		});

		// `close` rather than `exit`: `exit` fires when the child is gone, which
		// can be before its output has been drained, and reporting EXIT then
		// would cut off data the caller is entitled to. `close` waits for the
		// stdio to end as well, which is the point the threaded path reaches by
		// joining its two reader threads.
		child.on("exit", function(code:Null<Int>, _:Null<String>):Void {
			__exitCode = code == null ? -1 : code;
		});

		child.on("close", function(code:Null<Int>, _:Null<String>):Void {
			if (__process == null) {
				return;
			}

			__running = false;

			// Null when the child was signalled rather than exiting on its own,
			// in which case whatever `exit` recorded already stands.
			if (code != null) {
				__exitCode = code;
			}

			__emitExit();
		});
	}

	@:noCompletion private function __readNodeStream(stream:Null<js.node.stream.Readable.IReadable>, name:String):Void {
		if (stream == null) {
			__emitClose(name);
			return;
		}

		// Decoded by Node rather than chunk by chunk, so a multi-byte character
		// split across two reads survives: its decoder holds the partial
		// sequence until the rest arrives.
		stream.setEncoding("utf8");

		stream.on("data", function(chunk:Dynamic):Void {
			__emitData(name, Std.string(chunk), name == STREAM_STDERR);
		});

		stream.on("end", function():Void {
			__emitClose(name);
		});
	}
	#end

	@:noCompletion private inline function __requireSupported():Void {
		if (!isSupported) {
			// An IllegalOperationError naming the target, as everything that
			// cannot work on one throws, rather than an ArgumentError, which
			// would say the caller passed something wrong.
			#if eval
			throw new IllegalOperationError("NativeProcess cannot start a process on the interpreter (--interp): its process calls hold every thread while they wait on the child. Build for a native target, the jvm, hl, neko or Node.");
			#else
			throw new IllegalOperationError("NativeProcess cannot start a process on this target.");
			#end
		}
	}

	@:noCompletion private inline function get_standardInput():Output {
		#if nodejs
		return __standardInput;
		#else
		return __process != null ? __process.stdin : null;
		#end
	}

	@:noCompletion private function get_standardOutput():Input {
		#if nodejs
		return __refuseNodeStream("standardOutput", "STANDARD_OUTPUT_DATA");
		#else
		return __process != null ? __process.stdout : null;
		#end
	}

	@:noCompletion private function get_standardError():Input {
		#if nodejs
		return __refuseNodeStream("standardError", "STANDARD_ERROR_DATA");
		#else
		return __process != null ? __process.stderr : null;
		#end
	}

	#if nodejs
	/**
	 * Node delivers a child's output through callbacks, and no amount of
	 * wrapping turns that into a synchronous `Input`: the bytes are simply not
	 * there yet when a caller asks for them. Returning null would read as "the
	 * process has not started", which is a different and wrong answer, so this
	 * says what is actually true and points at the events that do carry the
	 * output on every target.
	 */
	@:noCompletion private function __refuseNodeStream(name:String, constant:String):Input {
		throw new IllegalOperationError("NativeProcess." + name + " cannot be read synchronously on Node; listen for NativeProcessEvent." + constant
			+ " instead.");
	}
	#end

	@:noCompletion private inline function get_running():Bool {
		return __running;
	}

	@:noCompletion private inline function get_pid():Int {
		return __pid;
	}

	@:noCompletion private inline function get_exitCode():Int {
		return __exitCode;
	}
}
#end
