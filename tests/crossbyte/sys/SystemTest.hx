package crossbyte.sys;

import crossbyte.io.File;
import crossbyte.io.StorageSandbox;
import crossbyte.io._internal.FilePath;
import utest.Assert;

/**
	Where an application's own files live: its name, its storage directory,
	and the directory it was started from.
**/
@:access(crossbyte.sys.System)
class SystemTest extends utest.Test {
	public function testTheApplicationIdIsTheMainClass():Void {
		// No -D crossbyte_app_id in the suites, so the id is the entry
		// point's class -- TestMain, JvmTestMain, NativeSmokeMain -- and that
		// class has the main the program started at.
		var id:String = System.applicationId;
		var main:Null<Class<Dynamic>> = Type.resolveClass(id);

		Assert.notNull(main, '"$id" is not a class of this program');
		if (main != null) {
			Assert.isTrue(Type.getClassFields(main).indexOf("main") >= 0, '"$id" has no static main');
		}
		Assert.isNull(crossbyte.io._internal.ApplicationIdentity.defined);
		// From the compiler, not from the program's file name, which only
		// matches it on eval -- TestMain.hx -- and is the jar's name on the
		// jvm. The main expression is a block there, the main call and the
		// event loop's, and the main call was looked for only on its own.
		Assert.equals(id, crossbyte.io._internal.ApplicationIdentity.mainClass());
	}

	public function testEachPlatformKeepsDataWhereItsConventionSays():Void {
		// Each rule asked of an environment of the test's own, so every
		// platform's is checked on whichever one runs it.
		function env(values:Map<String, String>):String->Null<String> {
			return name -> values.get(name);
		}

		Assert.equals("C:\\Users\\u\\AppData\\Roaming", System.__storageBase("windows", env(["APPDATA" => "C:\\Users\\u\\AppData\\Roaming", "HOME" => "/c/Users/u"])));
		// A service whose profile sets no APPDATA still has the profile.
		Assert.equals("C:\\Users\\u\\AppData\\Roaming", System.__storageBase("windows", env(["USERPROFILE" => "C:\\Users\\u\\"])));
		Assert.isNull(System.__storageBase("windows", env(["HOME" => "/c/Users/u"])));

		Assert.equals("/Users/u/Library/Application Support", System.__storageBase("mac", env(["HOME" => "/Users/u"])));
		Assert.isNull(System.__storageBase("mac", env([])));

		Assert.equals("/home/u/.local/share", System.__storageBase("linux", env(["HOME" => "/home/u"])));
		Assert.equals("/data/xdg", System.__storageBase("linux", env(["HOME" => "/home/u", "XDG_DATA_HOME" => "/data/xdg"])));
		// A relative XDG_DATA_HOME is invalid, and ignored as the spec says.
		Assert.equals("/home/u/.local/share", System.__storageBase("linux", env(["HOME" => "/home/u", "XDG_DATA_HOME" => "data"])));
		// A daemon with no HOME has no storage directory, rather than one
		// called "null" in whatever directory it was started from.
		Assert.isNull(System.__storageBase("linux", env([])));
		Assert.isNull(System.__storageBase("freebsd", env(["HOME" => " "])));
	}

	public function testTheStorageDirectoryIsTheApplicationsOwn():Void {
		// It was the account's root -- %APPDATA% or $HOME itself -- shared by
		// every CrossByte program, so their stores of one name were one store.
		var path:String = System.__storagePath();
		var base:Null<String> = System.__storageBase(System.PLATFORM, Sys.getEnv);

		Assert.notNull(base);
		Assert.equals(haxe.io.Path.removeTrailingSlashes(base) + File.separator + System.applicationId, path);
		Assert.notEquals(haxe.io.Path.removeTrailingSlashes(base), haxe.io.Path.removeTrailingSlashes(path));
		Assert.notEquals(Sys.getEnv("HOME"), path);
	}

