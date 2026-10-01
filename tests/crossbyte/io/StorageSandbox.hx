package crossbyte.io;

/**
	Points the application storage directory somewhere temporary while a
	test class runs, and takes it back afterwards.

	The directory is the application's own -- `%APPDATA%\<id>`, with the id
	the main class's name -- and is created the first time anything asks for
	it. Unsandboxed, a test run would leave one under the account's real
	application data per suite entry point: `TestMain`, `JvmTestMain`,
	`NativeSmokeMain` and the rest. A class that touches
	`File.applicationStorageDirectory` or opens a `Store` calls `enter` in
	`setupClass` and `leave` in `teardownClass`. Calls nest.

	Nothing to do in a browser, whose stores are IndexedDB's.
**/
@:access(crossbyte.sys.System)
class StorageSandbox {
	private static var __depth:Int = 0;
	private static var __savedPath:Null<String> = null;
	private static var __savedMade:Bool = false;
	private static var __root:Null<File> = null;

	/** Redirects the storage directory, and answers where it now is. **/
	public static function enter():Null<String> {
		#if (js && !nodejs)
		return null;
		#else
		if (__depth++ > 0) {
			return crossbyte.sys.System.__appStorageDirPath;
		}

		__savedPath = crossbyte.sys.System.__appStorageDirPath;
		__savedMade = crossbyte.sys.System.__appStorageDirMade;
		__root = File.createTempDirectory();

		var root:String = haxe.io.Path.removeTrailingSlashes(__root.nativePath);
		crossbyte.sys.System.__appStorageDirPath = root + File.separator + crossbyte.sys.System.applicationId;
		crossbyte.sys.System.__appStorageDirMade = false;
		return crossbyte.sys.System.__appStorageDirPath;
		#end
	}

	/** Puts the real directory back, and removes the temporary one. **/
	public static function leave():Void {
		#if !(js && !nodejs)
		if (__depth == 0 || --__depth > 0) {
			return;
		}

		crossbyte.sys.System.__appStorageDirPath = __savedPath;
		crossbyte.sys.System.__appStorageDirMade = __savedMade;

		if (__root != null) {
			try {
				__root.deleteDirectory(true);
			} catch (_:Dynamic) {}
			__root = null;
		}
		#end
	}
}
