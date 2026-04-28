package crossbyte.sys;

import crossbyte.io.File;
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

	public function testSystemDirectoryGettersStayDistinctAndCached():Void {
		var expectedUser = #if windows Sys.getEnv("USERPROFILE") #else Sys.getEnv("HOME") #end;
		var expectedDesktop = expectedUser + File.separator + "Desktop";
		var expectedDocuments = expectedUser + File.separator + "Documents";

		Assert.equals(Path.removeTrailingSlashes(Sys.getCwd()), System.appDir);
		Assert.equals(expectedUser, System.userDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.equals(expectedDesktop, System.desktopDir);
		Assert.equals(expectedDocuments, System.documentsDir);
		Assert.notEquals(System.desktopDir, System.documentsDir);

		#if windows
		Assert.equals(Sys.getEnv("APPDATA"), System.appStorageDir);
		#else
		Assert.equals(Sys.getEnv("HOME"), System.appStorageDir);
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
