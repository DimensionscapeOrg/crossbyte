package crossbyte.sys;

import crossbyte.events.EventDispatcher;
import crossbyte.events.NativeProcessEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
import haxe.io.Eof;

#if (sys && (windows || linux || mac || macos))
import haxe.io.Input;
import haxe.io.Output;
import sys.io.Process;
import sys.thread.Deque;
import sys.thread.Thread;
#else
import haxe.io.Input;
import haxe.io.Output;
#end

/** Launches and monitors a native operating-system process. */
class NativeProcess extends EventDispatcher {
	public static inline var isSupported:Bool = #if (sys && (windows || linux || mac || macos)) true #else false #end;

	public var standardInput(get, never):Output;
	public var standardOutput(get, never):Input;
	public var standardError(get, never):Input;
	public var running(get, never):Bool;
	public var pid(get, never):Int;
	public var exitCode(get, never):Int;

	@:noCompletion private var __worker:Worker;
	#if (sys && (windows || linux || mac || macos))
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
	}

	public function exit():Void {
		if (!__running) {
			return;
		}

		if (__process != null) {
			try {
				__process.kill();
			} catch (_:Dynamic) {}
			try {
				__process.close();
			} catch (_:Dynamic) {}
		}
		__running = false;
	}

	public function close():Void {
		exit();
	}

	public function closeInput():Void {
		if (__process != null && __process.stdin != null) {
			try {
				__process.stdin.close();
			} catch (_:Dynamic) {}
		}
	}

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

	@:noCompletion private function __onWorkerProgress(event:ThreadEvent):Void {
		var payload = event.message;
		if (payload == null) {
			return;
		}

		var stream:Null<String> = Reflect.field(payload, "stream");
		var isClose:Dynamic = Reflect.field(payload, "isClose");

		if (isClose == true) {
			if (stream == STREAM_STDOUT && !__stdoutClosed) {
				__stdoutClosed = true;
				dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, "", __exitCode, __pid));
			} else if (stream == STREAM_STDERR && !__stderrClosed) {
				__stderrClosed = true;
				dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_CLOSE, "", __exitCode, __pid));
			}
			return;
		}

		var text:Null<String> = Reflect.field(payload, "text");
		var resolvedText = text == null ? "" : text;
		var isError:Bool = Reflect.field(payload, "isError") == true;
		if (stream == null || stream == STREAM_STDOUT || !isError) {
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_DATA, resolvedText, __exitCode, __pid));
		} else if (stream == STREAM_STDERR) {
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_DATA, resolvedText, __exitCode, __pid));
		}
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

		if (!__stdoutClosed) {
			__stdoutClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, "", __exitCode, __pid));
		}

		if (!__stderrClosed) {
			__stderrClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_CLOSE, "", __exitCode, __pid));
		}

		dispatchEvent(new NativeProcessEvent(NativeProcessEvent.EXIT, "", __exitCode, __pid));
		__process = null;
		__worker = null;
	}

	@:noCompletion private function __onWorkerError(event:ThreadEvent):Void {
		__running = false;
		__exitCode = -1;
		if (!__stdoutClosed) {
			__stdoutClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, "", __exitCode, __pid));
		}

		if (!__stderrClosed) {
			__stderrClosed = true;
			dispatchEvent(new NativeProcessEvent(NativeProcessEvent.STANDARD_ERROR_CLOSE, "", __exitCode, __pid));
		}
		dispatchEvent(new NativeProcessEvent(NativeProcessEvent.EXIT, "", __exitCode, __pid));
		__worker = null;
		__process = null;
	}

	@:noCompletion private inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("NativeProcess is not supported on this target.");
		}
	}

	@:noCompletion private inline function get_standardInput():Output {
		return __process != null ? __process.stdin : null;
	}

	@:noCompletion private inline function get_standardOutput():Input {
		return __process != null ? __process.stdout : null;
	}

	@:noCompletion private inline function get_standardError():Input {
		return __process != null ? __process.stderr : null;
	}

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
