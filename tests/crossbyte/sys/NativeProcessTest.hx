package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.NativeProcessEvent;
import utest.Assert;

class NativeProcessTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (sys && (windows || linux || mac || macos))
		Assert.isTrue(NativeProcess.isSupported);
		#else
		Assert.isFalse(NativeProcess.isSupported);
		#end
	}

	public function testStartThrowsWhenUnsupported():Void {
		#if (sys && (windows || linux || mac || macos))
		Assert.pass();
		#else
		var proc = new NativeProcess();
		Assert.isTrue(throws(function() {
			proc.start(new NativeProcessStartupInfo("echo"));
		}));
		#end
	}

	public function testStartEmitEventsAndExitCode():Void {
		#if (sys && (windows || linux || mac || macos))
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

		pumpUntil(() -> exited, 3.0);

		Assert.isTrue(exited);
		Assert.equals(0, exitCode);
		Assert.isTrue(stdoutClosed);
		Assert.isTrue(stderrClosed);
		Assert.notNull(output);
		Assert.isTrue(output.indexOf("nativeprocess_smoke") >= 0);
		#else
		Assert.pass();
		#end
	}

	@:noCompletion private static function getDefaultInfo():NativeProcessStartupInfo {
		#if windows
		return new NativeProcessStartupInfo("cmd", ["/C", "echo nativeprocess_smoke"]);
		#else
		return new NativeProcessStartupInfo("sh", ["-c", "echo nativeprocess_smoke"]);
		#end
	}

	@:noCompletion private static function pumpUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeoutSeconds;
		while (!predicate() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0.0);
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
