package crossbyte.io;

import crossbyte.events.EventDispatcher;
import crossbyte.events.ThreadEvent;
import haxe.io.Path;
import crossbyte.sys.System;
import crossbyte.sys.Worker;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.Error;
import crossbyte.errors.IOError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.FileListEvent;
import crossbyte.io._internal.FileOps;
import crossbyte.io._internal.FilePath;
#if (js && !nodejs)
// No filesystem here. The class keeps its type and its API; the calls
// refuse. See NoFileSystem for why this is a shim and not a stubbed class.
import crossbyte.io._internal.NoFileSystem as FileSystem;
import crossbyte.io._internal.NoFileSystem as HaxeFile;
#else
import sys.FileSystem;
import sys.io.File as HaxeFile;
import sys.io.Process;
#end
import haxe.io.Bytes;

// @:noCompletion private typedef HaxeFile = sys.io.File;
/**
	A File object represents a path to a file or directory. This can be an existing file
	or directory, or it can be one that does not yet exist; for instance, it can represent
	the path to a file or directory that you plan to create.

	The File class has a number of properties and methods for getting information about the
	file system and for performing operations, such as copying files and directories.

	You can use File objects along with the FileStream class to read and write files.

	The File class includes static properties that let you reference commonly used directory
	locations. These static properties include:

	* File.applicationStorageDirectory, a storage directory unique to each installed	application
	* File.applicationDirectory, the read-only directory where the application is installed
	(along with any installed assets)
	* File.desktopDirectory, the user's desktop directory
	* File.documentsDirectory, the user's documents directory
	* File.userDirectory, the user directory

	These properties have meaningful values on different operating systems. For example,
	Mac OS, Linux, and Windows each have different native paths to the user's desktop directory.
	However, the File.desktopDirectory property points to the correct desktop directory path
	on each of these platforms. To write applications that work well across platforms, use these
	properties as the basis for referencing other files used by the application. Then use the
	resolvePath() method to refine the path. For example, this code points to the preferences.xml
	file in the application storage directory:

	```hx
		var prefsFile:File = File.applicationStorageDirectory;
		prefsFile = prefsFile.resolvePath("preferences.xml");
	```

	If you use a literal native path in referencing a file, it will only work on one platform.
	For example, the following File object would only work on Windows:

	```hx
		new File("C:\\Documents and Settings\\joe\\My Documents\\test.txt")
	```

	The application storage directory is particularly useful. It gives an application-specific
	storage directory for the application. It is defined by the File.applicationStorageDirectory
	property.

	@event cancel    			Dispatched when a pending asynchronous operation is canceled.
	@event complete  			Dispatched when an asynchronous operation is complete.
	@event directoryListing 	Dispatched when a directory list is available as a result of a
	call to the getDirectoryListingAsync() method.
	@event ioError  			Dispatched when an error occurs during an asynchronous file operation.

**/
#if !crossbyte_debug
@:noDebug
#end
final class File extends EventDispatcher {
	/**
		The creation date of the file on the local disk, read from the disk
		each time it is asked for.

		The time the file was made, where the system keeps one: on Windows,
		on macOS, and on Linux where the C library has `statx` (glibc 2.28)
		and the file system records a birth time, natively, on the jvm and
		on Node. `null` where the file system keeps none. On Node it is
		Node's `birthtime`; on the jvm the attribute `creationTime`, which
		before Java 22 on Linux is the modification time, the JVM's own
		fallback. It is never POSIX's `ctime`, which is when the file's status
		last changed, a chmod, a rename or a write moves it on.

		@throws IOError               The file does not exist or cannot be
									  examined.
		@throws IllegalOperationError On the interpreter, neko and HashLink
									  under Linux or macOS, whose `stat`
									  reports no creation time.
	**/
	public var creationDate(get, null):Date;

	/**
		The Macintosh creator type of the file, which is only used in Mac OS
		versions prior to Mac OS X. In Windows or Linux, this property is
		`null`.
	**/
	public var creator(default, null):String;

	/**
		The ByteArray object representing the data from the loaded file after
		a successful call to the `load()` method.

		A load starts by unsetting it, so a load that fails, `load()`
		throwing its `IOError`, `loadAsync()` dispatching `ioError`, or one
		cancelled leaves no data from an earlier one. `save()` sets it to what
		it saved.

		@throws IllegalOperationError If the `load()` method was not called
									  successfully, an exception is thrown
									  with a message indicating that functions
									  were called in the incorrect sequence or
									  an earlier call was unsuccessful.
	**/
	public var data(get, null):ByteArray;

	/**
		The date that the file on the local disk was last modified, read from
		the disk each time it is asked for.

		@throws IOError               The file does not exist or cannot be
									  examined.
	**/
	public var modificationDate(get, null):Date;

	/**
		The name of the file on the local disk.
	**/
	public var name(get, null):String;

	/**
		The size of the file on the local disk in bytes, read from the disk
		each time it is asked for: a File made before its file was written,
		or kept while something else writes it, says what is there now.

		An `Int`, so it states sizes up to 2,147,483,647 bytes, and a file
		larger than that throws rather than answering. The standard library's
		`stat` has an Int size too, and what it made of a larger file was
		different everywhere and right nowhere: on Windows native a 3 GB file
		and a 5 GB one both read as **0**, indistinguishable from an empty
		file. The HTTP server refuses to serve such a file for the same
		reason.

		@throws IOError               If the file is larger than 2 GB, or if
									  the file cannot be opened or read, or
									  if a similar error is encountered in
									  accessing the file, an exception is
									  thrown with a message indicating a file
									  I/O error.
	**/
	public var size(get, null):Int;

	/**
		The file type.
		In Windows or Linux, this property is the file extension. On the
		Macintosh, this property is the four-character file type, which is
		only used in Mac OS versions prior to Mac OS X.

		For Windows, Linux, and Mac OS X, the file extension ?the portion
		of the `name` property that follows the last occurrence of the dot (.)
		character ?identifies the file type.
	**/
	public var type(get, null):String;

	/**
		The filename extension.

		A file's extension is the part of the name following (and not including)
		the final dot ("."). If there is no dot in the filename, the extension
		is `null`.

		Note: You should use the `extension` property to determine a file's
		type; do not use the `creator` or `type` properties. You should consider
		the `creator` and `type` properties to be considered deprecated. They
		apply to older versions of Mac OS.

		@throws IllegalOperationError If the reference is not initialized
	**/
	public var extension(default, null):String;

	/**
		The folder containing the application's installed files.

		The applicationDirectory property provides a way to reference the application directory
		that works across platforms. In CrossByte this is exposed as a filesystem path, not
		as a URL-backed virtual path.

		It is the directory the program itself is in, the executable natively, the jar on the
		jvm, the script on Node, the bytecode file on neko and HashLink, and not the working
		directory, which is wherever the program was started from: `C:\Windows\System32` for a
		Windows service. On the interpreter (`--interp`), which runs from source and has no
		program file, it is the working directory. `System.appDir` says more.

		Nothing stops a write here; it is read-only only by convention, and an installed
		application's directory is often not writable by the user running it. Keep what the
		application writes in `applicationStorageDirectory`.

		@throws IllegalOperationError In a browser.
	**/
	public static var applicationDirectory(get, never):File;

	/**
		The application's private storage directory.

		Each application has a unique, persistent application storage directory, which is
		created when you first access File.applicationStorageDirectory. This directory is unique
		to each application and user. This directory is a convenient location to store user-specific
		or application-specific data.

		The applicationStorageDirectory property provides a way to reference the application
		storage directory that works across platforms.

		It is `System.applicationId` inside the directory the operating system keeps
		applications' data in: `%APPDATA%\<id>` on Windows, `~/Library/Application Support/<id>`
		on macOS, and `$XDG_DATA_HOME/<id>` or `~/.local/share/<id>` elsewhere. The id is the
		`crossbyte_app_id` define if the build sets one and the main class's full name if not,
		so two applications whose main classes share a name, such as `Main`, share this directory
		unless one of them sets the define. `System.appStorageDir` says more.

		@throws IOError The environment names no place for it (no `APPDATA` on Windows, no
		`HOME` elsewhere), or it cannot be created.
		@throws IllegalOperationError In a browser, which has no file system.

		The following code creates a File object pointing to the "images" subdirectory of the application storage directory.

		```hx
		import crossbyte.io.File;

		var tempFiles:File = File.applicationStorageDirectory;
		tempFiles = tempFiles.resolvePath("images/");
		trace(tempFiles.nativePath);
		```
	**/
	public static var applicationStorageDirectory(get, never):File;


	/**
		The user's desktop directory.

		The desktopDirectory property provides a way to reference the desktop directory that works across platforms. If you
		set a File object to reference the desktop directory using the nativePath property, it will only work on the
		platform for which that path is valid.

		On Windows it is the Desktop directory in the user's profile (a Desktop moved elsewhere is not
		followed), on macOS ~/Desktop, and on Linux and the BSDs the directory xdg-user-dirs names,
		`XDG_DESKTOP_DIR` in `~/.config/user-dirs.dirs`, or ~/Desktop where that names none.

		If an operating system does not support a desktop directory, a suitable directory in the file system is used instead.

		The following code outputs a list of files and directories contained in the user's desktop directory.

		```hx
		import crossbyte.io.File;

		var desktop:File = File.desktopDirectory;
		var files:Array<File> = desktop.getDirectoryListing();

		for (file in files) {
			trace(file.nativePath);
		}
		```
	**/
	public static var desktopDirectory(get, never):File;

	/**
		The user's documents directory.

		On Windows, this is the Documents directory in the user's profile (for example,
		C:\Users\userName\Documents); a Documents folder moved elsewhere, through its properties or by OneDrive,
		is not followed. On Mac OS, it is /Users/userName/Documents. On Linux and the BSDs it is the directory
		xdg-user-dirs names, `XDG_DOCUMENTS_DIR` in `~/.config/user-dirs.dirs`, which a desktop in another
		language or the user may have moved, and /home/userName/Documents where that names none.

		The documentsDirectory property provides a way to reference the documents directory that works across
		platforms.

		If an operating system does not support a documents directory, a suitable directory in the file system
		is used instead.

		The following code uses the File.documentsDirectory property and the File.createDirectory() method to
		ensure that a directory named "CrossByte Test" exists in the user's documents directory.

		```hx
		import crossbyte.io.File;

		var directory:File = File.documentsDirectory;
		directory = directory.resolvePath("CrossByte Test");

		directory.createDirectory();
		trace(directory.exists); // true
		```
	**/
	public static var documentsDirectory(get, never):File;


	/**
		Indicates whether the referenced file or directory exists.  The value is true if the File object points
		to an existing file or directory, false otherwise.

		The following code creates a temporary file, then deletes it and uses the File.exists property to check
		for the existence of the file.

		```hx
		import crossbyte.io.File;

		var temp:File = File.createTempFile();
		trace(temp.exists); // true
		temp.deleteFile();
		trace(temp.exists); // false
		```
	**/
	public var exists(get, never):Bool;


	/**
		Indicates whether the reference is to a directory.  The value is true if the File object points to a directory; false otherwise.

		The following code creates an array of File objects pointing to files and directories in the user directory and then uses the
		isDirectory property to list only those File objects that point to directories (not to files).

		```hx
		import crossbyte.io.File;

		var userDirFiles:Array<File> = File.userDirectory.getDirectoryListing();

		for (file in userDirFiles) {
			if (file.isDirectory) {
				trace(file.nativePath);
			}
		}
		```
	**/
	public var isDirectory(get, never):Bool;

	/**
		Indicates whether the referenced file or directory is "hidden." The value is true if the
		referenced file or directory is hidden, false otherwise.

		The following code creates an array of File objects pointing to files and directories in
		the user directory and then uses the isHidden property to list hidden files and directories.

		```hx
		import crossbyte.io.File;

		var userDirFiles:Array<File> = File.userDirectory.getDirectoryListing();

		for (file in userDirFiles) {
			if (file.isHidden) {
				trace(file.nativePath);
			}
		}
		```
	**/
	public var isHidden(get, never):Bool;

	public static var lineEnding(get, never):String;

