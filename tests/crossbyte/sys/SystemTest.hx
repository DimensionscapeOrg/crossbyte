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
		// point's class, TestMain, JvmTestMain, NativeSmokeMain, and that
		// class has the main the program started at.
		var id:String = System.applicationId;
		var main:Null<Class<Dynamic>> = Type.resolveClass(id);

		Assert.notNull(main, '"$id" is not a class of this program');
		if (main != null) {
			Assert.isTrue(Type.getClassFields(main).indexOf("main") >= 0, '"$id" has no static main');
		}
		Assert.isNull(crossbyte.io._internal.ApplicationIdentity.defined);
		// From the compiler, not from the program's file name, which only
		// matches it on eval, TestMain.hx, and is the jar's name on the
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
		// It was the account's root, %APPDATA% or $HOME itself, shared by
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
		interpreter, the choice is the compiler's, the same for every
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
