package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.NativeProcessEvent;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte.core.CrossByte)
class NativeProcessTest extends utest.Test {
	// Every wait below returns the moment its predicate holds, so this ceiling
	// costs nothing when the child behaves and only decides how loaded a machine
	// has to get before a passing test reports a failure. Spawning a process is
	// not reliably a three-second operation on a busy CI runner.
	private static inline var TIMEOUT:Float = 15.0;

	// Every target with processes and threads but the interpreter: cpp, hl,
	// neko and the jvm, none of which but cpp names an OS when it is built,
	// so support is not decided by asking for one. The interpreter's process
	// calls hold every thread while they wait, so it refuses, and says why.
	public function testSupportFlagMatchesTarget():Void {
		#if (nodejs || (sys && target.threaded && !eval))
		Assert.isTrue(NativeProcess.isSupported);
		#else
		Assert.isFalse(NativeProcess.isSupported);
		#end
	}

	public function testStartThrowsWhenUnsupported():Void {
		#if (sys && target.threaded && !eval)
		Assert.pass();
		#else
		// An IllegalOperationError, which says the target cannot, rather than
		// an ArgumentError, which says the caller passed something wrong; and
		// on the interpreter, why.
		var proc = new NativeProcess();
		var thrown:Dynamic = null;
		try {
			proc.start(new NativeProcessStartupInfo("echo"));
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IllegalOperationError), "start threw " + thrown);
		#if eval
		Assert.isTrue(Std.string(thrown).indexOf("interpreter") >= 0, "the refusal did not name the interpreter: " + thrown);
		#end
		Assert.isFalse(proc.running);
		#end
	}

	public function testStartEmitEventsAndExitCode():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var output:String = "";
		var exited:Bool = false;
		var exitCode:Int = -1;
		var stdoutClosed:Bool = false;
		var stderrClosed:Bool = false;

		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> output += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitCode = event.exitCode;
		});
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, _ -> stdoutClosed = true);
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_CLOSE, _ -> stderrClosed = true);

		var info = getDefaultInfo();
		proc.start(info);

		pumpUntil(() -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(0, exitCode);
		Assert.isTrue(stdoutClosed);
		Assert.isTrue(stderrClosed);
		Require.notNull(output);
		Assert.isTrue(output.indexOf("nativeprocess_smoke") >= 0);
		#else
		Assert.pass();
		#end
	}

	/**
		The child's own id, while it runs and on the event that ends it.

		The id is read through `getPid()`, which every target's
		`sys.io.Process` has, not looked up as a `pid` field by reflection,
		which none has: that would read -1 on every target that runs the child
		on a thread, cpp included.
	**/
	public function testThePidIsTheChilds():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		var exitPid:Int = -1;

		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitPid = event.pid;
		});

		proc.start(getDefaultInfo());
		var pid:Int = proc.pid;

		pumpUntil(() -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(pid, exitPid);
		#if jvm
		// The one place there is no id to have: Java 8 on Windows keeps the
		// child's handle and no way to learn its id, as `pid` documents. The
		// jvm's own getPid() answers -1 everywhere, Linux and Java 9 included.
		if (System.isWindows && Std.parseFloat(java.lang.System.getProperty("java.specification.version")) < 9) {
			Assert.equals(-1, pid);
			return;
		}
		#end
		Assert.isTrue(pid > 0, "the running child reported pid " + pid);
		#else
		Assert.pass();
		#end
	}

	/**
		A child with nothing to say does not stop the runtime while it runs.

		On hl a child's output is read, and its exit waited for, in natives that
		do not tell the collector the thread is waiting, and the collector stops
		every thread until each reaches a safe point. Unless those waits are
		marked, the first collection after the start would hold the whole
		runtime until the child spoke or ended: about five seconds between two
		ticks, for a child quiet for five seconds.
	**/
	public function testAQuietChildDoesNotStopTheRuntime():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);
		proc.start(getQuietInfo(2));

		var runtime = CrossByte.current();
		var garbage:Array<Bytes> = [];
		var last:Float = haxe.Timer.stamp();
		var longest:Float = 0.0;
		var deadline:Float = last + TIMEOUT;
		while (!exited && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			// Garbage enough that the collector runs while the child is quiet.
			for (_ in 0...10) {
				garbage.push(Bytes.alloc(100000));
			}
			if (garbage.length > 100) {
				garbage = [];
			}
			crossbyte.sys.System.sleep(0.001);
			var now:Float = haxe.Timer.stamp();
			if (now - last > longest) {
				longest = now - last;
			}
			last = now;
		}

		Assert.isTrue(exited, "the quiet child never exited");
		Assert.isTrue(longest < 1.0, "the runtime stopped for " + Math.round(longest * 1000) + " ms while the child said nothing");
		#else
		Assert.pass();
		#end
	}

	/**
		A character a read cuts in two arrives whole. Decoding each read of a
		child's output on its own would turn a UTF-8 character split across two
		(at a 4096-byte boundary, or wherever the pipe hands back less) into
		two replacement characters. Node decodes across reads already. Here the
		output arrives a byte per read.
	**/
	@:access(crossbyte.sys.NativeProcess)
	public function testACharacterSplitBetweenReadsArrivesWhole():Void {
		#if (sys && target.threaded && !eval && !hl)
		var expected:String = "aé€\u{1F600}b";
		var proc = new NativeProcess();
		var text:String = "";
		var closed = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> text += event.text);
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, _ -> closed = true);

		proc.__running = true;
		proc.__worker = new Worker();
		proc.__worker.addEventListener(crossbyte.events.ThreadEvent.PROGRESS, proc.__onWorkerProgress);
		proc.__worker.doWork = _ -> proc.__readStream(NativeProcess.STREAM_STDOUT, new ByteAtATime(Bytes.ofString(expected)));
		proc.__worker.run();

		pumpUntil(() -> closed, TIMEOUT);
		proc.__running = false;

		Assert.isTrue(closed);
		Assert.equals(expected, text);
		#else
		Assert.pass();
		#end
	}

	/**
		The worker that waited for a child survives the runtime dispatching
		the child's `EXIT` first, and the child is closed all the same.

		The worker sends its completion and then closes the child, and must
		not close it through the field `EXIT` clears: a runtime that got there
		first would leave the worker closing null, an access violation natively
		that the `try` around the close cannot catch, with the child's handles
		left for the collector to close. The test hook holds the worker at that
		moment until the runtime has dispatched `EXIT`.
	**/
	public function testAChildWhoseExitIsDispatchedFirstIsStillClosed():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		var dispatched = new sys.thread.Lock();
		var resumed:Bool = false;
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> {
			exited = true;
			dispatched.release();
		});
		@:privateAccess NativeProcess.__afterCompleteForTest = () -> {
			// Released from inside the EXIT listener; the runtime finishes
			// dispatching it a moment later.
			dispatched.wait(TIMEOUT);
			crossbyte.sys.System.sleep(0.1);
			resumed = true;
		};

		try {
			proc.start(getDefaultInfo());
			pumpUntil(() -> exited, TIMEOUT);
			// The worker goes on from where the hook held it, after EXIT, and
			// is given a moment to finish.
			waitUntil(() -> resumed, TIMEOUT);
			crossbyte.sys.System.sleep(0.5);
		} catch (error:Dynamic) {
			@:privateAccess NativeProcess.__afterCompleteForTest = null;
			throw error;
		}
		@:privateAccess NativeProcess.__afterCompleteForTest = null;

		Assert.isTrue(exited, "the child never exited");
		Assert.isTrue(resumed, "the worker never went on past its completion");
		#else
		Assert.pass();
		#end
	}

	/**
		A child writing faster than the runtime dispatches is held to at most
		`MAX_OUTPUT_AHEAD` bytes ahead of it; past that the child waits on its
		pipe, rather than its output being read as fast as it comes and queued
		without limit (here a 2 MB file, every byte of it waiting in this
		process while the runtime does not pump). All of it still arrives once
		the runtime does.
	**/
	public function testAChattyChildIsHeldToABoundedBacklog():Void {
		#if (sys && target.threaded && !eval)
		var path:String = haxe.io.Path.join([Sys.getCwd(), "nativeprocess-backlog-" + Std.random(1000000) + ".txt"]);
		var line:String = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopq\n";
		var buffer = new StringBuf();
		for (_ in 0...32768) {
			buffer.add(line);
		}
		var content:String = buffer.toString();
		sys.io.File.saveContent(path, content);

		var proc = new NativeProcess();
		var received:Int = 0;
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> received += event.text.length);
		var errors:String = "";
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, event -> errors += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);

		try {
			// The file written out exactly, by a program rather than a shell
			// builtin: hxcpp quotes each argument, and cmd.exe takes a quoted
			// "type" for a program it cannot find.
			proc.start(System.isWindows ? new NativeProcessStartupInfo("powershell.exe", [
				"-NoProfile",
				"-NonInteractive",
				"-Command",
				"[Console]::Out.Write([IO.File]::ReadAllText('" + path + "'))"
			]) : new NativeProcessStartupInfo("cat", [path]));
			// Not pumped: nothing is dispatched, so the readers can only queue.
			// Until the queue stops growing, as it does once the readers wait
			// or the child has written everything.
			var queued:Int = -1;
			var steady:Int = 0;
			var deadline:Float = haxe.Timer.stamp() + TIMEOUT;
			while (steady < 10 && haxe.Timer.stamp() < deadline) {
				crossbyte.sys.System.sleep(0.05);
				var now:Int = @:privateAccess proc.__worker.__outbox.length;
				steady = now == queued && now > 0 ? steady + 1 : 0;
				queued = now;
			}
			Assert.isTrue(queued > 0 && queued <= 72, queued + " pieces of output were queued ahead of the runtime");

			pumpUntil(() -> exited, TIMEOUT * 2);
			Assert.isTrue(exited, "the child never exited");
			Assert.equals(content.length, received, "not all of the output arrived: " + received + " of " + content.length + " bytes, exit code " + proc.exitCode + ", stderr " + errors);
		} catch (error:Dynamic) {
			try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
			throw error;
		}
		try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	public function testExitEventDispatchesOnOwningRuntimeTick():Void {
		#if (sys && target.threaded && !eval)
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var proc = new NativeProcess();
		var exited = false;
		var exitRuntime:CrossByte = null;

		proc.addEventListener(NativeProcessEvent.EXIT, _ -> {
			exited = true;
			exitRuntime = CrossByte.current();
		});

		proc.start(getDefaultInfo());
		waitUntil(() -> proc.exitCode == 0, TIMEOUT);

		primordial.pump(1 / 60, 0);
		Assert.isFalse(exited);

		pumpRuntimeUntil(child, () -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(child, exitRuntime);

		child.exit();
		#else
		Assert.pass();
		#end
	}

	// Asked of the machine rather than the compiler: hl and neko have no
	// `windows` define, and their bytecode runs on whichever OS it is given to.
	@:noCompletion private static function getDefaultInfo():NativeProcessStartupInfo {
		if (System.isWindows) {
			return new NativeProcessStartupInfo("cmd.exe", ["/C", "echo", "nativeprocess_smoke"]);
		}
		return new NativeProcessStartupInfo("sh", ["-c", "echo nativeprocess_smoke"]);
	}

	/** A child that prints nothing and ends after about `seconds`. **/
	@:noCompletion private static function getQuietInfo(seconds:Int):NativeProcessStartupInfo {
		if (System.isWindows) {
			return new NativeProcessStartupInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds " + seconds]);
		}
		return new NativeProcessStartupInfo("sh", ["-c", "sleep " + seconds]);
	}

	@:noCompletion private static function pumpUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		pumpRuntimeUntil(CrossByte.current(), predicate, timeoutSeconds);
	}

	@:noCompletion private static function pumpRuntimeUntil(runtime:CrossByte, predicate:Void->Bool, timeoutSeconds:Float):Void {
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!predicate() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	@:noCompletion private static function waitUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!predicate() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.001);
		}
	}

	@:noCompletion private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}

/** A child's output that arrives one byte per read, then ends. **/
private class ByteAtATime extends haxe.io.Input {
	private final source:Bytes;
	private var at:Int = 0;

	public function new(source:Bytes) {
		this.source = source;
	}

	override public function readByte():Int {
		if (at >= source.length) {
			throw new haxe.io.Eof();
		}
		return source.get(at++);
	}

	override public function readBytes(buffer:Bytes, pos:Int, len:Int):Int {
		if (at >= source.length) {
			throw new haxe.io.Eof();
		}
		buffer.set(pos, source.get(at++));
		return 1;
	}
}