	/**
		The full path in the host operating system representation. On Mac OS and Linux, the forward
		slash (/) character is used as the path separator. However, in Windows, you can set the nativePath
		property by using the forward slash character or the backslash (\) character as the path separator,
		and the forward slashes are replaced with the appropriate backslash character for you.

		A path is taken literally on every platform: `%NAME%` and `$NAME` are characters of a
		name, as they are to the operating system's own file calls. It used to expand the first
		`%NAME%` from the environment on Windows, which let a name a peer sent, `"%SystemRoot%"`,
		reach a directory the program never named. Expand a variable yourself, from
		`Sys.getEnv`, where one is meant; `File.applicationStorageDirectory` and the other
		static directories are usually what was.

		Before writing code to set the nativePath property directly, consider whether doing so may result
		in platform-specific code. For example, a native path such as "C:\\Documents and Settings\\bob\\Desktop"
		is only valid on Windows. It is far better to use the following static properties, which represent
		commonly used directories, and which are valid on all platforms:

			*File.applicationDirectory
			*File.applicationStorageDirectory
			*File.desktopDirectory
			*File.documentsDirectory
			*File.userDirectory

		You can use the resolvePath() method to get a path relative to these directories.

		@throws ArgumentError The path is a bare name, such as `"file.txt"`: relative,
		with no directory component.

		@throws ArgumentError The syntax of the path is invalid.

		The following code shows a native path for an example Windows computer.

		```hx
		import crossbyte.io.File;

		var docs:File = File.documentsDirectory;
		trace(docs.nativePath); // C:\Documents and Settings\turing\My Documents
		```
	**/
	public var nativePath(get, set):String;

	/**
		The directory that contains the file or directory referenced by this File object.

		If the file or directory does not exist, the parent property still returns the File object that points to the
		containing directory, even if that directory does not exist.

		This property is identical to the return value for resolvePath("..") except that the parent of a root directory
		is null.

		The following code uses the parent property to show the directory that contains a temporary file.

		```hx
		import crossbyte.io.File;

		var tempDirectory:File = File.createTempDirectory();
		trace(tempDirectory.parent.nativePath);
		tempDirectory.deleteDirectory();
		```
	**/
	public var parent(get, never):File;


	/**
		The host operating system's path component separator character.

		On Mac OS and Linux, this is the forward slash (`/`) character. On
		Windows, it is the backslash (`\`) character.

		Note: When using the backslash character in a String literal, remember
		to type the character twice (as in `"directory\\file.ext"`). Each pair
		of backslashes in a String literal represent a single backslash in the
		String.
	**/
	public static var separator(get, never):String;

	@:noCompletion private static inline function get_separator():String {
		return System.isWindows ? "\\" : "/";
	}

	/**
		The space available at this File's location, in bytes: on the volume
		a directory is on, or the room a file has to grow on its volume. 0 if
		there is nothing at the path.

		Natively, on the jvm and on Node the file system is asked directly.
		The interpreter, neko and HashLink have no call for it and run
		`fsutil` on Windows, `df` elsewhere, once per read; `fsutil` answers
		in the system's language, and where that is not English its answer
		is not understood and this is 0.

		@throws IllegalOperationError In a browser, which has no file system.
	**/
	public var spaceAvailable(get, null):Float;

	/**
		Members of the Adobe AIR `File` API that CrossByte does not implement.

		They were eleven bare `// TODO` markers next to commented-out
		declarations, which recorded that something was missing without
		recording what or why. Listed here so the gap can be judged rather than
		rediscovered:

		- `cacheDirectory`: a per-user cache location distinct from
		  `applicationStorageDirectory`. Implementable: it is a known path per
		  OS. The only reason it is absent is that nothing has needed it.
		- `isSymbolicLink`: needs `lstat`, which the Haxe standard library
		  does not expose. Worth having: `HTTPRequestHandler` contains static
		  serving to its document root by comparing normalized paths, and a
		  symlink pointing out of the root is not visible to a comparison of
		  strings. Following symlinks in a document root is what most servers
		  do by default, so this is a policy CrossByte cannot currently offer
		  rather than a hole it currently has.
		- `url`: the `file://` form of `nativePath`. Small, and unambiguous.
		- `systemCharset`: the operating system's default text encoding.
		  CrossByte reads and writes UTF-8 throughout, so exposing this would
		  invite an encoding this class does not honour anywhere else.
		- `downloaded`: whether the file came from the internet: an NTFS
		  alternate data stream on Windows, a quarantine extended attribute on
		  macOS. Per-OS metadata with no portable meaning.
		- `preventBackup`: an iOS backup exclusion flag. No meaning on the
		  platforms CrossByte targets.
		- `permissionStatus`: AIR's mobile file-access permission model. Same.
		- `isPackage`: whether a directory is a macOS bundle. macOS only.
		- `icon`: needs an `Icon` type and image decoding, neither of which
		  belongs in a networking runtime.
	**/


	/**
		The user's directory.

		On Windows, this is the parent of the My Documents directory (for example, C:\Documents and Settings\userName).
		On Mac OS, it is /Users/userName. On Linux, it is /home/userName.

		The userDirectory property provides a way to reference the user directory that works across platforms. If you
		set the nativePath property of a File object directly, it will only work on the platform for which that
		path is valid.

		If an operating system does not support a user directory, a suitable directory in the file system is used
		instead.

		The following code outputs a list of files and directories contained in the root level of the user directory:

		```hx
		import crossbyte.io.File;

		var files:Array<File> = File.userDirectory.getDirectoryListing();

		for (file in files) {
			trace(file.nativePath);
		}
		```

	**/
	public static var userDirectory(get, never):File;

	/**
	 * Reads the contents of a file as a `ByteArray`.
	 *
	 * @param path The path to the file.
	 * @return A `ByteArray` containing the file's contents.
	 * @throws IOError The file does not exist (3003) or cannot be read.
	 */
	public static function getFileBytes(path:String):ByteArray {
		try {
			return HaxeFile.getBytes(path);
		} catch (e:Dynamic) {
			throw __missingOr(path, e);
		}
	}

	/**
	 * Reads the contents of a file as a `String`.
	 *
	 * @param path The path to the file.
	 * @return A `String` containing the file's contents.
	 * @throws IOError The file does not exist (3003) or cannot be read.
	 */
	public static function getFileText(path:String):String {
		try {
			return HaxeFile.getContent(path);
		} catch (e:Dynamic) {
			throw __missingOr(path, e);
		}
	}

	/**
	 * Saves a `ByteArray` to a file.
	 *
	 * @param path The path where the file should be saved.
	 * @param bytes The `ByteArray` to write to the file.
	 * @throws IOError The file cannot be written.
	 */
	public static function saveBytes(path:String, bytes:ByteArray):Void {
		try {
			FileOps.saveBytes(path, bytes);
		} catch (e:Dynamic) {
			throw __ioError('Could not write "$path": ${Std.string(e)}', 0);
		}
	}

	/**
	 * Saves a `String` as a text file.
	 *
	 * @param path The path where the file should be saved.
	 * @param text The `String` content to write to the file.
	 * @throws IOError The file cannot be written.
	 */
	public static function saveText(path:String, text:String):Void {
		try {
			FileOps.saveBytes(path, Bytes.ofString(text));
		} catch (e:Dynamic) {
			throw __ioError('Could not write "$path": ${Std.string(e)}', 0);
		}
	}

	@:noCompletion private var __data:ByteArray;

	@:noCompletion private static var __driveLetters:Array<String> = [
		"A:\\", "B:\\", "C:\\", "D:\\", "E:\\", "F:\\", "G:\\", "H:\\", "I:\\", "J:\\", "K:\\", "L:\\", "M:\\", "N:\\", "O:\\", "P:\\", "Q:\\", "R:\\",
		"S:\\", "T:\\", "U:\\", "V:\\", "W:\\", "X:\\", "Y:\\", "Z:\\"
	];

	// Each asynchronous operation's own worker, while it runs. There was one
	// field for all of them, so a second operation started before the first
	// had finished was disposed of by the first one's completion.
	@:noCompletion private var __pending:Array<Worker> = [];
	@:noCompletion private var __path:String;

	/**
		The constructor function for the File class.

		If you pass a path argument, the File object points to the specified path, and the nativePath property and and url
		property are set to reflect that path.

		Although you can pass a path argument to specify a file path, consider whether doing so may result in platform-specific
		code. For example, a native path such as "C:\\Documents and Settings\\bob\\Desktop" or a URL such as
		"file:///C:/Documents%20and%20Settings/bob/Desktop" is only valid on Windows. It is far better to use the following
		static properties, which represent commonly used directories, and which are valid on all platforms:

			*File.applicationDirectory
			*File.applicationStorageDirectory
			*File.desktopDirectory
			*File.documentsDirectory
			*File.userDirectory

		You can then use the resolvePath() method to get a path relative to these directories. For example, the following code
		sets up a File object to point to the settings.xml file in the application storage directory:

		```hx
		var file:File = File.applicationStorageDirectory.resolvePath("settings.xml");
		```

		@param path	The path to the file. You can specify the path by using either a URL or native path (platform-specific)
		notation. A URL is a `file:` URL: `file:///C:/x` is `C:\x` on Windows, `file:///home/x` is `/home/x`,
		`file://server/share/x` is the share `\\server\share\x`, and `%XX` escapes are decoded as UTF-8.
		@throws ArgumentError The syntax of the path parameter is invalid.
	**/
	public function new(path:String = null) {
		super();

		if (path == null) {
			return;
		}

		// A URL, as documented: it was taken for a native path, so
		// "file:///C:/x" became "file:\C:\x", which names nothing.
		if (path.length >= 5 && path.substr(0, 5).toLowerCase() == "file:") {
			path = __pathOfUrl(path, System.isWindows);
		}

		nativePath = path;

		if (name.length == 0) {
			var dirs:Array<String> = Path.directory(__path).split(separator);
			name = dirs[dirs.length - 1];
		}
	}

	/**
		The native path a `file:` URL names: `file:///C:/x` is `C:\x` on Windows,
		`file:///home/x` is `/home/x`, `file://server/share/x` is the share
		`\\server\share\x`, and `%XX` escapes are decoded as UTF-8, `+` is a
		plus sign in a path, not a space.
	**/
	@:noCompletion private static function __pathOfUrl(url:String, windows:Bool):String {
		var rest:String = url.substr(5);
		var host:String = "";

		if (StringTools.startsWith(rest, "//")) {
			rest = rest.substr(2);
			var slash:Int = rest.indexOf("/");
			host = slash < 0 ? rest : rest.substr(0, slash);
			rest = slash < 0 ? "/" : rest.substr(slash);

			if (host.toLowerCase() == "localhost") {
				host = "";
			}
		}

		var path:String = __percentDecode(rest);

		if (host != "") {
			return windows ? "\\\\" + host + StringTools.replace(path, "/", "\\") : "//" + host + path;
		}

		if (windows && ~/^\/[A-Za-z]:/.match(path)) {
			path = path.substr(1);
		}

		return path;
	}