	public function testTheStorageDirectoryIsCreatedOnFirstAccess():Void {
		// AIR's promise, which nothing kept: the account root it used to be
		// existed anyway. Somewhere temporary, so the run leaves nothing in
		// the account's application data.
		var temp:File = File.createTempDirectory();
		var where:String = haxe.io.Path.removeTrailingSlashes(temp.nativePath) + File.separator + "not-yet" + File.separator
			+ System.applicationId;
		var savedPath = System.__appStorageDirPath;
		var savedMade = System.__appStorageDirMade;

		System.__appStorageDirPath = where;
		System.__appStorageDirMade = false;

		try {
			Assert.isFalse(sys.FileSystem.exists(where));
			Assert.equals(where, File.applicationStorageDirectory.nativePath);
			Assert.isTrue(sys.FileSystem.exists(where) && sys.FileSystem.isDirectory(where));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		System.__appStorageDirPath = savedPath;
		System.__appStorageDirMade = savedMade;
		try temp.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testAStoreLivesInTheApplicationsDirectory():Void {
		var storage:Null<String> = StorageSandbox.enter();

		try {
			var opened:crossbyte.io.Store = null;
			// Synchronous underneath on every target with a file system.
			crossbyte.io.Store.open("system-test-placement").then(store -> opened = store, error -> Assert.fail(error));

			Assert.notNull(opened);
			Assert.isTrue(sys.FileSystem.isDirectory(haxe.io.Path.join([storage, "stores", "system-test-placement"])));

			if (opened != null) {
				opened.close();
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		StorageSandbox.leave();
	}

	#if eval
	/**
		What the build decides, checked by building: a small program from
		tests/fixtures/appid, compiled and run three times. Once only, on the
		interpreter -- the choice is the compiler's, the same for every
		target, and each target's reading of it is the case above.
	**/
	public function testTheIdIsChosenWhenTheApplicationIsBuilt():Void {
		// tests/TestMain.hx, on the interpreter: the repository is above it.
		var root:String = haxe.io.Path.directory(haxe.io.Path.directory(Sys.programPath()));

		function build(defines:Array<String>):{code:Int, output:String} {
			var args:Array<String> = ["--cwd", root, "-cp", "src", "-cp", "tests/fixtures/appid", "-main", "ProgramMain", "--interp"].concat(defines);
			var process = new sys.io.Process("haxe", args);
			var output:String = process.stdout.readAll().toString() + process.stderr.readAll().toString();
			var code:Int = process.exitCode();
			process.close();
			return {code: code, output: output};
		}

		// Aedifex starts every application at a ProgramMain of its own. Its
		// main class was the id, so every application it built had one name
		// and one storage directory; the class ProgramMain starts is meant.
		var aedifex = build([]);
		Assert.equals(0, aedifex.code, aedifex.output);
		Assert.isTrue(aedifex.output.indexOf("applicationId=example.AppIdProbe") >= 0, aedifex.output);

		var named = build(["-D", "crossbyte_app_id=com.example.chat"]);
		Assert.equals(0, named.code, named.output);
		Assert.isTrue(named.output.indexOf("applicationId=com.example.chat") >= 0, named.output);

		// A name that is not a directory's is a build error, not a path.
		var refused = build(["-D", "crossbyte_app_id=../escape"]);
		Assert.notEquals(0, refused.code, refused.output);
		Assert.isTrue(refused.output.indexOf("cannot name a directory") >= 0, refused.output);
	}
	#end

	public function testTheApplicationDirectoryIsTheProgramsOwn():Void {
		// It was the working directory: a Windows service, started in
		// System32, looked for its files there. The suites start their
		// programs from the repository and keep them in export/, so the two
		// differ here except natively, where the runner starts the program
		// in its own directory -- which is why the working directory is
		// moved below as well.
		#if eval
		// No program file on the interpreter: the directory the compiler ran in.
		Assert.equals(haxe.io.Path.removeTrailingSlashes(Sys.getCwd()), System.appDir);
		#else
		var program:String = sys.FileSystem.absolutePath(Sys.programPath());
		var expected:String = haxe.io.Path.removeTrailingSlashes(FilePath.normalize(haxe.io.Path.directory(program), System.isWindows));

		Assert.equals(expected, haxe.io.Path.removeTrailingSlashes(System.appDir));
		Assert.equals(expected, haxe.io.Path.removeTrailingSlashes(File.applicationDirectory.nativePath));

		#if !(java || jvm)
		// Not on the jvm, which cannot change its working directory -- and
		// whose jar is never in it here, so the assertions above decide.
		var savedCwd:String = Sys.getCwd();
		var savedDir:String = System.__appDirPath;
		var elsewhere:File = File.createTempDirectory();

		try {
			System.__appDirPath = null;
			Sys.setCwd(elsewhere.nativePath);
			Assert.equals(expected, haxe.io.Path.removeTrailingSlashes(System.appDir), "it followed the working directory");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		Sys.setCwd(savedCwd);
		System.__appDirPath = savedDir;
		try elsewhere.deleteDirectory(true) catch (_:Dynamic) {}
		#end
		#end

		// Resources are read from beside it.
		Assert.equals(haxe.io.Path.removeTrailingSlashes(System.appDir) + File.separator + "resources" + File.separator,
			crossbyte.Resources.resourcesDir);
	}

	public function testXdgUserDirsAreRead():Void {
		// File.documentsDirectory says it observes xdg-user-dirs on Linux,
		// which nothing read: ~/Documents, whatever the desktop's language or
		// the user's choice.
		var file:String = '# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR="$$HOME/Schreibtisch"\nXDG_DOCUMENTS_DIR="/data/docs/"\nXDG_MUSIC_DIR="$$HOME"\n';

		Assert.equals("/home/u/Schreibtisch", System.__parseUserDirs(file, "XDG_DESKTOP_DIR", "/home/u"));
		Assert.equals("/data/docs", System.__parseUserDirs(file, "XDG_DOCUMENTS_DIR", "/home/u/"));
		Assert.equals("/home/u", System.__parseUserDirs(file, "XDG_MUSIC_DIR", "/home/u"));
		Assert.isNull(System.__parseUserDirs(file, "XDG_VIDEOS_DIR", "/home/u"));
		Assert.isNull(System.__parseUserDirs('XDG_DESKTOP_DIR="relative"', "XDG_DESKTOP_DIR", "/home/u"));
		Assert.isNull(System.__parseUserDirs('#XDG_DESKTOP_DIR="/x"', "XDG_DESKTOP_DIR", "/home/u"));
	}

	public function testDocumentsAndDesktopFollowXdgUserDirs():Void {
		// End to end, through a user-dirs.dirs where XDG_CONFIG_HOME points.
		// Linux and the BSDs read it; Windows and macOS keep folders of their
		// own and do not.
		#if (jvm || java)
		// Sys.putEnv throws on the jvm. testXdgUserDirsAreRead covers the
		// reading there.
		Assert.pass();
		#else
		var config = File.createTempDirectory();
		var saved:Null<String> = Sys.getEnv("XDG_CONFIG_HOME");
		sys.io.File.saveContent(config.resolvePath("user-dirs.dirs").nativePath,
			'XDG_DOCUMENTS_DIR="/srv/papers"\nXDG_DESKTOP_DIR="$$HOME/Schreibtisch"\n');
		Sys.putEnv("XDG_CONFIG_HOME", config.nativePath);
		System.__documentsDirPath = null;
		System.__desktopDirPath = null;
		var documents:String = System.documentsDir;
		var desktop:String = System.desktopDir;
		__restoreEnv("XDG_CONFIG_HOME", saved);
		System.__documentsDirPath = null;
		System.__desktopDirPath = null;
		try config.deleteDirectory(true) catch (_:Dynamic) {}

		var home:String = System.userDir;

		if (System.isWindows || System.PLATFORM == "mac") {
			Assert.equals(home + File.separator + "Documents", documents);
			Assert.equals(home + File.separator + "Desktop", desktop);
		} else {
			Assert.equals("/srv/papers", documents);
			Assert.equals(haxe.io.Path.removeTrailingSlashes(home) + "/Schreibtisch", desktop);
		}
		#end
	}

	public function testTotalCpuUsageMeasuresTheProcess():Void {
		// It returned 0, busy or idle.
		#if (js && !nodejs)
		Assert.raises(() -> System.totalCpuUsage(), crossbyte.errors.IllegalOperationError);
		#else
		System.totalCpuUsage();
		var started:Float = haxe.Timer.stamp();
		var sum:Float = 0.0;

		while (haxe.Timer.stamp() - started < 0.3) {
			for (i in 0...10000) {
				sum += Math.sqrt(i);
			}
		}

		var busy:Float = System.totalCpuUsage();
		Assert.isFalse(Math.isNaN(sum));
		Assert.isTrue(busy > 0, 'busy for 0.3 s, the process read $busy%');
		Assert.isTrue(busy <= 100, 'read $busy%');
		#end
	}

	public function testAffinityIsNativeOnWindowsAndLinuxAndRefusedElsewhere():Void {
		// Off native it answered [false] -- no processor usable -- and false
		// to every question; natively on macOS, [] and false.
		#if cpp
		if (System.isWindows || System.PLATFORM == "linux") {
			var mask:Array<Bool> = System.processAffinity;
			Assert.equals(System.processorCount, mask.length);
			Assert.equals(mask[0], System.hasProcessAffinity(0));
			// The native calls shift a bit by the index: past the mask that
			// was undefined behaviour.
			Assert.raises(() -> System.hasProcessAffinity(-1), crossbyte.errors.RangeError);
			Assert.raises(() -> System.hasProcessAffinity(System.processorCount), crossbyte.errors.RangeError);
			Assert.raises(() -> System.setProcessAffinity(System.processorCount, true), crossbyte.errors.RangeError);
			// Asking for what the process has already changes nothing, and
			// is accepted.
			Assert.isTrue(System.setProcessAffinity(0, mask[0]));
			Assert.same(mask, System.processAffinity);
			return;
		}
		#end
		Assert.raises(() -> {
			var mask = System.processAffinity;
		}, crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> System.hasProcessAffinity(0), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> System.setProcessAffinity(0, true), crossbyte.errors.IllegalOperationError);
	}

	public function testTheDeviceIdIsTheMachines():Void {
		// It was "" everywhere but native, and null natively on Linux and
		// macOS.
		var id:Null<String> = System.getDeviceId();
		Assert.equals(id, System.getDeviceId());
		#if (js && !nodejs)
		Assert.isNull(id);
		#else
		if (System.isWindows || System.PLATFORM == "mac") {
			var uuid:EReg = ~/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
			Assert.isTrue(id != null && uuid.match(id), 'device id "$id"');
		} else if (sys.FileSystem.exists("/etc/machine-id")) {
			Assert.equals(StringTools.trim(sys.io.File.getContent("/etc/machine-id")), id);
		} else {
			Assert.pass();
		}

		if (System.isWindows) {
			// The native build reads the registry itself; the others ask
			// reg.exe. One machine, one answer.
			var viaReg:Null<String> = System.__parseMachineGuid(System.__programOutput("reg",
				["query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid", "/reg:64"]));
			Assert.equals(viaReg, id);
		}
		#end
	}

	public function testDeviceIdOutputsAreRead():Void {
		var reg:String = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d\r\n\r\n";
		Assert.equals("1B2C3D4E-5F60-4A7B-8C9D-0E1F2A3B4C5D", System.__parseMachineGuid(reg));
		Assert.equals("1B2C3D4E-5F60-4A7B-8C9D-0E1F2A3B4C5D", System.__parseMachineGuid("MachineGuid REG_SZ {1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d}"));
		Assert.isNull(System.__parseMachineGuid("ERROR: The system was unable to find the specified registry key or value."));
		Assert.isNull(System.__parseMachineGuid(null));

		var ioreg:String = '+-o Mac14,2  <class IOPlatformExpertDevice, id 0x100000201, registered, matched, active, busy 0 (13 ms), retain 39>\n'
			+ '    {\n      "IOPlatformSerialNumber" = "C02XX0XXXX00"\n      "IOPlatformUUID" = "564D8A1B-2C3D-4E5F-8A9B-0C1D2E3F4A5B"\n    }\n';
		Assert.equals("564D8A1B-2C3D-4E5F-8A9B-0C1D2E3F4A5B", System.__parseIoregUuid(ioreg));
		Assert.isNull(System.__parseIoregUuid("no platform device here"));
		Assert.isNull(System.__parseIoregUuid(null));
	}

	public function testSystemMemoryIsAskedOfTheSystem():Void {
		// Each figure started a process -- wmic on Windows, natively and on
		// the jvm too, grep on Linux -- and macOS answered 0.
		var started:Float = haxe.Timer.stamp();
		var total:Float = System.totalSystemMemory();
		var free:Float = System.freeSystemMemory();
		var took:Float = haxe.Timer.stamp() - started;
		Assert.isTrue(total > 64 * 1024 * 1024, 'total $total');
		Assert.isTrue(free > 0 && free <= total, 'free $free of $total');
		#if (cpp || jvm || java || nodejs)
		// Asked directly. Through wmic the two took 0.2 s and more on
		// Windows; the jvm's first answer now takes 4 ms. Natively on macOS
		// too, where sysctl and vm_stat took 0.11 s; the jvm still runs them.
		var direct:Bool = #if (jvm || java) System.PLATFORM != "mac" #else true #end;
		if (direct) {
			Assert.isTrue(took < 0.1, 'the two figures took $took s');
		}
		#end
		#if !nodejs
		if (System.PLATFORM == "linux") {
			Assert.equals(System.__parseMeminfo(System.__readProcFile("/proc/meminfo"), "MemTotal"), total);
		}
		#end
	}

	public function testMemoryOutputsAreRead():Void {
		var meminfo:String = "MemTotal:       16314616 kB\nMemFree:          301212 kB\nMemAvailable:    9876543 kB\n";
		Assert.equals(16314616.0 * 1024, System.__parseMeminfo(meminfo, "MemTotal"));
		Assert.equals(9876543.0 * 1024, System.__parseMeminfo(meminfo, "MemAvailable"));
		Assert.equals(-1.0, System.__parseMeminfo("MemTotal: 1 kB\n", "MemAvailable"));

		var vmStat:String = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               10000.\n"
			+ "Pages active:                            200000.\nPages inactive:                           30000.\n"
			+ "Pages speculative:                         4000.\nPages throttled:                              0.\n";
		Assert.equals((10000.0 + 30000.0 + 4000.0) * 16384.0, System.__parseVmStat(vmStat));
		Assert.equals(-1.0, System.__parseVmStat("nothing"));
		Assert.equals(-1.0, System.__parseVmStat(null));

		Assert.equals(68530098176.0, System.__parseFirstNumber("TotalPhysicalMemory  \r\r\n68530098176  \r\r\n\r\r\n"));
		Assert.isNull(System.__parseFirstNumber("FreePhysicalMemory  \r\r\n"));
		Assert.isNull(System.__parseFirstNumber(null));
	}

	#if !(jvm || java)
	static function __restoreEnv(name:String, value:Null<String>):Void {
		#if nodejs
		// Node's putEnv stores null as the text "null".
		if (value == null) {
			js.Syntax.code("delete process.env[{0}]", name);
			return;
		}
		#end
		#if neko
		// neko's put_env throws for null on Windows, where setting a variable
		// to nothing is how it is removed.
		if (value == null && System.isWindows) {
			Sys.putEnv(name, "");
			return;
		}
		#end
		Sys.putEnv(name, value);
	}
	#end

	public function testAnIdTheBuildRefuses():Void {
		// What -D crossbyte_app_id is held to: a name every platform can give
		// a directory.
		for (good in ["com.example.chat", "MyApp", "my app 2", "a_b-c"]) {
			Assert.isNull(FilePath.portableNameProblem(good), good);
		}

		for (bad in ["", "../escape", "a/b", "a\\b", "C:", ".hidden", "trailing.", "trailing ", "what?", "tab\there"]) {
			Assert.notNull(FilePath.portableNameProblem(bad), bad);
		}
	}
}
