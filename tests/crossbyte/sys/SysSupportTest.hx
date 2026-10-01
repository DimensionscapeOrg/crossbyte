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
		// Node, so on Windows those three answered every platform question
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
		// not fail, and any tool that rewrote the file flipped them
		// invisibly, because .gitattributes normalises endings so a diff
		// shows nothing.
		Assert.equals(System.isWindows ? "\r\n" : "\n", File.lineEnding);
	}

	public function testTheStorageDirectoryDoesNotDependOnHOME():Void {
		// This is where Store keeps its files. Under Windows the old
		// conditional was false on Node, so it read HOME: the profile root
		// when Git Bash had set it, a different location than a native build
		// uses, for the same data, and null when nothing had, which reached
		// callers as a relative directory named "undefined".
		//
		// The path, not the directory: asking for appStorageDir creates it, and
		// this run would leave one in the account's application data.
		var storage:String = @:privateAccess System.__storagePath();

		Assert.notNull(storage);
		Assert.notEquals("", storage);
		Assert.notEquals("undefined", storage);
		Assert.notEquals("null", storage);

		if (System.isWindows) {
			// The application's own directory inside it; SystemTest says why.
			Assert.equals(Sys.getEnv("APPDATA") + "\\" + System.applicationId, storage);
			Assert.notEquals(Sys.getEnv("USERPROFILE"), storage, "storage fell back to the profile root");
		}
	}

	public function testSystemDirectoryGettersStayDistinctAndCached():Void {
		// Runtime, like the code under test. This assertion used `#if windows`
		// too, so on eval, which does not set that define even on Windows,
		// it expected HOME and got HOME, and the two were wrong together. A
		// test that reproduces the bug it is checking for cannot see it.
		var expectedUser = System.isWindows ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
		// Linux's xdg-user-dirs when the user has one; SystemTest reads it.
		var xdgDesktop:Null<String> = @:privateAccess System.__xdgUserDir("XDG_DESKTOP_DIR");
		var xdgDocuments:Null<String> = @:privateAccess System.__xdgUserDir("XDG_DOCUMENTS_DIR");
		var expectedDesktop = xdgDesktop != null ? xdgDesktop : expectedUser + File.separator + "Desktop";
		var expectedDocuments = xdgDocuments != null ? xdgDocuments : expectedUser + File.separator + "Documents";

		// The program's own directory, not the working directory; SystemTest
		// checks which.
		Assert.equals(System.appDir, System.appDir);
		Assert.equals(expectedUser, System.userDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.notEquals(System.desktopDir, System.documentsDir);

		// Cached, and the application's own: SystemTest checks the rule.
		Assert.equals(@:privateAccess System.__storagePath(), @:privateAccess System.__storagePath());
		Assert.isTrue(StringTools.endsWith(@:privateAccess System.__storagePath(), File.separator + System.applicationId));
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
		// macOS has no process-level affinity, there is no
		// sched_setaffinity, and thread_policy_set is a per-thread hint the
		// scheduler may ignore, and says so: an empty mask read as "no
		// processor usable".
		Assert.raises(() -> {
			var mask = System.processAffinity;
		}, crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> System.hasProcessAffinity(0), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> System.setProcessAffinity(0, true), crossbyte.errors.IllegalOperationError);
		#else
		Assert.pass();
		#end
	}

	public function testSystemFallbackPropertiesStaySafeOnNonCppTargets():Void {
		// Every target reports at least one processor. It was 0 everywhere but
		// native, and a TaskPool sized by it threw.
		Assert.isTrue(System.processorCount >= 1, "processorCount is " + System.processorCount);
		#if cpp
		Assert.notNull(System.processAffinity);
		Assert.isTrue(System.processAffinity.length >= 0);
		// The collector's 64-bit figure: the 32-bit one wrapped past 2GiB.
		Assert.isTrue(System.memoryUsage() > 0, "memoryUsage is " + System.memoryUsage());
		#else
		// Affinity is refused off native, and SystemTest checks the device
		// id: these pinned the placeholders, [false] and "".
		Assert.raises(() -> {
			var mask = System.processAffinity;
		}, crossbyte.errors.IllegalOperationError);
		#if (java || jvm || nodejs)
		// It was 0 everywhere but native.
		Assert.isTrue(System.memoryUsage() > 0, "memoryUsage is " + System.memoryUsage());
		#else
		Assert.equals(0.0, System.memoryUsage());
		#end
		Assert.raises(() -> System.hasProcessAffinity(0), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> System.setProcessAffinity(0, true), crossbyte.errors.IllegalOperationError);
		#end
	}
}