	@:noCompletion private static function __percentDecode(text:String):String {
		if (text.indexOf("%") < 0) {
			return text;
		}

		var out:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		var i:Int = 0;

		while (i < text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);

			if (code == "%".code && i + 2 < text.length && __isHex(text.charCodeAt(i + 1)) && __isHex(text.charCodeAt(i + 2))) {
				out.addByte(Std.parseInt("0x" + text.substr(i + 1, 2)));
				i += 3;
				continue;
			}

			// One character, as UTF-8; a surrogate pair is two code units.
			var length:Int = 1;
			if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
				length = 2;
			}
			out.addString(text.substr(i, length));
			i += length;
		}

		return out.getBytes().toString();
	}

	@:noCompletion private static inline function __isHex(code:Null<Int>):Bool {
		return code != null && ((code >= "0".code && code <= "9".code) || (code >= "a".code && code <= "f".code) || (code >= "A".code && code <= "F".code));
	}

	/**
		Cancels any pending asynchronous operation.

		Each stops where it is and reports nothing more, no `complete`, no `ioError`, and the File
		dispatches `cancel`, once. What is left behind:

		- `copyToAsync` stops between blocks. A destination that did not exist before the copy began is
		  removed; copying onto one that did, the file it was part way through is removed, and the files
		  it had finished stay.
		- `moveToAsync` is a rename on one volume, done before there is anything to cancel; across
		  volumes the copy stops and is removed, and the source and whatever the move was replacing are
		  as they were.
		- `deleteDirectoryAsync` stops between entries: what it had deleted stays deleted.
		- `loadAsync` stops reading, and `data` stays unset, as for a load that failed.
		- `getDirectoryListingAsync` and `deleteFileAsync` dispatch nothing more.

		With nothing pending this does nothing, and dispatches nothing.

		@event cancel An asynchronous operation was cancelled.
	**/
	public function cancel():Void {
		// It cancelled a worker without asking whether there was one: with
		// nothing pending, a null access. And the work went on, a 64 MB
		// copy finished after it had been cancelled, because nothing in it
		// ever asked.
		if (__pending.length == 0) {
			return;
		}

		var workers:Array<Worker> = __pending;
		__pending = [];

		for (worker in workers) {
			worker.removeAllListeners();
			worker.cancel();
		}

		dispatchEvent(new Event(Event.CANCEL));
	}

	/**
		Runs `work` on a worker of its own, then `done` with what it returned
		on this File's thread, or an ioError with what it threw. `work` is
		handed what it asks, between steps, to learn whether it has been
		cancelled; a cancelled one ends by throwing FileCancelled.
	**/
	@:noCompletion private function __startAsync(work:(Void->Bool)->Dynamic, done:Dynamic->Void):Void {
		var worker:Worker = new Worker();
		__pending.push(worker);

		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> {
			__pending.remove(worker);
			done(event.message);
		});
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> {
			__pending.remove(worker);
			__dispatchIoError(event.message);
		});

		worker.doWork = function(_:Dynamic):Void {
			var result:Dynamic = null;

			try {
				result = work(() -> worker.cancelRequested);
			} catch (_:FileCancelled) {
				return;
			} catch (e:Dynamic) {
				worker.sendError(e);
				return;
			}

			worker.sendComplete(result);
		};

		worker.run();
	}

	/**
		Canonicalizes the File path.

		If the File object represents an existing file or directory, canonicalization adjusts the path so that it
		matches the case of the actual file or directory name. If the File object is a symbolic link,
		canonicalization adjusts the path so that it matches the file or directory that the link points to.

		The path is the one the file system gives for the file, natively and on Node through the system's own
		call (`GetFinalPathNameByHandle`, `realpath`), on the jvm `toRealPath`, and on the interpreter, neko and
		HashLink under Linux and macOS `realpath`, so every link on the way, a junction on Windows included, is
		followed. Two cases fall back to correcting the case of each name that exists, listing each directory on
		the way down, without following links: a path with nothing at the end of it, AIR follows a link to a
		target that does not exist, and this does not, and the interpreter, neko and HashLink under Windows,
		whose standard library resolves no link.

		The following code shows how to use the canonicalize() method to find the correct capitalization of a
		directory name. Before running this example, create a directory named CrossByte Test on the desktop of your computer.

		```hx
		import crossbyte.io.File;

		var path:File = File.desktopDirectory.resolvePath("crossbyte test");
		trace(path.nativePath);
		path.canonicalize();
		trace(path.nativePath); // ...\CrossByte Test
		```
	**/
	public function canonicalize():Void {
		// The file system's own path, where it can be asked: links followed,
		// as documented, which nothing did, only the case of each name was
		// corrected, by listing each directory on the way down.
		var real:Null<String> = __realPath(__path);

		if (real != null) {
			__path = real;
			__updateNames(real);
			return;
		}

		var segs:Array<String> = __path.split(separator);

		var cPath:String = __driveLetters[__driveLetters.indexOf(segs[0].toUpperCase() + separator)];
		var start:Int = 1;
		if (cPath == null) {
			// fall back to unix paths
			cPath = separator + segs[1] + separator;
			start = 2;
		}

		for (i in start...segs.length) {
			cPath += __canonicalize(cPath, segs[i]) + separator;
		}

		__path = Path.removeTrailingSlashes(cPath);
	}

	/**
		Returns a copy of this File object. Event registrations are not copied.

		Note: This method does not copy the file itself. It simply makes a copy of the instance of the Haxe
		File object. To copy a file, use the copyTo() method.
	**/
	public function clone():File {
		// The File's own state, set on a File made the ordinary way. It copied
		// every instance field by reflection: EventDispatcher's too, so the
		// clone shared the original's listeners (fixed by skipping those), and
		// every property through its getter, `isHidden`, which runs
		// `attrib` on Windows, `spaceAvailable`, which runs fsutil or df, and
		// size and both dates, which read the disk, to set them on a clone
		// that cannot be set.
		var clone:File = new File();
		clone.__path = __path;
		clone.name = name;
		clone.extension = extension;
		clone.type = type;
		clone.creator = creator;
		clone.__data = __data;
		return clone;
	}

	/**
		Copies the file or directory at the location specified by this File object to the location
		specified by the newLocation parameter. The copy process creates any required parent directories
		(if possible). Only the contents are copied, not the attributes AIR copies: a new copy gets the
		permissions a new file gets, one written over a file keeps that file's, and either was modified now.

		The source and destination are compared as files, not only as names: a name for the same file in
		another case on Windows, a hard link to it, or a path to it through a junction or a symbolic link is
		the same file, and copying a file onto itself is refused whatever `overwrite` says. A directory
		copied onto an existing directory with `overwrite` is merged into it: its files replace those of
		the same name, and the others stay; a file there that is one of its own under another name is
		left as it is. On neko and HashLink under Windows, which cannot tell two names of one file apart,
		a copy onto another name for the file itself does nothing, rather than being refused.

		@param newLocation The target location of the new file. Note that this File object specifies the
		resulting (copied) file or directory, not the path to the containing directory.
		@param overwrite If false, the copy fails if the file specified by the target parameter already
		exists. If true, the operation overwrites existing file or directory of the same name.
		@throws IOError The source does not exist; or the source could not be copied to the target; or
		the source and destination refer to the same file or folder; or a directory would be copied into
		itself. A file that is open is copied as it stands on disk, and so is a directory with one inside
		it, unless whatever has the file open refused other readers, as a program can on Windows.
		@throws ArgumentError `newLocation` is null.

		The following code shows how to use the copyTo() method to copy a file. Before running this code,
		create a test1.txt file in the CrossByte Test subdirectory of the documents directory on your computer.
		The resulting copied file is named test2.txt in the same directory. When
		you set the overwrite parameter to true, the operation overwrites any existing test2.txt file.

		```hx
		import crossbyte.io.File;

		var sourceFile:File = File.documentsDirectory.resolvePath("CrossByte Test/test1.txt");
		var destination:File = File.documentsDirectory.resolvePath("CrossByte Test/test2.txt");
		sourceFile.copyTo(destination, true);
		trace("Done.");
		```

		The following code shows how to use the copyTo() method to copy a file. Before running this code,
		create a test1.txt file in the CrossByte Test subdirectory of the home directory on your computer. The
		resulting copied file is named test2.txt. The try and catch statements show how to respond to errors.

		```hx
		import crossbyte.errors.Error;
		import crossbyte.io.File;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("CrossByte Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("CrossByte Test/test2.txt");

		try {
			sourceFile.copyTo(destination, true);
		} catch (error:Error) {
			trace("Error: " + error.message);
		}
		```
	**/
	public function copyTo(newLocation:File, overwrite:Bool = false):Void {
		__copyTo(newLocation, overwrite, null);
	}

	/** copyTo, which `cancelled`, when given, can stop between blocks. **/
	@:noCompletion private function __copyTo(newLocation:File, overwrite:Bool, cancelled:Null<Void->Bool>):Void {
		if (newLocation == null) {
			throw new ArgumentError("copyTo needs a destination.");
		}

		var newPath:String = newLocation.__path;

		if (!FileSystem.exists(__path)) {
			throw __ioError('"$__path" does not exist.', 3003);
		}

		// Onto itself, whatever overwrite says. The standard library's copy
		// truncates the destination before it reads the source, and the
		// source was the destination: the file was left empty. A different
		// spelling of the same file, its name in another case, a hard
		// link, a path through a junction, did the same.
		if (FileOps.sameFile(__path, newPath, System.isWindows)) {
			throw __ioError('"$__path" and "$newPath" are the same file, and copying it onto itself would empty it.', 3011);
		}

		if (!overwrite && FileSystem.exists(newPath)) {
			throw __ioError('"$newPath" exists, and overwrite is false.', 3011);
		}

		// Nor a directory into itself, which copied what it had just copied
		// until the path grew too long.
		if (isDirectory && __inside(__path, newPath)) {
			throw __ioError('Cannot copy "$__path" into itself, as "$newPath".', 3014);
		}

		if (cancelled == null) {
			__copyPath(__path, newPath, overwrite, null);
			return;
		}

		// A destination that is all this copy's own goes as a whole if it is
		// cancelled; one that was there already keeps what it had.
		var fresh:Bool = !FileSystem.exists(newPath);

		try {
			__copyPath(__path, newPath, overwrite, cancelled);
		} catch (stopped:FileCancelled) {
			if (fresh && FileSystem.exists(newPath)) {
				try {
					__removePath(newPath);
				} catch (_:Dynamic) {}
			}
			throw stopped;
		}
	}

	/**
		The copy itself, once copyTo has checked the two ends. `cancelled`,
		when given, is asked before each entry and each block, and a file cut
		short by it is removed.
	**/
	@:noCompletion private static function __copyPath(source:String, target:String, overwrite:Bool, cancelled:Null<Void->Bool>):Void {
		try {
			if (cancelled != null && cancelled()) {
				throw new FileCancelled();
			}

			if (FileSystem.isDirectory(source)) {
				FileSystem.createDirectory(target);
				for (item in __listPath(source)) {
					var child:String = Path.join([target, item]);

					if (!overwrite && FileSystem.exists(child)) {
						throw __ioError('"$child" exists, and overwrite is false.', 3011);
					}

					__copyPath(Path.join([source, item]), child, overwrite, cancelled);
				}
			} else {
				var newDirectory:String = Path.directory(target);
				if (newDirectory != "" && !FileSystem.exists(newDirectory)) {
					FileSystem.createDirectory(newDirectory);
				}

				if (FileSystem.exists(target) && __alreadyThere(source, target)) {
					// Nothing to copy, and copying would have emptied it: the
					// copy truncates the destination before it reads the
					// source, and they are one file.
					return;
				}

				if (cancelled == null) {
					#if jvm
					// Its copy opens the destination as its write() does: see FileOps.write.
					__copyFileInBlocks(source, target, () -> false);
					#else
					HaxeFile.copy(source, target);
					#end
				} else {
					__copyFileInBlocks(source, target, cancelled);
				}
			}
		} catch (e:FileCancelled) {
			throw e;
		} catch (e:Error) {
			// A recursive call has already described the failure against the
			// path it actually happened on. Re-wrapping it here would bury both.
			throw e;
		} catch (e:Dynamic) {
			// The source was checked above, so whatever went wrong is not what
			// 3003 says. A permission denial, a full disk and a file held open
			// by another process all used to be reported as a missing file,
			// which sends whoever is reading the error looking for the wrong
			// thing entirely.
			throw __ioError('Unable to copy "$source" to "$target": ${Std.string(e)}', 3006);
		}
	}

	/**
		Whether the file at `target` already is the file at `source`, so that
		copying one onto the other has nothing to do, and would empty it.

		copyTo refuses its own two ends when they are one file, but a
		directory merged into another can find a second name of one of its
		own files there, a hard link, and that copy truncated the file before
		reading it. Where the target cannot tell two files apart, neko and
		hl under Windows, whose `stat` has no file index, two files with
		the same bytes count as one: copying either onto the other changes
		nothing, and a second name of one file always has the same bytes.
	**/
	@:noCompletion private static function __alreadyThere(source:String, target:String):Bool {
		var windows:Bool = System.isWindows;

		if (FileOps.sameFile(source, target, windows)) {
			return true;
		}

		#if (neko || hl)
		if (windows && (FileOps.identity(source) == null || FileOps.identity(target) == null)) {
			return __sameBytes(source, target);
		}
		#end

		return false;
	}

	#if (neko || hl)
	/** Whether two files hold the same bytes, read a block at a time. **/
	@:noCompletion private static function __sameBytes(a:String, b:String):Bool {
		if (FileSystem.stat(a).size != FileSystem.stat(b).size) {
			return false;
		}

		var left = HaxeFile.read(a, true);
		var right = try HaxeFile.read(b, true) catch (e:Dynamic) {
			left.close();
			throw e;
		};
		var one:Bytes = Bytes.alloc(__COPY_BLOCK);
		var two:Bytes = Bytes.alloc(__COPY_BLOCK);
		var same:Bool = true;

		try {
			while (same) {
				var got:Int = __fill(left, one);
				if (got != __fill(right, two)) {
					same = false;
				} else if (got == 0) {
					break;
				} else {
					same = one.sub(0, got).compare(two.sub(0, got)) == 0;
				}
			}
		} catch (e:Dynamic) {
			left.close();
			right.close();
			throw e;
		}

		left.close();
		right.close();
		return same;
	}

	/** As many bytes as `input` has, up to `block`'s length. **/
	@:noCompletion private static function __fill(input:haxe.io.Input, block:Bytes):Int {
		var got:Int = 0;

		try {
			while (got < block.length) {
				var read:Int = input.readBytes(block, got, block.length - got);
				if (read <= 0) {
					break;
				}
				got += read;
			}
		} catch (_:haxe.io.Eof) {}

		return got;
	}
	#end

	/**
		A file's copy, a block at a time, asking `cancelled` before each;
		stopped, what it had written is removed. The standard library's copy
		is one call nothing can interrupt, so a cancelled copy ran to its end.
	**/
	@:noCompletion private static function __copyFileInBlocks(source:String, target:String, cancelled:Void->Bool):Void {
		var input = HaxeFile.read(source, true);
		var output = try FileOps.write(target) catch (e:Dynamic) {
			input.close();
			throw e;
		};
		var block:Bytes = Bytes.alloc(__COPY_BLOCK);
		var stopped:Bool = false;
		var copied:Float = 0;

		try {
			while (true) {
				if (cancelled()) {
					stopped = true;
					break;
				}

				var read:Int = 0;
				try {
					read = input.readBytes(block, 0, block.length);
				} catch (_:haxe.io.Eof) {}

				if (read <= 0) {
					break;
				}

				output.writeFullBytes(block, 0, read);
				copied += read;
				__copiedBlock(target, copied);
			}
		} catch (e:Dynamic) {
			input.close();
			output.close();
			throw e;
		}

		input.close();
		output.close();

		if (stopped) {
			try {
				FileSystem.deleteFile(target);
			} catch (_:Dynamic) {}
			throw new FileCancelled();
		}
	}

	@:noCompletion private static inline var __COPY_BLOCK:Int = 1 << 20;

	/**
		Told of each block a cancellable copy writes. Does nothing; dynamic so
		that a test can slow a copy down enough to cancel it part way through.
	**/
	@:noCompletion private static dynamic function __copiedBlock(target:String, copied:Float):Void {}

	/**
		Whether a rename reaches from `path` into `directory`. Dynamic so that
		a test on a machine with one volume can take the path a second one
		would.
	**/
	@:noCompletion private static dynamic function __sameVolume(path:String, directory:String, windows:Bool):Bool {
		return FileOps.sameVolume(path, directory, windows);
	}

	/** Whether `path` is `directory` or below it, once both are absolute and normalized. **/
	@:noCompletion private static function __inside(directory:String, path:String):Bool {
		#if (js && !nodejs)
		return false;
		#else
		return FilePath.relative(FileSystem.absolutePath(directory), FileSystem.absolutePath(path), false, System.isWindows) != null;
		#end
	}

	/** An IOError carrying one of AIR's error numbers, as File's documentation promises. **/
	@:noCompletion private static function __ioError(message:String, id:Int):IOError {
		var error:IOError = new IOError(message);
		@:privateAccess error.errorID = id;
		return error;
	}

	/**
		Begins copying the file or directory at the location specified by this File object to the
		location specified by the destination parameter.

		Upon completion, either a complete event (successful) or an ioError event (unsuccessful) is dispatched.
		The copy process creates any required parent directories (if possible).

		@param newLocation The target location of the new file. Note that this File object specifies the
		resulting (copied) file or directory, not the path to the containing directory.
		@param overwrite If false, the copy fails if the file specified by the target parameter already
		exists. If true, the operation overwrites existing file or directory of the same name.
		@event complete Dispatched when the file or directory has been successfully copied.
		@event ioError The source does not exist; or the source could not be copied to the target; or the source
		and destination refer to the same file or folder. A file that is open is copied as it stands on
		disk, and so is a directory with one inside it, unless whatever has the file open refused other
		readers, as a program can on Windows.

		The following code shows how to use the copyToAsync() method to copy a file. Before running this code,
		be sure to create a test1.txt file in the CrossByte Test subdirectory of the documents directory on your computer.
		The resulting copied file is named test2.txt in the same directory. When you set the
		overwrite parameter to true, the operation overwrites any existing test2.txt file.

		```hx
		import crossbyte.events.Event;
		import crossbyte.io.File;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("CrossByte Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("CrossByte Test/test2.txt");

		function fileCopiedHandler(event:Event):Void {
			trace("Done.");
		}

		sourceFile.addEventListener(Event.COMPLETE, fileCopiedHandler);
		sourceFile.copyToAsync(destination, true);
		```
	**/
	public function copyToAsync(newLocation:File, overwrite:Bool = false):Void {
		__startAsync(cancelled -> {
			__copyTo(newLocation, overwrite, cancelled);
			return null;
		}, _ -> dispatchEvent(new Event(Event.COMPLETE)));
	}

	/**
		Creates the specified directory and any necessary parent directories. If the directory already exists,
		no action is taken.

		@throws	IOError The directory did not exist and could not be created.

		The following code moves a file named test.txt on the desktop to the CrossByte Test subdirectory of the
		documents directory. The call to the createDirectory() method ensures that the CrossByte Test directory
		exists before the file is moved.

		```hx
		import crossbyte.io.File;

		var source:File = File.desktopDirectory.resolvePath("test.txt");
		var target:File = File.documentsDirectory.resolvePath("CrossByte Test/test.txt");
		var targetParent:File = target.parent;
		targetParent.createDirectory();
		source.moveTo(target, true);
		```

	**/
	public function createDirectory():Void {
		try {
			FileSystem.createDirectory(__path);
		} catch (e:Dynamic) {
			throw __ioError('Could not create the directory "$__path": ${Std.string(e)}', FileSystem.exists(__path) ? 3002 : 0);
		}
	}

	/**
		Deletes the directory.

		@param deleteDirectoryContents Specifies whether or not to delete a directory that contains files or
		subdirectories. When false, if the directory contains files or directories, a call to this method throws
		an exception.
		@throws	IOError The directory does not exist, or the directory could not be deleted. On Windows a
		directory with a file open inside it cannot be deleted, unless whatever has the file open allowed
		that: most programs do not, nor does `FileStream` except on Node.

		The following code creates an empty directory and then uses the deleteDirectory() method to delete the directory.

		```hx
		import crossbyte.io.File;

		var directory:File = File.documentsDirectory.resolvePath("Empty Junk Directory/");
		directory.createDirectory();
		trace(directory.exists); // true
		directory.deleteDirectory();
		trace(directory.exists); // false
		```
	**/
	public function deleteDirectory(deleteDirectoryContents:Bool = false):Void {
		__deleteDirectory(deleteDirectoryContents, null);
	}

	/** deleteDirectory, which `cancelled`, when given, can stop between entries. **/
	@:noCompletion private function __deleteDirectory(deleteDirectoryContents:Bool, cancelled:Null<Void->Bool>):Void {
		if (!FileSystem.exists(__path)) {
			throw __ioError('"$__path" does not exist.', 3003);
		}

		if (!FileSystem.isDirectory(__path)) {
			throw __ioError('"$__path" is not a directory; deleteFile() deletes a file.', 3007);
		}

		if (deleteDirectoryContents) {
			for (item in __listPath(__path)) {
				try {
					__removePath(Path.join([__path, item]), cancelled);
				} catch (e:FileCancelled) {
					throw e;
				} catch (e:Dynamic) {
					throw __ioError('Could not delete "${Path.join([__path, item])}": ${Std.string(e)}', 3012);
				}
			}
		} else if (__listPath(__path).length > 0) {
			throw __ioError('"$__path" is not empty, and deleteDirectoryContents is false.', 3010);
		}

		// Each failure was "Folder is not empty", whatever it was, a
		// directory held open, a permission refused, and the base Error,
		// where an IOError is documented.
		try {
			FileSystem.deleteDirectory(__path);
		} catch (e:Dynamic) {
			throw __ioError('Could not delete "$__path": ${Std.string(e)}', 3012);
		}
	}

	/**
		Deletes the directory asynchronously.

		@param deleteDirectoryContents Specifies whether or not to delete a directory that contains files or
		subdirectories. When false, a directory that contains files or directories is reported as an
		`ioError`.
		@events complete Dispatched when the directory has been deleted successfully.
		@events ioError The directory does not exist or could not be deleted. On Windows a directory with a
		file open inside it cannot be deleted, unless whatever has the file open allowed that: most programs
		do not, nor does `FileStream` except on Node.

	**/
	public function deleteDirectoryAsync(deleteDirectoryContents:Bool = false):Void {
		__startAsync(cancelled -> {
			__deleteDirectory(deleteDirectoryContents, cancelled);
			return null;
		}, _ -> dispatchEvent(new Event(Event.COMPLETE)));
	}

	/**
		Deletes the file.

		@throws	IOError The file does not exist (3003), is a directory (3006), or could not be deleted
		(3012). On Windows a file that is open cannot be deleted, unless whatever has it open allowed that:
		most programs do not, nor does `FileStream` except on Node.

		The following code creates a temporary file and then calls the deleteFile() method to delete it.

		```hx
		import crossbyte.io.File;

		var file:File = File.createTempFile();
		trace(file.exists); // true
		file.deleteFile();
		trace(file.exists); // false
		```
	**/
	public function deleteFile():Void {
		if (!FileSystem.exists(__path)) {
			throw __ioError('"$__path" does not exist.', 3003);
		}

		if (FileSystem.isDirectory(__path)) {
			throw __ioError('"$__path" is a directory; deleteDirectory() deletes one.', 3006);
		}

		try {
			FileSystem.deleteFile(__path);
		} catch (e:Dynamic) {
			throw __ioError('Could not delete "$__path": ${Std.string(e)}', 3012);
		}
	}

	/**
		Deletes the file asynchronously.

		@events complete Dispatched when the file has been deleted successfully.
		@events ioError The file does not exist, is a directory, or could not be deleted. On Windows a file
		that is open cannot be deleted, unless whatever has it open allowed that: most programs do not, nor
		does `FileStream` except on Node.
	**/
	public function deleteFileAsync():Void {
		__startAsync(_ -> {
			deleteFile();
			return null;
		}, _ -> dispatchEvent(new Event(Event.COMPLETE)));
	}

	/**
		Returns an array of File objects corresponding to files and directories in the directory
		represented by this File object. This method does not explore the contents of subdirectories.

		@returns Array An array of File objects.

		The following code shows how to use the getDirectoryListing() method to enumerate the contents of the
		user directory.

		```hx
		import crossbyte.io.File;

		var directory:File = File.userDirectory;
		var list:Array<File> = directory.getDirectoryListing();

		for (file in list) {
			trace(file.nativePath);
		}
		```
	**/
	public function getDirectoryListing():Array<File> {
		__checkDirectory();

		var directories:Array<String> = __listPath(__path);
		var files:Array<File> = [];

		for (directory in directories) {
			files.push(new File(__path + separator + directory));
		}

		return files;
	}

	/**
		Asynchronously retrieves an array of File objects corresponding to the contents of the
		directory represented by this File object.

		@events ioError You do not have adequate permissions to read this directory, or the directory does
		not exist.
		@events directoryListing The directory contents have been enumerated successfully. The contents
		event includes a files property, which is the resulting array of File objects.

		The following code shows how to use the getDirectoryListingAsync() method to enumerate the contents
		of the user directory.

		```hx
		import crossbyte.events.FileListEvent;
		import crossbyte.io.File;

		function directoryListingHandler(event:FileListEvent):Void {
			for (file in event.files) {
				trace(file.nativePath);
			}
		}

		var directory:File = File.userDirectory;
		directory.addEventListener(FileListEvent.DIRECTORY_LISTING, directoryListingHandler);
		directory.getDirectoryListingAsync();
		```
	**/
	public function getDirectoryListingAsync():Void {
		__startAsync(cancelled -> {
			// On the worker, so that what is wrong with the directory is the
			// documented ioError event. It was thrown, synchronously.
			__checkDirectory();
			var files:Array<File> = [];

			for (item in __listPath(__path)) {
				if (cancelled()) {
					throw new FileCancelled();
				}
				files.push(new File(Path.join([__path, item])));
			}

			return files;
		}, (files:Array<File>) -> dispatchEvent(new FileListEvent(FileListEvent.DIRECTORY_LISTING, files)));
	}

	/** An IOError unless this is a directory: 3003 when nothing is there, 3007 when a file is. **/
	@:noCompletion private function __checkDirectory():Void {
		if (!FileSystem.exists(__path)) {
			throw __ioError('"$__path" does not exist.', 3003);
		}

		if (!FileSystem.isDirectory(__path)) {
			throw __ioError('"$__path" is not a directory.', 3007);
		}
	}

	/**
		Finds the relative path between two File paths.

		The relative path is the list of components that can be appended to (resolved against) this reference
		in order to locate the second (parameter) reference. The relative path is returned using the "/"
		separator character.

		Optionally, relative paths may include ".." references, but such paths will not cross conspicuous volume
		boundaries.

		Without `useDotDot` the answer is null for anything that is not this
		File's path or below it, which makes this the check to run on a path
		that came from outside: see `resolvePath`. It is `""` when the two are
		the same place. Both paths are normalized first, and a relative one is
		read against the working directory. Names are compared without regard
		to case on Windows and exactly everywhere else, macOS included,
		whose default volume ignores case: a name that differs only in case
		reads as somewhere else, which for an inside-this-directory check is
		the side to err on. Two drives, or two shares, are two volumes, and
		the answer between them is null even with `useDotDot`.

		@param ref A File object against which the path is given.
		@param useDotDot  Specifies whether the resulting relative path can use ".." components.
		@returns String The relative path between this file (or directory) and the ref file (or directory), if possible; otherwise null.
		@throws	ArgumentError The reference is null.
	**/
	public function getRelativePath(ref:File, useDotDot:Bool = false):Null<String> {
		// It compared raw strings split on the separator: a sibling came back
		// as its bare name rather than null, the answer was joined with `\` on
		// Windows, a null ref was a null access, and nothing stopped it
		// answering across two drives.
		if (ref == null) {
			throw new ArgumentError("getRelativePath needs a File to compare against.");
		}

		var windows:Bool = System.isWindows;
		var from:String = __path;
		var to:String = ref.__path;
		var fromAbsolute:Bool = FilePath.isAbsolute(from, windows);
		var toAbsolute:Bool = FilePath.isAbsolute(to, windows);

		if (fromAbsolute != toAbsolute) {
			#if (js && !nodejs)
			return null;
			#else
			if (!fromAbsolute) {
				from = FileSystem.absolutePath(from);
			}
			if (!toAbsolute) {
				to = FileSystem.absolutePath(to);
			}
			#end
		}

		return FilePath.relative(from, to, useDotDot, windows);
	}

	/**
		Loads a file synchronously. The data is loaded into the data property of the File instance.

		@throws IOError The file does not exist (3003) or cannot be read.
	**/
	public function load():Void {
		// Unset first: a load that fails leaves no data from an earlier one.
		__data = null;
		__data = getFileBytes(__path);
	}

	/**
		Loads a file asynchronously. The file data is stored in the `data` property and a
		`complete` event is dispatched when loading finishes.

		@event complete The file has been read into `data`.
		@event ioError The file does not exist or cannot be read.
	**/
	public function loadAsync():Void {
		__data = null;
		__startAsync(cancelled -> {
			// A block at a time, so that a cancel stops it, into one buffer of
			// the file's size.
			var size:Float = __sizeNow();

			if (size > 2147483647.0) {
				throw __ioError('"$__path" is larger than 2 GB, more than one ByteArray holds.', 3005);
			}

			var data:Bytes = Bytes.alloc(Std.int(size));
			var input = HaxeFile.read(__path, true);
			var got:Int = 0;

			try {
				while (got < data.length) {
					if (cancelled()) {
						throw new FileCancelled();
					}

					var want:Int = data.length - got < __COPY_BLOCK ? data.length - got : __COPY_BLOCK;
					var read:Int = 0;
					try {
						read = input.readBytes(data, got, want);
					} catch (_:haxe.io.Eof) {}

					if (read <= 0) {
						break;
					}

					got += read;
				}
			} catch (e:Dynamic) {
				input.close();
				throw e;
			}

			input.close();
			return got == data.length ? data : data.sub(0, got);
		}, (bytes:Bytes) -> {
			__data = ByteArray.fromBytes(bytes);
			dispatchEvent(new Event(Event.COMPLETE));
		});
	}

	/**
		Moves the file or directory at the location specified by this File object to the
		location specified by the destination parameter.

		To rename a file, set the destination parameter to point to a path that is in the
		file's directory, but with a different filename.

		The move process creates any required parent directories (if possible).

		On one volume a move is a rename: as quick for a directory of any size as for one file, and a
		file replaced through it is never seen half written. A name changed only in case is renamed,
		even where the file system ignores case and the two names are the same file. Onto another
		volume, where no rename reaches, the source is copied and then deleted, and if the copy fails
		nothing of it is left behind. With `overwrite`, an existing destination is replaced, a
		directory as a whole, not merged into, and is put back if the move fails.

		@param newLocation The target location for the move. This object specifies the path to the
		resulting (moved) file or directory, not the path to the containing directory.
		@param overwrite If false, the move fails if the target file already exists. If true, the
		operation overwrites any existing file or directory of the same name.
		@throws	IOError  The source does not exist; or the destination exists and overwrite is set to
		false; or the source file or directory could not be moved to the target location; or the source
		and destination refer to the same file or folder (other than by a name changed only in case); or
		a directory would be moved into itself. On Windows a file that is open cannot be moved, nor a
		directory with one inside it, unless whatever has the file open allowed that: most programs do
		not, nor does `FileStream` except on Node.
		@throws ArgumentError `newLocation` is null.

		The following code shows how to use the moveTo() method to rename a file. The original filename
		is test1.txt and the resulting filename is test2.txt. Since both the source and destination File
		object point to the same directory (the CrossByte Test subdirectory of the user's documents directory),
		the moveTo() method renames the file, rather than moving it to a new directory. Before running this
		code, create a test1.txt file in the CrossByte Test subdirectory of the documents directory on your
		computer. When you set the overwrite parameter to true, the operation overwrites any existing test2.txt
		file.

		```hx
		import crossbyte.errors.Error;
		import crossbyte.io.File;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("CrossByte Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("CrossByte Test/test2.txt");

		try {
			sourceFile.moveTo(destination, true);
		} catch (error:Error) {
			trace("Error: " + error.message);
		}
		```
	**/
	public function moveTo(newLocation:File, overwrite:Bool = false):Void {
		__moveTo(newLocation, overwrite, null);
	}

	/** moveTo, whose copy across volumes `cancelled`, when given, can stop. **/
	@:noCompletion private function __moveTo(newLocation:File, overwrite:Bool, cancelled:Null<Void->Bool>):Void {
		// It was a copy followed by a delete, always. Onto itself that copy
		// emptied the file; a rename of a name's case, the same file to
		// Windows and to macOS by default, copied the file onto itself and
		// then deleted it. It is a rename now, and a copy and a delete only
		// where a rename cannot go: to another volume.
		if (newLocation == null) {
			throw new ArgumentError("moveTo needs a destination.");
		}

		var windows:Bool = System.isWindows;
		var source:String = __path;
		var target:String = newLocation.__path;

		if (!FileSystem.exists(source)) {
			throw __ioError('"$source" does not exist.', 3003);
		}

		if (FileOps.sameFile(source, target, windows)) {
			var from:String = FilePath.normalize(FileSystem.absolutePath(source), windows);
			var to:String = FilePath.normalize(FileSystem.absolutePath(target), windows);

			if (from != to && from.toLowerCase() == to.toLowerCase()) {
				// One name in another case: nothing is overwritten, whatever
				// overwrite says.
				try {
					FileSystem.rename(source, target);
				} catch (e:Dynamic) {
					throw __ioError('Could not rename "$source" to "$target": ${Std.string(e)}', 3006);
				}

				return;
			}

			throw __ioError('"$source" and "$target" are the same file.', 3011);
		}

		var targetExists:Bool = FileSystem.exists(target);

		if (targetExists && !overwrite) {
			throw __ioError('"$target" exists, and overwrite is false.', 3011);
		}

		var sourceIsDirectory:Bool = FileSystem.isDirectory(source);

		if (sourceIsDirectory && __inside(source, target)) {
			throw __ioError('Cannot move "$source" into itself, as "$target".', 3014);
		}

		var targetParts:FilePathParts = FilePath.parse(FileSystem.absolutePath(target), windows);
		var parentSegments:Array<String> = FilePath.walk([], targetParts.segments, true, 0);
		parentSegments.pop();
		var parentDirectory:String = FilePath.join(targetParts.root, parentSegments, windows);

		if (!FileSystem.exists(parentDirectory)) {
			FileSystem.createDirectory(parentDirectory);
		}

		var across:Bool = !__sameVolume(source, parentDirectory, windows);

		if (targetExists && !across && !sourceIsDirectory && !FileSystem.isDirectory(target)) {
			// A file over a file on one volume: one step, which a reader of
			// the old file never sees half done.
			try {
				FileOps.replace(source, target);
			} catch (e:Dynamic) {
				throw __ioError('Could not move "$source" over "$target": ${Std.string(e)}', 3006);
			}

			return;
		}

		// Anything else in the way, a directory, or a file a directory is
		// moving onto, is set aside first, under a name of its own in the
		// same directory, and put back if the move fails. Overwrite replaces
		// it, as documented, rather than merging into it.
		var aside:Null<String> = null;

		if (targetExists) {
			aside = target + ".moving-" + __tempNonce();

			try {
				FileSystem.rename(target, aside);
			} catch (e:Dynamic) {
				throw __ioError('Could not move "$target" out of the way: ${Std.string(e)}', 3006);
			}
		}

		try {
			if (across) {
				__copyPath(source, target, false, cancelled);
			} else {
				FileSystem.rename(source, target);
			}
		} catch (e:Dynamic) {
			// Cancelled or failed alike: what the copy made goes, and what the
			// move was replacing comes back.
			if (across && FileSystem.exists(target)) {
				try {
					__removePath(target);
				} catch (_:Dynamic) {}
			}

			if (aside != null) {
				try {
					FileSystem.rename(aside, target);
				} catch (_:Dynamic) {}
			}

			if (Std.isOfType(e, Error) || Std.isOfType(e, FileCancelled)) {
				throw e;
			}

			throw __ioError('Could not move "$source" to "$target": ${Std.string(e)}', 3006);
		}

		if (across) {
			// The copy is whole; only now does the source go.
			try {
				__removePath(source);
			} catch (e:Dynamic) {
				throw __ioError('Copied "$source" to "$target", on another volume, but could not then delete it: ${Std.string(e)}', 3012);
			}
		}

		if (aside != null) {
			try {
				__removePath(aside);
			} catch (e:Dynamic) {
				throw __ioError('Moved "$source" to "$target", but the "$target" it replaced is still at "$aside": ${Std.string(e)}', 3012);
			}
		}
	}

	/**
			Begins moving the file or directory at the location specified by this File object to
			the location specified by the newLocation parameter.

			To rename a file, set the destination parameter to point to a path that is in the file's directory, but
			with a different filename.

			The move process creates any required parent directories (if possible).

			@param newLocation The target location for the move. This object specifies the path to the
			resulting (moved) file or directory, not the path to the containing directory.
			@param overwrite If false, the move fails if the target file already exists. If true, the
			operation overwrites any existing file or directory of the same name.
			@event complete Dispatched when the file or directory has been successfully moved.
			@event ioError The source does not exist; or the destination exists and overwrite is false; or
			the source could not be moved to the target; or the source and destination refer to the same file
			or folder (other than by a name changed only in case). On Windows a file that is open cannot be
			moved, nor a directory with one inside it, unless whatever has the file open allowed that: most
			programs do not, nor does `FileStream` except on Node.

			The following code shows how to use the moveToAsync() method to rename a file. The original filename
			is test1.txt and the resulting name is test2.txt. Since both the source and destination File object
			point to the same directory (the CrossByte Test subdirectory of the user's documents directory), the
			moveToAsync() method renames the file, rather than moving it to a new directory. Before running this
			code, create a test1.txt file in the CrossByte Test subdirectory of the documents directory on your
			computer. When you set overwrite parameter to true, the operation overwrites any existing test2.txt file.

			```hx
			import crossbyte.events.Event;
			import crossbyte.io.File;

			var sourceFile:File = File.documentsDirectory;
			sourceFile = sourceFile.resolvePath("CrossByte Test/test1.txt");
			var destination:File = File.documentsDirectory;
			destination = destination.resolvePath("CrossByte Test/test2.txt");

			function fileMoveCompleteHandler(event:Event):Void {
				trace("Done.");
			}

			sourceFile.addEventListener(Event.COMPLETE, fileMoveCompleteHandler);
			sourceFile.moveToAsync(destination, true);
			```
	**/
	public function moveToAsync(newLocation:File, overwrite:Bool = false):Void {
		__startAsync(cancelled -> {
			__moveTo(newLocation, overwrite, cancelled);
			return null;
		}, _ -> dispatchEvent(new Event(Event.COMPLETE)));
	}

	/**
		Opens the file in the application registered by the operating system to open this file type.

		A directory opens in the file manager. The application is started and this returns: it does
		not wait for it, nor report what it does after starting. Through `explorer.exe` on Windows,
		`open` on macOS and `xdg-open` elsewhere, on Node through `child_process`, so it opens on
		the desktop of the user the program runs as, and does nothing visible for a service with no
		desktop.

		As in AIR, a file the operating system would run rather than open is refused: one with an
		executable's extension (`exe`, `bat`, `cmd`, `com`, `msi`, `ps1`, `vbs`, `js`, `jar`, `lnk`,
		`sh`, `app`, `command`, `desktop` and the like), and on Linux and macOS a file marked
		executable.

		@throws IOError The file does not exist.
		@throws IllegalOperationError The file's type is one that would be run; or there is no way to
		open a file here, a browser, an operating system other than Windows, macOS, Linux and BSD, or
		`xdg-open` not installed.
	**/
	public function openWithDefaultApplication():Void {
		// It was empty: a public, documented member that did nothing at all.
		#if (js && !nodejs)
		throw new IllegalOperationError("A browser cannot open a file in another application.");
		#else
		if (!FileSystem.exists(__path)) {
			throw __ioError('"$__path" does not exist.', 3003);
		}

		var path:String = FilePath.normalize(FileSystem.absolutePath(__path), System.isWindows);

		if (!FileSystem.isDirectory(path) && __runsRatherThanOpens(path)) {
			throw new IllegalOperationError('"$path" is a type of file the operating system would run rather than open, and is not opened.');
		}

		var launch:Null<{command:String, args:Array<String>}> = __defaultApplicationCommand(path, System.PLATFORM);

		if (launch == null) {
			throw new IllegalOperationError("There is no way to open a file with its default application on " + System.PLATFORM + ".");
		}

		__launch(launch.command, launch.args);
		#end
	}

	/**
		The command that opens `path` with its default application on
		`platform`, or null where there is none.
	**/
	@:noCompletion private static function __defaultApplicationCommand(path:String, platform:String):Null<{command:String, args:Array<String>}> {
		return switch (platform) {
			// explorer.exe rather than cmd's `start`, which a quoted argument,
			// and Process quotes each, stops being: cmd reads `"start"` as
			// the name of a program.
			case "windows": {command: "explorer.exe", args: [path]};
			case "mac": {command: "open", args: [path]};
			case "linux" | "freebsd" | "openbsd" | "netbsd" | "bsd": {command: "xdg-open", args: [path]};
			default: null;
		}
	}

	/**
		Whether the operating system would run `path` rather than open it:
		an executable's extension anywhere, and on POSIX the executable bit.
	**/
	@:noCompletion private static function __runsRatherThanOpens(path:String):Bool {
		var extension:Null<String> = Path.extension(path);

		if (extension != null && __RUNNABLE.indexOf(extension.toLowerCase()) >= 0) {
			return true;
		}

		#if !(js && !nodejs)
		if (!System.isWindows) {
			try {
				// Any of the three execute bits.
				return FileSystem.stat(path).mode & 0x49 != 0;
			} catch (_:Dynamic) {}
		}
		#end

		return false;
	}

	@:noCompletion private static final __RUNNABLE:Array<String> = [
		"exe", "com", "bat", "cmd", "msi", "msp", "msc", "scr", "pif", "cpl", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "wsc", "hta",
		"lnk", "reg", "scf", "url", "inf", "jar", "appref-ms", "application", "gadget", "sh", "bash", "csh", "ksh", "zsh", "app", "command", "tool",
		"terminal", "workflow", "desktop", "run"
	];

	/**
		Starts `command` and lets it run. Dynamic so a test can see what
		would be started without starting it.
	**/
	@:noCompletion private static dynamic function __launch(command:String, args:Array<String>):Void {
		#if (js && !nodejs)
		throw new IllegalOperationError("A browser cannot start a program.");
		#elseif nodejs
		var child:Dynamic = js.node.ChildProcess.spawn(command, args, cast {detached: true, stdio: "ignore"});
		// Reported on the child, not thrown here, so it is caught and dropped:
		// once started it is not this call's to answer for.
		child.on("error", (_:Dynamic) -> {});
		child.unref();
		#else
		if (System.PLATFORM != "windows" && !__onPath(command)) {
			throw new IllegalOperationError('"$command", which opens files with their default applications here, is not installed.');
		}

		var process:sys.io.Process = new sys.io.Process(command, args);

		#if target.threaded
		// Waited for elsewhere, so this call does not wait, and a POSIX child
		// is reaped rather than left a zombie for the life of the process.
		sys.thread.Thread.create(() -> {
			try {
				process.exitCode();
			} catch (_:Dynamic) {}
			try {
				process.close();
			} catch (_:Dynamic) {}
		});
		#end
		#end
	}

	#if !(js && !nodejs)
	@:noCompletion private static function __onPath(command:String):Bool {
		var path:Null<String> = Sys.getEnv("PATH");

		if (path == null) {
			return false;
		}

		for (directory in path.split(System.isWindows ? ";" : ":")) {
			if (directory != "" && FileSystem.exists(Path.join([directory, command]))) {
				return true;
			}
		}

		return false;
	}
	#end

	/**
		Creates a new File object with a path relative to this File object's path, based on the path
		parameter (a string).

		You can use a relative path or absolute path as the path parameter.

		If you specify a relative path, the given path is "appended" to the path of the File object. However, use
		of ".." in the path can return a resulting path that is not a child of the File object. The resulting
		reference need not refer to an actual file system location.

		If you specify an absolute file reference, the method returns the File object pointing to that path. The
		absolute file reference should use valid native path syntax for the user's operating system (such as
		"C:\\test" on Windows). Do not use a URL (such as "file:///c:/test") as the path parameter.

		All resulting paths are normalized as follows:

			Any "." element is ignored.
			Any ".." element consumes its parent entry.
			No ".." reference that reaches the file system root or the application-persistent storage root passes
			that node; it is ignored.

		You should always use the forward slash (/) character as the path separator. On Windows, you can also use
		the backslash (\) character, but you should not. Using the backslash character can lead to applications
		that do not work on other platforms.

		Filenames and directory names are case-sensitive on Linux.

		What counts as absolute: on POSIX a path starting with `/`. On Windows a
		drive (`C:\test`, and `C:test`, which is taken to mean `C:\test`), a
		share (`\\server\share\test`, which covers `\\?\C:\test` too), or a path
		starting with a separator, which is read against this File's own drive
		or share. `\` separates on every platform, as it does in `nativePath`.
		A relative File stays relative, and its `..` past the start is kept.

		**This is not a sandbox.** An absolute `path` is returned as it is,
		wherever it points, and the `..` rule above only stops a path climbing
		out of the storage root by `..`, it does not stop one that names
		somewhere else outright. To keep a path that came from a user or a peer
		inside a directory, resolve it and then check where it landed:

		```hx
		// Given requestedName:String.
		import crossbyte.io.File;

		var dir:File = File.applicationStorageDirectory.resolvePath("uploads");
		var target:File = dir.resolvePath(requestedName);

		if (dir.getRelativePath(target) == null) {
			throw new crossbyte.errors.SecurityError(requestedName + " is not inside " + dir.nativePath);
		}
		```

		`getRelativePath` answers null for anything that is not the directory
		or below it. It compares paths, not what is on disk: a symbolic link
		inside the directory that points out of it passes.

		@param path The path to append to this File object's path (if the path parameter is a relative path); or
		the path to return (if the path parameter is an absolute path).
		@returns File A new File object pointing to the resulting path.
		@throws ArgumentError `path` is null.
	**/
	public function resolvePath(path:String):File {
		// It concatenated: "../x" came back as "<this>\..\x", an absolute path
		// came back appended, "<this>\C:\Windows\win.ini", and nothing stopped
		// at the storage root. So applicationStorageDirectory.resolvePath(name)
		// climbed out of it on a name holding "..".
		if (path == null) {
			throw new ArgumentError("resolvePath needs a path; null names nowhere.");
		}

		var windows:Bool = System.isWindows;
		var target:FilePathParts = FilePath.parse(path, windows);

		if (target.root != "") {
			var root:String = target.root;

			if (windows && root == "\\") {
				// Rooted on no drive in particular: this File's own.
				var own:String = FilePath.parse(__path, true).root;
				if (own != "") {
					root = own;
				}
			}

			return new File(FilePath.join(root, FilePath.walk([], target.segments, true, 0), windows));
		}

		var base:FilePathParts = FilePath.parse(__path, windows);
		var rooted:Bool = base.root != "";
		var start:Array<String> = FilePath.walk([], base.segments, rooted, 0);
		var floor:Int = 0;
		var storage:Array<String> = null;

		if (rooted) {
			// The storage root's own rule: a `..` never climbs out of it, from
			// inside it or from a path that passes through it.
			var storageRoot:Null<String> = @:privateAccess System.__storageRootOrNull();

			if (storageRoot != null) {
				var parts:FilePathParts = FilePath.parse(storageRoot, windows);

				if (parts.root != "" && FilePath.sameRoot(parts.root, base.root, windows)) {
					storage = FilePath.walk([], parts.segments, true, 0);

					if (FilePath.sameSegments(start, storage, windows, storage.length)) {
						floor = storage.length;
					}
				}
			}
		}

		var segments:Array<String> = FilePath.walk(start, target.segments, rooted, floor, storage, windows);
		var result:String = FilePath.join(base.root, segments, windows);

		if (!rooted && result.indexOf(separator) < 0) {
			// A relative File stays one. A bare name says nothing about where
			// the file is and the constructor refuses it, so it is given the
			// directory it is in: this one.
			result = "." + separator + result;
		}

		return new File(result);
	}

	/**
		Saves the data parameter passed to the location of the file.

		@param data The bytes to write: all `length` of them, whatever its `position`.
		@param overwrite Whether to replace a file already there.
		@throws ArgumentError `data` is null.
		@throws IOError A file is there and `overwrite` is false (3002), or the file cannot be written.
	**/
	public function save(data:ByteArray, overwrite:Bool = false):Void {
		// Plain strings were thrown, and every failure to write was "File is
		// open": a missing directory, a permission refused and a full disk all
		// read as that.
		if (data == null) {
			throw new ArgumentError("save needs the data to write.");
		}

		if (exists && overwrite == false) {
			throw __ioError('"$__path" exists, and overwrite is false.', 3002);
		}

		try {
			FileOps.saveBytes(__path, (data : haxe.io.Bytes));
		} catch (e:Dynamic) {
			throw __ioError('Could not write "$__path": ${Std.string(e)}', 0);
		}

		this.__data = data;
	}

	/**
		Returns a reference to a new temporary directory. This is a new directory in the system's
		temporary directory path.

		This method lets you identify a new, unique directory, without having to query the system to
		see that the directory is new and unique.

		You may want to delete the temporary directory before closing the application, since on some
		devices it is not deleted automatically.

		@returns File A File object referencing the new temporary directory.

		The following code uses the createTempFile() method to obtain a reference to a new temporary
		directory.

		```hx
		import crossbyte.io.File;

		var temp:File = File.createTempDirectory();
		trace(temp.nativePath);
		```

		Each time you run this code, a new (unique) file is created.
	**/
	public static function createTempDirectory():File {
		return new File(Path.addTrailingSlash(__createTemp(true)));
	}

	/**
		Returns a reference to a new temporary file. This is a new file in the system's temporary
		directory path.

		This method lets you identify a new, unique file, without having to query the system to see that
		the file is new and unique.

		You may want to delete the temporary file before closing the application, since it is not deleted
		automatically.

		@returns File A File object referencing the new temporary file;

		The following code uses the createTempFile() method to obtain a reference to a new temporary file.

		```hx
		import crossbyte.io.File;

		var temp:File = File.createTempFile();
		trace(temp.nativePath);
		```
	**/
	public static function createTempFile():File {
		return new File(__createTemp(false));
	}

	/**
		 Returns an array of File objects, listing the file system root directories.

		 For example, on Windows this is a list of volumes such as the C: drive and the D: drive. An empty
		 drive, such as a CD or DVD drive in which no disc is inserted, is not included in this array. On Mac
		 OS and Linux, this method always returns the unique root directory for the machine (the "/" directory)

		On file systems for which the root is not readable, such as the Android file system, the properties of
		the returned File object do not always reflect the true value. For example, on Android, the
		spaceAvailable property reports 0.

		@returns Array An array of File objects, listing the root directories.

		The following code outputs a list of root directories:

		```hx
		import crossbyte.io.File;

		var rootDirs:Array<File> = File.getRootDirectories();

		for (dir in rootDirs) {
			trace(dir.nativePath);
		}
		```
	**/
	public static function getRootDirectories():Array<File> {
		if (!System.isWindows) {
			return [new File(separator)];
		}

		var rootDirs:Array<File> = [];

		for (letter in __driveLetters) {
			if (FileSystem.exists(letter)) {
				rootDirs.push(new File(letter));
			}
		}

		return rootDirs;
	}

	/**
		The file system's own path for `path`, every link followed, each
		name in its case on disk, or null when there is no such file, or no
		way here to ask: the interpreter, neko and hl under Windows, whose
		`fullPath` follows no link.
	**/
	@:noCompletion private static function __realPath(path:String):Null<String> {
		#if (js && !nodejs)
		return null;
		#elseif cpp
		var real:String = crossbyte.io._internal.NativeFileSync.realPath(path);
		return real == null || real == "" ? null : real;
		#elseif jvm
		try {
			return java.nio.file.Paths.get(path).toRealPath().toString();
		} catch (_:Dynamic) {
			return null;
		}
		#elseif nodejs
		try {
			return js.Syntax.code("require('fs').realpathSync.native({0})", path);
		} catch (_:Dynamic) {
			return null;
		}
		#else
		if (System.isWindows || !FileSystem.exists(path)) {
			return null;
		}

		try {
			// realpath, on POSIX.
			return FileSystem.fullPath(path);
		} catch (_:Dynamic) {
			return null;
		}
		#end
	}

	@:noCompletion private function __canonicalize(cpath:String, seg:String):String {
		seg = seg.toLowerCase();
		var items:Array<String> = FileSystem.readDirectory(Path.directory(cpath));
		if (items == null) {
			return "";
		}
		for (item in items) {
			if (item.toLowerCase() == seg) {
				seg = item;
				break;
			}
		}

		return seg;
	}

	@:noCompletion private function __dispatchIoError(e:Dynamic):Void {
		if (hasEventListener(IOErrorEvent.IO_ERROR)) {
			if (#if (haxe_ver >= 4.2) Std.isOfType #else Std.is #end (e, Error)) {
				var error = (e : Error);
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, error.message, error.errorID));
			} else {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR));
			}
		} else {
			// if there's no listener, throw it again
			throw e;
		}
	}

	/**
		`FileSystem.readDirectory` does not fail the same way on every target. On hxcpp a
		directory it cannot open comes back as `null` rather than throwing, `sys_read_dir`
		returns `null()` when `FindFirstFileW` hands back `INVALID_HANDLE_VALUE`, and
		iterating that null takes the process down with it, past any `catch` the caller
		wrote. Every listing goes through here so a missing directory raises the same
		catchable `Error` everywhere.
	**/
	@:noCompletion private static function __listPath(path:String):Array<String> {
		var items:Array<String> = null;

		try {
			items = FileSystem.readDirectory(path);
		} catch (e:Dynamic) {
			throw __missingOr(path, e);
		}

		if (items == null) {
			throw __missingOr(path, "it could not be read");
		}
		return items;
	}

	/**
		Deletes `path`, and everything in it if it is a directory. `cancelled`,
		when given, is asked before each entry; what is deleted by then stays
		deleted.
	**/
	@:noCompletion private static function __removePath(path:String, ?cancelled:Void->Bool):Void {
		if (cancelled != null && cancelled()) {
			throw new FileCancelled();
		}

		if (FileSystem.isDirectory(path)) {
			for (item in __listPath(path)) {
				__removePath(Path.join([path, item]), cancelled);
			}
			FileSystem.deleteDirectory(path);
		} else {
			FileSystem.deleteFile(path);
		}
	}

	@:noCompletion private function __formatPath(path:String):String {
		var dirs:Array<String> = [];
		var lastBreak:Int = 0;

		for (i in 0...path.length) {
			var char:String = path.charAt(i);

			if (path.charAt(i) == "\\" || char == "/") {
				if (lastBreak != i) {
					dirs.push(path.substring(lastBreak, i));
				}
				lastBreak = i + 1;
			}
		}

		if (path.length != lastBreak) {
			dirs.push(path.substring(lastBreak, path.length));
		}

		path = "";

		for (dir in dirs) {
			path += '$dir$separator';
		}

		return Path.removeTrailingSlashes(path);
	}

	/**
		Creates a temporary file or directory under a name nobody could have
		guessed, and only if nothing is there already.

		The name came from `Math.random`, 24 bits of it, and the file was
		created after checking the name was free, through a call that follows
		symbolic links. On a shared temporary directory another local user
		could plant links at the names ahead of time, and the next temporary
		file this created was written wherever the link pointed. The name is
		now 64 bits from the platform's secure source, and the file is created
		exclusively, `O_CREAT | O_EXCL | O_NOFOLLOW`, readable by its owner
		only, or `CREATE_NEW`, so a name that is taken, by a link or anything
		else, is passed over for another.

		The interpreter, hl and neko have neither a secure source nor an
		exclusive create here, and fall back to a name drawn from `Std.random`
		and a check. That is unguessable in practice and no more: on a shared
		temporary directory with local users who cannot be trusted, prefer a
		native build.
	**/
	@:noCompletion private static function __createTemp(directory:Bool):String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("There is no temporary directory in a browser, and no environment to name one.");
		#else
		var root:String = __tempRoot();

		if (!FileSystem.exists(root)) {
			FileSystem.createDirectory(root);
		}

		for (_ in 0...100) {
			var path:String = Path.join([root, "ofl" + __tempNonce() + (directory ? "" : ".tmp")]);

			switch (__createExclusive(path, directory)) {
				case 0:
					return path;
				case 1:
					continue;
				default:
					throw new crossbyte.errors.IOError('Could not create a temporary ${directory ? "directory" : "file"} at $path.');
			}
		}

		throw new crossbyte.errors.IOError("Could not find an unused temporary name in " + root + ".");
		#end
	}

	@:noCompletion private static function __tempRoot():String {
		#if (js && !nodejs)
		return "";
		#else
		if (System.isWindows) {
			return Sys.getEnv("TEMP");
		}

		var path:String = Sys.getEnv("TMPDIR");
		return path == null || path == "" ? "/tmp" : path;
		#end
	}

	/**
		Sixteen hex digits from the secure source where there is one.

		Elsewhere four draws of sixteen bits. It was two draws below
		0x7FFFFFFF, and neko's Int is 31 bits: that bound is not an Int there,
		and the native under `Std.random` refused it, so every temporary file
		and directory neko asked for threw, and so did every `Store.put`,
		which drew the same way.
	**/
	@:noCompletion private static function __tempNonce():String {
		if (crossbyte.crypto.SecureRandom.isSupported) {
			var bytes:haxe.io.Bytes = crossbyte.crypto.SecureRandom.getSecureRandomBytes(8);
			return bytes.sub(0, 8).toHex();
		}

		var nonce:String = "";
		for (_ in 0...4) {
			nonce += StringTools.hex(Std.random(0x10000), 4).toLowerCase();
		}
		return nonce;
	}

	/**
		Creates `path` only if nothing is there: `0` when it did, `1` when
		something was, `-1` on any other failure.
	**/
	@:noCompletion private static function __createExclusive(path:String, directory:Bool):Int {
		#if (js && !nodejs)
		return -1;
		#elseif cpp
		return crossbyte.io._internal.NativeFileSync.createExclusive(path, directory);
		#elseif jvm
		try {
			var target = java.nio.file.Paths.get(path);

			if (directory) {
				java.nio.file.Files.createDirectory(target);
			} else {
				java.nio.file.Files.createFile(target);
			}

			if (!System.isWindows) {
				// Owner only, as the other targets make them.
				var permissions = java.nio.file.attribute.PosixFilePermissions.fromString(directory ? "rwx------" : "rw-------");
				java.nio.file.Files.setPosixFilePermissions(target, permissions);
			}

			return 0;
		} catch (_:java.nio.file.FileAlreadyExistsException) {
			return 1;
		} catch (_:Dynamic) {
			return -1;
		}
		#elseif nodejs
		try {
			if (directory) {
				js.node.Fs.mkdirSync(path, cast 0x1C0);
			} else {
				// "wx" is O_CREAT | O_EXCL, which does not follow a link.
				js.node.Fs.closeSync(js.node.Fs.openSync(path, "wx", 0x180));
			}

			return 0;
		} catch (e:Dynamic) {
			return Reflect.field(e, "code") == "EEXIST" ? 1 : -1;
		}
		#else
		if (FileSystem.exists(path)) {
			return 1;
		}

		try {
			if (directory) {
				FileSystem.createDirectory(path);
			} else {
				HaxeFile.saveBytes(path, Bytes.alloc(0));
			}

			return 0;
		} catch (_:Dynamic) {
			return -1;
		}
		#end
	}

	@:noCompletion private function __winGetHiddenAttr():Bool {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Reading a file attribute means shelling out, and a browser has no shell.");
		#elseif cpp
		// GetFileAttributesW. It started `attrib` through cmd.exe for each
		// question, and cmd expanded any %NAME% in the path, so a file with
		// one in its name was asked about under another name.
		return crossbyte.io._internal.NativeFileSync.hidden(__path) == 1;
		#elseif (jvm || java)
		// On Windows the JVM's isHidden is the attribute.
		return new java.io.File(__path).isHidden();
		#else
		// No call for the attribute here, so `attrib` still answers, run
		// directly, not through cmd.exe, which expanded any %NAME% in the
		// path. Node has no sys.io.Process; System's helper runs it there
		// through child_process.
		return __attribSaysHidden(@:privateAccess System.__programOutput("attrib", [__path]));
		#end
	}

	/**
		Whether `attrib`'s answer for one file has the `H` attribute: a letter
		among those before the path, which starts at a drive (`C:\`) or a
		share (`\\`). "File not found - C:\x" has none.
	**/
	@:noCompletion private static function __attribSaysHidden(output:Null<String>):Bool {
		if (output == null) {
			return false;
		}

		var line:String = StringTools.trim(output.split("\n")[0]);
		var drive:Int = line.indexOf(":\\");
		var end:Int = drive > 0 ? drive - 1 : line.indexOf("\\\\");

		if (end < 0) {
			return false;
		}

		return line.substr(0, end).split(" ").indexOf("H") >= 0;
	}

	/**
		The names a path gives, `name`, `extension`, `type`, which need
		nothing from the disk. What the disk says is asked when it is wanted:
		`size`, `modificationDate` and `creationDate` were a snapshot taken
		when the path was set, while `exists` was live, so a File made before
		its file was written reported a size of 0 for good.
	**/
	@:noCompletion private function __updateNames(path:String):Void {
		name = Path.withoutDirectory(path);
		// null for a name with no dot, as documented. It was "", which reads
		// as an extension that happens to be empty, as "name." has.
		extension = name.indexOf(".") < 0 ? null : Path.extension(path);
		type = extension;
	}

	/**
		The file's stat, or an IOError saying why there is none. Dynamic in a
		browser, where the sys package cannot be named and NoFileSystem's
		stat refuses anyway.
	**/
	@:noCompletion private function __stat():#if (js && !nodejs) Dynamic #else sys.FileStat #end {
		var stat:#if (js && !nodejs) Dynamic #else sys.FileStat #end;

		try {
			stat = FileSystem.stat(__path);
		} catch (e:Dynamic) {
			throw __missingOr(__path, e);
		}

		// hxcpp answers a missing file with a stat of zeros rather than a
		// throw. A file or a directory always has its type in `mode`.
		if (stat == null || (stat.mode == 0 && !FileSystem.exists(__path))) {
			throw __missingOr(__path, "it could not be examined");
		}

		return stat;
	}

	#if jvm
	// A Java long as a double, from its two halves: masking with 0xFFFFFFFF
	// masks with -1, an Int, which keeps every bit.
	@:noCompletion private static function __longToFloat(value:haxe.Int64):Float {
		var low:Float = haxe.Int64.getLow(value);
		if (low < 0) {
			low += 4294967296.0;
		}
		return haxe.Int64.getHigh(value) * 4294967296.0 + low;
	}
	#end

	/** An IOError for `path`: 3003 when it is not there, else what went wrong. **/
	@:noCompletion private static function __missingOr(path:String, cause:Dynamic):IOError {
		if (!FileSystem.exists(path)) {
			return __ioError('"$path" does not exist.', 3003);
		}
		return __ioError('Could not examine "$path": ${Std.string(cause)}', 3001);
	}

	/**
		The file's size, exact past 2 GB where the target can say, or an
		IOError. On the interpreter, neko and hl `stat` has an Int size, and
		`__exceedsInt` asks the file whether there is more past it.
	**/
	@:noCompletion private function __sizeNow():Float {
		#if (js && !nodejs)
		return FileSystem.stat(__path).size;
		#elseif cpp
		// One call: the exact size, or -1 when there is no file to measure.
		var size:Float = crossbyte.io._internal.NativeFileSync.size(__path);
		if (size < 0) {
			throw __missingOr(__path, "it could not be examined");
		}
		return size;
		#elseif jvm
		var file = new java.io.File(__path);
		if (!file.exists()) {
			throw __missingOr(__path, "it could not be examined");
		}
		return __longToFloat(file.length());
		#elseif nodejs
		try {
			return (js.node.Fs.statSync(__path).size : Float);
		} catch (e:Dynamic) {
			throw __missingOr(__path, e);
		}
		#else
		var reported:Int = __stat().size;
		return __exceedsInt(__path, reported) ? 2147483648.0 : reported;
		#end
	}

	@:noCompletion private static function get_applicationDirectory():File {
		return new File(System.appDir);
	}

	@:noCompletion private static function get_applicationStorageDirectory():File {
		return new File(System.appStorageDir);
	}

	@:noCompletion private static function get_documentsDirectory():File {
		return new File(System.documentsDir);
	}

	@:noCompletion private static function get_desktopDirectory():File {
		return new File(System.desktopDir);
	}

	@:noCompletion private static function get_userDirectory():File {
		return new File(System.userDir);
	}

	@:noCompletion private function get_creationDate():Null<Date> {
		// When the file was made. It was stat's ctime, which on POSIX is when
		// the file's status last changed: a chmod, a rename, a write moved it
		// on. Windows' ctime is the creation time, which is the one platform
		// where that was right.
		#if (js && !nodejs)
		return FileSystem.stat(__path).ctime;
		#elseif cpp
		var created:Float = crossbyte.io._internal.NativeFileSync.created(__path);
		if (created == -2) {
			throw __missingOr(__path, "it could not be examined");
		}
		return created < 0 ? null : Date.fromTime(created);
		#elseif nodejs
		try {
			var stats:Dynamic = js.node.Fs.statSync(__path);
			var created:Float = stats.birthtimeMs;
			return created > 0 ? Date.fromTime(created) : null;
		} catch (e:Dynamic) {
			throw __missingOr(__path, e);
		}
		#elseif jvm
		try {
			var time:java.nio.file.attribute.FileTime = cast java.nio.file.Files.getAttribute(java.nio.file.Paths.get(__path), "basic:creationTime");
			return Date.fromTime(__longToFloat(time.toMillis()));
		} catch (e:Dynamic) {
			throw __missingOr(__path, e);
		}
		#else
		if (System.isWindows) {
			return __stat().ctime;
		}
		__stat();
		throw new IllegalOperationError("A file's creation time cannot be read on " + #if eval "the interpreter" #elseif neko "neko" #elseif hl "HashLink" #else "this target" #end
			+ " on " + System.PLATFORM + ": its stat reports when the file's status last changed, which is not when it was made. Natively, on the jvm and on Node it is read.");
		#end
	}

	@:noCompletion private function get_data():ByteArray {
		// As documented: an error rather than null when nothing has been
		// loaded, or the load failed.
		if (__data == null) {
			throw new IllegalOperationError("No data: load() or loadAsync() has not completed on this File.");
		}
		return __data;
	}

	@:noCompletion private function get_modificationDate():Date {
		return __stat().mtime;
	}

	@:noCompletion private function get_name():String {
		return name;
	}

	@:noCompletion private function get_size():Int {
		var size:Float = __sizeNow();

		if (size > 2147483647.0) {
			throw new crossbyte.errors.IOError('$__path is larger than 2 GB, which File.size, an Int, cannot state.');
		}

		return Std.int(size);
	}

	/**
		Whether the file is longer than an Int can say, which the size `stat`
		reported cannot answer by itself: a wrap, a clamp and Windows' zero all
		look like ordinary sizes.

		Asked of a 64-bit size where the target has one, and otherwise of the
		file, as the HTTP server does: seek to the reported end and see whether
		there is more.
	**/
	@:noCompletion private static function __exceedsInt(path:String, reported:Int):Bool {
		#if (js && !nodejs)
		return false;
		#elseif cpp
		return crossbyte.io._internal.NativeFileSync.size(path) > 2147483647.0;
		#elseif jvm
		var length:haxe.Int64 = new java.io.File(path).length();
		return length > haxe.Int64.ofInt(0x7FFFFFFF);
		#elseif nodejs
		return (js.node.Fs.statSync(path).size : Float) > 2147483647.0;
		#else
		if (reported < 0) {
			return true;
		}

		try {
			var input = HaxeFile.read(path, true);

			try {
				input.seek(reported, sys.io.FileSeek.SeekBegin);
				input.readByte();
			} catch (_:Dynamic) {
				input.close();
				return false;
			}

			input.close();
			return true;
		} catch (_:Dynamic) {
			return false;
		}
		#end
	}

	@:noCompletion private function get_type():String {
		return type;
	}

	@:noCompletion private function get_nativePath():String {
		return __path;
	}

	@:noCompletion private function set_nativePath(path:String):String {
		// Taken literally. On Windows the first %NAME% in a path was replaced
		// by that environment variable, after resolvePath had normalized it,
		// so a name sent by a peer, "%SystemRoot%" or "%USERPROFILE%",
		// reached a directory the caller had never named, out of a server's
		// root among them. AIR's File expands nothing, and neither does the
		// operating system's own file API.
		if (path.charAt(path.length - 1) == ":" /*|| FileSystem.isDirectory(path)*/) {
			path = Path.addTrailingSlash(path);
		}
		// Refuses a bare name, which says nothing about where the file is. An
		// absolute path always says, whatever Path.directory makes of it: the
		// directory of "/root" is "", because its only separator is the root,
		// so every path one level under "/", a HOME of /root, a working
		// directory of /app, "/" itself, was refused as though it were a
		// bare "root". A relative path with a directory in it is accepted as
		// it always was; callers build those, and resolvePath keeps them so.
		if (Path.directory(path).length == 0 && !Path.isAbsolute(path)) {
			throw new ArgumentError("One of the parameters is invalid.");
		}

		__updateNames(path);

		// Reformat when the path carries the *other* platform's separator, so
		// that what is stored is joined on `separator` throughout.
		return __path = path.indexOf(System.isWindows ? "/" : "\\") > 0 ? __formatPath(path) : path;
	}

	@:noCompletion private function get_exists():Bool {
		return FileSystem.exists(__path);
	}

	@:noCompletion private function get_isHidden():Bool {
		// The dotfile convention is not Windows's, and Windows's attribute is
		// not a convention. Asked at runtime because eval, Node and the JVM
		// all run on Windows without the compiler saying so, and all three
		// used to answer the dotfile question there.
		return System.isWindows ? __winGetHiddenAttr() : name.charAt(0) == ".";
	}

	@:noCompletion private function get_isDirectory():Bool {
		// isDirectory throws an exception if the file doesn't exist
		return FileSystem.exists(__path) && FileSystem.isDirectory(__path);
	}

	@:noCompletion private static function get_lineEnding():String {
		return System.isWindows ? "\r\n" : "\n";
	}

	@:noCompletion private function get_parent():File {
		var path:String = Path.removeTrailingSlashes(__path);

		var lastIndex:Int = path.lastIndexOf(separator);

		// Nothing left above it: "/" strips to "" and "C:\" to "C:". A root's
		// parent is documented as null, and the return below was written to
		// give it, but the adjustment after this ran first and turned -1 into
		// 0, so a root asked for new File("") instead, which throws.
		if (lastIndex == -1) {
			return null;
		}

		// A lone separator is kept, so "/tmp" climbs to "/" and "C:\tmp" to
		// "C:\" rather than to "" and "C:".
		if (lastIndex == path.indexOf(separator)) {
			lastIndex += 1;
		}
		// `(lastIndex - path.length) + path.length` is `lastIndex`; the round
		// trip through the length cancels exactly and always did. That
		// expression is what the "can we optimize this?" note here was
		// pointing at, so it is answered rather than left asked.
		return new File(__path.substring(0, lastIndex));
	}

	/**
	 * Free bytes on the volume holding this path.
	 *
	 * Bytes on every target, which it was not: the POSIX branch returned
	 * `df -k` output unconverted, so one target reported bytes and another
	 * reported kilobytes for the same question.
	 *
	 * Three separate things were wrong here, and all of them answered rather
	 * than failed, a wrong number is worse than an error for a caller asking
	 * "have I room to write this":
	 *
	 * - Windows matched the line containing "Total bytes", which is the
	 *   volume's capacity. `fsutil` prints free space on the line above, as
	 *   "Total free bytes". A 930 GB disk with 75 GB free reported 930 GB.
	 * - POSIX required `df`'s first column to equal this path, but that column
	 *   is the device. It never matched, so the loop fell through and returned
	 *   zero, and zero is a legitimate reading, so nothing looked wrong.
	 * - Node compiled and then threw `ReferenceError: sys is not defined` at
	 *   runtime, because `sys.io.Process` type-checks there (hxnodejs allows
	 *   the `sys` package) and generates nothing.
	 */
	@:noCompletion private function get_spaceAvailable():Float {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Free disk space means asking the filesystem, and a browser has neither a filesystem nor a disk to report on.");
		#elseif cpp
		// GetDiskFreeSpaceEx or statvfs, without starting fsutil or df.
		var bytes:Float = crossbyte.io._internal.NativeFileSync.spaceAvailable(__path);
		return bytes < 0 ? 0 : bytes;
		#elseif (jvm || java)
		// 0 for a path with nothing there, as documented.
		return __longToFloat(new java.io.File(__path).getUsableSpace());
		#elseif nodejs
		// The syscall directly, no shell and no output parsing. Node has had
		// statfsSync since 18.15; older ones are told so rather than handed a
		// zero they cannot distinguish from a full disk.
		var fs:Dynamic = js.Syntax.code("require('fs')");

		if (fs.statfsSync == null) {
			throw new crossbyte.errors.IllegalOperationError("Reading free disk space needs fs.statfsSync, which arrived in Node 18.15; this is " + js.Node.process.version + ".");
		}

		if (!FileSystem.exists(__path)) {
			// As documented, where statfs threw ENOENT.
			return 0;
		}

		var stats:Dynamic = fs.statfsSync(__path);
		return stats.bsize * stats.bavail;
		#else
		if (!FileSystem.exists(__path)) {
			return 0;
		}

		// Sys.systemName(), not `#if windows`. That define says which target the
		// compiler was aimed at, not which machine is running, eval does not
		// set it at all, so on Windows this took the `df` branch, found no df,
		// and reported a full disk as empty. A conditional that is right on
		// four targets and silently wrong on the fifth is worse than a runtime
		// check that is right on all of them.
		var onWindows:Bool = Sys.systemName() == "Windows";
		// fsutil takes a directory, and refused a file's path: every file read
		// as having no room to grow. A file is asked about through the
		// directory it is in.
		var directory:String = !onWindows || FileSystem.isDirectory(__path) ? __path : Path.directory(FileSystem.absolutePath(__path));
		var cmd:String = onWindows ? "fsutil" : "df";
		var args:Array<String> = onWindows ? ["volume", "diskfree", Path.addTrailingSlash(directory)] : ["-k", __path];

		var process:Process = new Process(cmd, args);
		var output:String = process.stdout.readAll().toString();

		// Before close(), not after. Asking a closed process for its exit code
		// raises `process_exit` on eval, which is how this method announced
		// itself the first time anything actually called it.
		var status:Int = process.exitCode();
		process.close();

		if (status > 0) {
			return 0;
		}

		// `g`, or `split` stops at the first match: "/dev/sdd  1055762868 ..."
		// came back as two parts, the row never reached the four a data row
		// needs, and every disk on every non-Windows target read as full.
		// Windows parses fsutil above and never reaches this, which is why
		// the suite was green where it was run and zero everywhere else.
		var whitespace:EReg = ~/\s+/g;

		// An escape rather than a newline typed into the literal, which meant
		// whatever line ending the file was checked out with, a carriage
		// return and a newline in a Windows working tree. Each line is
		// trimmed below, so this handles either.
		for (line in output.split("\n")) {
			var text:String = StringTools.trim(line);

			if (text == "") {
				continue;
			}

			try {
				if (onWindows) {
					// "Total free bytes : 80,872,067,072 ( 75.3 GB)". Matched by
					// its own prefix: the next line, "Total bytes", is the
					// volume's capacity, and an indexOf on that string is what
					// used to return a 930 GB disk as 930 GB free.
					if (StringTools.startsWith(text, "Total free bytes")) {
						var value:String = text.substring(text.indexOf(":") + 1);
						return Std.parseFloat(StringTools.replace(StringTools.trim(value), ",", ""));
					}
				} else {
					// The Available column of the first data row, in 1K blocks.
					// Not matched against this path: df names the device there,
					// so the old comparison never matched and fell through to
					// zero, a reading indistinguishable from a full disk.
					var parts:Array<String> = whitespace.split(text);

					if (parts.length >= 4 && parts[0] != "Filesystem") {
						var blocks:Null<Float> = Std.parseFloat(parts[3]);

						if (blocks != null && !Math.isNaN(blocks)) {
							return blocks * 1024;
						}
					}
				}
			} catch (e:Dynamic) {
				return 0;
			}
		}

		return 0;
		#end
	}
	// #end
}

/** What a cancelled operation throws, to stop where it is; never seen outside File. **/
@:noCompletion
private class FileCancelled {
	public function new() {}
}
