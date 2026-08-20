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

#if nodejs
import crossbyte.errors.IllegalOperationError;
import crossbyte.sys._internal.NodeProcessOutput;
import js.node.ChildProcess as ChildProcessModule;
import js.node.child_process.ChildProcess as ChildProcessObject;
#elseif (sys && (windows || linux || mac || macos))
import sys.io.Process;
import sys.thread.Deque;
import sys.thread.Thread;
#end

/** Launches and monitors a native operating-system process. */
class NativeProcess extends EventDispatcher {
	public static inline var isSupported:Bool = #if (nodejs || (sys && (windows || linux || mac || macos))) true #else false #end;

	public var standardInput(get, never):Output;
	public var standardOutput(get, never):Input;
	public var standardError(get, never):Input;
	public var running(get, never):Bool;
	public var pid(get, never):Int;
	public var exitCode(get, never):Int;

	#if !nodejs
	@:noCompletion private var __worker:Worker;
	#end
	#if nodejs
	@:noCompletion private var __process:ChildProcessObject;
	@:noCompletion private var __standardInput:NodeProcessOutput;
	#elseif (sys && (windows || linux || mac || macos))
	@:noCompletion private var __process:Process;
	#else
	@:noCompletion private var __process:Dynamic;
	#end
	@:noCompletion private var __running:Bool = false;
	@:noCompletion private var __exitCode:Int = -1;
	@:noCompletion private var __pid:Int = -1;
	@:noCompletion private var __stdoutClosed:Bool = false;
	@:noCompletion private var __stderrClosed:Bool = false;
	@:noCompletion private static inline var OUTPUT_BUFFER_SIZE:Int = 4096;
	@:noCompletion private static inline var STREAM_STDOUT:String = "stdout";
	@:noCompletion private static inline var STREAM_STDERR:String = "stderr";

	public function new() {
		super();
	}

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
		#if (sys && (windows || linux || mac || macos))
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
	@:noCompletion private function __execute(info:Dynamic):Void {
		#if (sys && (windows || linux || mac || macos))
		try {
			var readerCompletion = new Deque<String>();
			Thread.create(() -> {
				__readStream(STREAM_STDOUT, __process.stdout);
				readerCompletion.add(STREAM_STDOUT);
			});
			Thread.create(() -> {
				__readStream(STREAM_STDERR, __process.stderr);
				readerCompletion.add(STREAM_STDERR);
			});

			__exitCode = __process.exitCode();

			readerCompletion.pop(true);
			readerCompletion.pop(true);

			__worker.sendComplete({exitCode: __exitCode, pid: __pid});

			try {
				__process.close();
			} catch (_:Dynamic) {}
		} catch (e:Dynamic) {
			__exitCode = -1;
			if (__running) {
				__worker.sendError(Std.string(e));
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
			__worker.sendProgress({stream: streamName, isClose: true});
			return;
		}

		var buffer:Bytes = Bytes.alloc(OUTPUT_BUFFER_SIZE);
		while (true) {
			try {
				var bytesRead = stream.readBytes(buffer, 0, OUTPUT_BUFFER_SIZE);
				if (bytesRead <= 0) {
					if (!__running) {
						break;
					}
					Sys.sleep(0.001);
					continue;
				}

				if (__worker != null) {
					__worker.sendProgress({
						stream: streamName,
						isError: streamName == STREAM_STDERR,
						text: buffer.sub(0, bytesRead).toString()
					});
				}
			} catch (e:Eof) {
				break;
			} catch (_:Dynamic) {
				break;
			}
		}

		if (__worker != null) {
			__worker.sendProgress({stream: streamName, isClose: true});
		}
	}

	@:noCompletion private function __resolvePid():Int {
		var value:Dynamic = null;
		try {
			if (__process != null) {
				value = Reflect.field(__process, "pid");
				if (Std.isOfType(value, Int)) {
					return value;
				}

				if (Std.isOfType(value, String)) {
					var parsed = Std.parseInt(cast value);
					return parsed != null ? parsed : -1;
				}

				if (value != null && Reflect.isFunction(value)) {
					value = Reflect.callMethod(__process, value, []);
					if (Std.isOfType(value, Int)) {
						return value;
					}
				}
			}
		} catch (_:Dynamic) {}

		return -1;
	}
	#end

	#if !nodejs
	@:noCompletion private function __onWorkerProgress(event:ThreadEvent):Void {
		var payload = event.message;
		if (payload == null) {
			return;
		}

		var stream:Null<String> = Reflect.field(payload, "stream");

		if (Reflect.field(payload, "isClose") == true) {
			__emitClose(stream);
			return;
		}

		var text:Null<String> = Reflect.field(payload, "text");
		__emitData(stream, text == null ? "" : text, Reflect.field(payload, "isError") == true);
	}

	@:noCompletion private function __onWorkerComplete(event:ThreadEvent):Void {
		__running = false;
		var payload = event.message;
		if (payload != null && Reflect.field(payload, "pid") != null) {
			__pid = cast Reflect.field(payload, "pid");
		}
		if (payload != null && Reflect.field(payload, "exitCode") != null) {
			__exitCode = cast Reflect.field(payload, "exitCode");
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
	 * Node's child_process, which is asynchronous to begin with -- so there is
	 * no worker here. `Worker` exists on the threaded targets to keep a blocking
	 * read off the runtime's thread, and neither the spawn nor the reads block.
	 *
	 * One difference is visible to a caller and cannot be hidden: an executable
	 * that does not exist throws out of `start` on the threaded targets, because
	 * the spawn fails there and then. Node reports it as an `error` event some
	 * time later, so it arrives here as an EXIT with an exit code of -1 -- the
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
		// split across two reads survives -- its decoder holds the partial
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
			throw new ArgumentError("NativeProcess is not supported on this target.");
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
