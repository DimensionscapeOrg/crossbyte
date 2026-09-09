package crossbyte.sys;

import crossbyte.io.File;
import crossbyte.sys.System;
import haxe.io.Path;
import utest.Assert;

class SysSupportTest extends utest.Test {
	public function testNativeProcessStartupInfoDefaultsArguments():Void {
		var info = new NativeProcessStartupInfo("tool.exe");
		Assert.equals("tool.exe", info.executable);
		Assert.notNull(info.arguments);
		Assert.equals(0, info.arguments.length);

		info.arguments.push("--flag");
		Assert.equals(1, info.arguments.length);

		var explicit = new NativeProcessStartupInfo("tool.exe", ["a", "b"]);
		Assert.equals(2, explicit.arguments.length);
		Assert.equals("a", explicit.arguments[0]);
		Assert.equals("b", explicit.arguments[1]);
	}

	public function testTaskAndWorkerStatesExposeExpectedConstructors():Void {
		Assert.equals("PENDING", Type.enumConstructor(TaskState.PENDING));
		Assert.equals("RUNNING", Type.enumConstructor(TaskState.RUNNING));
		Assert.equals("COMPLETED", Type.enumConstructor(TaskState.COMPLETED));
		Assert.equals("FAILED", Type.enumConstructor(TaskState.FAILED));
		Assert.equals("CANCELLED", Type.enumConstructor(TaskState.CANCELLED));

		Assert.equals("IDLE", Type.enumConstructor(WorkerState.IDLE));
		Assert.equals("RUNNING", Type.enumConstructor(WorkerState.RUNNING));
		Assert.equals("COMPLETED", Type.enumConstructor(WorkerState.COMPLETED));
		Assert.equals("FAILED", Type.enumConstructor(WorkerState.FAILED));
		Assert.equals("CANCELLED", Type.enumConstructor(WorkerState.CANCELLED));
	}

	public function testThePlatformIsIdentifiedAtRuntimeAndNotByTheCompiler():Void {
		// `#if windows` names the target the compiler was aimed at. Haxe sets
		// it for cpp, hl and neko and does not set it for eval, the JVM or
		// Node -- so on Windows those three answered every platform question
		// with the branch written for POSIX. It was invisible because the
		// tests asked the same broken way.
		//
		// "undefined" is the old System.PLATFORM's signature on exactly those
		// targets, and the only value that cannot be right anywhere.
		Assert.notEquals("undefined", System.PLATFORM);
		Assert.equals(System.PLATFORM == "windows", System.isWindows);
		Assert.equals(Sys.systemName() == "Windows", System.isWindows);

		// Derived from the same question, and wrong in the same places: File
		// joins every path it builds on this, so on eval and Node under
		// Windows it produced forward slashes against an OS handing it
		// backslashes.
		Assert.equals(System.isWindows ? "\\" : "/", File.separator);
		// Escapes, not newlines typed inside the quotes. Written the second
		// way each branch is whatever line ending this file happens to be
		// saved with, so both sides always agreed and the assertion could
		// not fail -- and any tool that rewrote the file flipped them
		// invisibly, because .gitattributes normalises endings so a diff
		// shows nothing.
		Assert.equals(System.isWindows ? "\r\n" : "\n", File.lineEnding);
	}

	public function testTheStorageDirectoryDoesNotDependOnHOME():Void {
		// This is where Store keeps its files. Under Windows the old
		// conditional was false on Node, so it read HOME: the profile root
		// when Git Bash had set it -- a different location than a native build
		// uses, for the same data -- and null when nothing had, which reached
		// callers as a relative directory named "undefined".
		var storage:String = System.appStorageDir;

		Assert.notNull(storage);
		Assert.notEquals("", storage);
		Assert.notEquals("undefined", storage);
		Assert.notEquals("null", storage);

		if (System.isWindows) {
			Assert.equals(Sys.getEnv("APPDATA"), storage);
			Assert.notEquals(Sys.getEnv("USERPROFILE"), storage, "storage fell back to the profile root");
		}
	}

	public function testSystemDirectoryGettersStayDistinctAndCached():Void {
		// Runtime, like the code under test. This assertion used `#if windows`
		// too, so on eval -- which does not set that define even on Windows --
		// it expected HOME and got HOME, and the two were wrong together. A
		// test that reproduces the bug it is checking for cannot see it.
		var expectedUser = System.isWindows ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
		var expectedDesktop = expectedUser + File.separator + "Desktop";
		var expectedDocuments = expectedUser + File.separator + "Documents";

		Assert.equals(Path.removeTrailingSlashes(Sys.getCwd()), System.appDir);
		Assert.equals(expectedUser, System.userDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.notEquals(System.desktopDir, System.documentsDir);

		Assert.equals(System.isWindows ? Sys.getEnv("APPDATA") : Sys.getEnv("HOME"), System.appStorageDir);
	}

	public function testProcessorCountIsAnswerableOnEverySupportedNativePlatform():Void {
		#if (cpp && (windows || linux || mac || macos))
		// Zero means the query fell through to the dispatcher's default rather
		// than reaching a platform that can answer it, which is what macOS did
		// before it had an implementation of its own.
		Assert.isTrue(System.processorCount >= 1, "expected at least one processor, got " + System.processorCount);
		#else
		Assert.pass();
		#end
	}

	public function testAffinityReportsWhatThePlatformCanActuallyDo():Void {
		#if (cpp && (windows || linux))
		// Where affinity exists, the mask describes the processors that exist.
		var affinity:Array<Bool> = System.processAffinity;
		Assert.notNull(affinity);
		Assert.equals(System.processorCount, affinity.length);
		#elseif (cpp && (mac || macos))
		// macOS has no process-level affinity to report -- there is no
		// sched_setaffinity, and thread_policy_set is a per-thread hint the
		// scheduler may ignore. The empty mask is the honest answer, and these
		// are pinned so that implementing it later has to be a deliberate
		// change to the contract rather than an accident.
		Assert.equals(0, System.processAffinity.length);
		Assert.isFalse(System.hasProcessAffinity(0));
		Assert.isFalse(System.setProcessAffinity(0, true));
		#else
		Assert.pass();
		#end
	}

	public function testSystemFallbackPropertiesStaySafeOnNonCppTargets():Void {
		#if cpp
		Assert.isTrue(System.processorCount >= 0);
		Assert.notNull(System.processAffinity);
		Assert.isTrue(System.processAffinity.length >= 0);
		#else
		Assert.equals(0, System.processorCount);
		Assert.same([false], System.processAffinity);
		Assert.equals("", System.getDeviceId());
		Assert.equals(0, System.memoryUsage());
		Assert.isFalse(System.hasProcessAffinity(0));
		Assert.isFalse(System.setProcessAffinity(0, true));
		#end
	}
}
