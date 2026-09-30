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

	// hl and neko with no OS define: their bytecode runs on any OS and their
	// process API with it, so nothing names one and none is needed.
	public function testSupportFlagMatchesTarget():Void {
		#if (nodejs || hl || neko || (sys && (windows || linux || mac || macos)))
		Assert.isTrue(NativeProcess.isSupported);
		#else
		Assert.isFalse(NativeProcess.isSupported);
		#end
	}

	public function testStartThrowsWhenUnsupported():Void {
		#if (hl || neko || (sys && (windows || linux || mac || macos)))
		Assert.pass();
		#else
		var proc = new NativeProcess();
		Assert.isTrue(throws(function() {
			proc.start(new NativeProcessStartupInfo("echo"));
		}));
		#end
	}

	public function testStartEmitEventsAndExitCode():Void {
		#if (hl || neko || (sys && (windows || linux || mac || macos)))
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

		It read -1 on every target that runs the child on a thread, cpp
		included: the id was looked up as a `pid` field, by reflection, and no
		target's `sys.io.Process` has one, they all have `getPid()`.
	**/
	public function testThePidIsTheChilds():Void {
		#if (hl || neko || (sys && (windows || linux || mac || macos)))
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

		Assert.isTrue(pid > 0, "the running child reported pid " + pid);
		Assert.isTrue(exited);
		Assert.equals(pid, exitPid);
		#else
		Assert.pass();
		#end
	}

	/**
		A child with nothing to say does not stop the runtime while it runs.

		On hl its output was read, and its exit waited for, in natives that do
		not tell the collector the thread is waiting, and the collector stops
		every thread until each reaches a safe point. The first collection
		after the start held the whole runtime until the child spoke or ended:
		5,212 ms between two ticks, for a child quiet for five seconds.
	**/
	public function testAQuietChildDoesNotStopTheRuntime():Void {
		#if (hl || neko || (sys && (windows || linux || mac || macos)))
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
			Sys.sleep(0.001);
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

	public function testExitEventDispatchesOnOwningRuntimeTick():Void {
		#if (hl || neko || (sys && (windows || linux || mac || macos)))
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
			return new NativeProcessStartupInfo("cmd.exe", ["/C echo nativeprocess_smoke"]);
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
		var deadline = Sys.time() + timeoutSeconds;
		while (!predicate() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0.0);
			Sys.sleep(0.001);
		}
	}

	@:noCompletion private static function waitUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		var deadline = Sys.time() + timeoutSeconds;
		while (!predicate() && Sys.time() < deadline) {
			Sys.sleep(0.001);
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
