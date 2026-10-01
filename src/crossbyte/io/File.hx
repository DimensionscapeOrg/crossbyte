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

	* File.applicationStorageDirectory—a storage directory unique to each installed	application
	* File.applicationDirectory—the read-only directory where the application is installed
	(along with any installed assets)
	* File.desktopDirectory—the user's desktop directory
	* File.documentsDirectory—the user's documents directory
	* File.userDirectory—the user directory

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
	@event securityError  		Dispatched when an operation violates a security constraint.

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
		and the file system records a birth time -- natively, on the jvm and
		on Node. `null` where the file system keeps none. On Node it is
		Node's `birthtime`; on the jvm the attribute `creationTime`, which
		before Java 22 on Linux is the modification time, the JVM's own
		fallback. It is never POSIX's `ctime`, which is when the file's status
		last changed -- a chmod, a rename or a write moves it on.

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

		@throws IOError               If the file cannot be opened or read, or
									  if a similar error is encountered in
									  accessing the file, an exception is
									  thrown with a message indicating a file
									  I/O error. In this case, the value of
									  the `data` property is `null`.
		@throws IllegalOperationError If the `load()` method was not called
									  successfully, an exception is thrown
									  with a message indicating that functions
									  were called in the incorrect sequence or
									  an earlier call was unsuccessful. In
									  this case, the value of the `data`
									  property is `null`.
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

		It is the directory the program itself is in -- the executable natively, the jar on the
		jvm, the script on Node, the bytecode file on neko and HashLink -- and not the working
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
		`crossbyte_app_id` define if the build sets one and the main class's full name if not --
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

		On Windows, this is the My Documents directory (for example, C:\Documents and Settings\userName\My
		Documents). On Mac OS, the default location is /Users/userName/Documents. On Linux, the default location
		is /home/userName/Documents (on an English system), and the property observes the xdg-user-dirs setting.

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

		On Windows a path containing `%NAME%` has the first such reference expanded from the
		process environment, so `"%APPDATA%/myapp"` resolves. A name that is not set is left
		as written rather than expanding to nothing, and only the first reference in a path is
		expanded.

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
		@throws SecurityError The caller is not in the application security sandbox.

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

	public var spaceAvailable(get, null):Float;

	/**
		Members of the Adobe AIR `File` API that CrossByte does not implement.

		They were eleven bare `// TODO` markers next to commented-out
		declarations, which recorded that something was missing without
		recording what or why. Listed here so the gap can be judged rather than
		rediscovered:

		- `cacheDirectory` — a per-user cache location distinct from
		  `applicationStorageDirectory`. Implementable: it is a known path per
		  OS. The only reason it is absent is that nothing has needed it.
		- `isSymbolicLink` — needs `lstat`, which the Haxe standard library
		  does not expose. Worth having: `HTTPRequestHandler` contains static
		  serving to its document root by comparing normalized paths, and a
		  symlink pointing out of the root is not visible to a comparison of
		  strings. Following symlinks in a document root is what most servers
		  do by default, so this is a policy CrossByte cannot currently offer
		  rather than a hole it currently has.
		- `url` — the `file://` form of `nativePath`. Small, and unambiguous.
		- `systemCharset` — the operating system's default text encoding.
		  CrossByte reads and writes UTF-8 throughout, so exposing this would
		  invite an encoding this class does not honour anywhere else.
		- `downloaded` — whether the file came from the internet: an NTFS
		  alternate data stream on Windows, a quarantine extended attribute on
		  macOS. Per-OS metadata with no portable meaning.
		- `preventBackup` — an iOS backup exclusion flag. No meaning on the
		  platforms CrossByte targets.
		- `permissionStatus` — AIR's mobile file-access permission model. Same.
		- `isPackage` — whether a directory is a macOS bundle. macOS only.
		- `icon` — needs an `Icon` type and image decoding, neither of which
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
	 */
	public static inline function getFileBytes(path:String):ByteArray {
		return HaxeFile.getBytes(path);
	}

	/**
	 * Reads the contents of a file as a `String`.
	 *
	 * @param path The path to the file.
	 * @return A `String` containing the file's contents.
	 */
	public static inline function getFileText(path:String):String {
		return HaxeFile.getContent(path);
	}

	/**
	 * Saves a `ByteArray` to a file.
	 *
	 * @param path The path where the file should be saved.
	 * @param bytes The `ByteArray` to write to the file.
	 */
	public static inline function saveBytes(path:String, bytes:ByteArray):Void {
		HaxeFile.saveBytes(path, bytes);
	}

	/**
	 * Saves a `String` as a text file.
	 *
	 * @param path The path where the file should be saved.
	 * @param text The `String` content to write to the file.
	 */
	public static inline function saveText(path:String, text:String):Void {
		HaxeFile.saveContent(path, text);
	}

	@:noCompletion private var __data:ByteArray;

	@:noCompletion private static var __driveLetters:Array<String> = [
		"A:\\", "B:\\", "C:\\", "D:\\", "E:\\", "F:\\", "G:\\", "H:\\", "I:\\", "J:\\", "K:\\", "L:\\", "M:\\", "N:\\", "O:\\", "P:\\", "Q:\\", "R:\\",
		"S:\\", "T:\\", "U:\\", "V:\\", "W:\\", "X:\\", "Y:\\", "Z:\\"
	];

	@:noCompletion private var __fileWorker:Worker;
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
		notation.
		@throws ArgumentError The syntax of the path parameter is invalid.
	**/
	public function new(path:String = null) {
		super();

		if (path == null) {
			return;
		}

		nativePath = path;

		if (name.length == 0) {
			var dirs:Array<String> = Path.directory(__path).split(separator);
			name = dirs[dirs.length - 1];
		}
	}

	/**
		Cancels any pending asynchronous operation.
	**/
	public function cancel():Void {
		__fileWorker.cancel();
		dispatchEvent(new Event(Event.CANCEL));
	}

	/**
		Canonicalizes the File path.

		If the File object represents an existing file or directory, canonicalization adjusts the path so that it
		matches the case of the actual file or directory name. If the File object is a symbolic link,
		canonicalization adjusts the path so that it matches the file or directory that the link points to,
		regardless of whether the file or directory that is pointed to exists. On case sensitive file systems (such
		as Linux), when multiple files exist with names differing only in case, the canonicalize() method adjusts
		the path to match the first file found (in an order determined by the file system).

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
		var fileClass:Class<File> = File;

		var fileClone:Dynamic = Type.createEmptyInstance(fileClass);

		// The file's own state, not the dispatcher's. Every instance field was
		// copied, EventDispatcher's included, so the clone shared the original's
		// listener map -- a listener added to either reached both -- and on the
		// dynamic targets the original's bound methods were copied onto the
		// clone too, so `clone.addEventListener` registered on the original.
		var dispatcherFields:Array<String> = Type.getInstanceFields(EventDispatcher);
		var fields:Array<String> = Type.getInstanceFields(fileClass);
		for (field in fields) {
			if (dispatcherFields.indexOf(field) != -1) {
				continue;
			}
			try {
				var value:Dynamic = Reflect.getProperty(this, field);
				if (!Reflect.isFunction(value)) {
					Reflect.setProperty(fileClone, field, value);
				}
			} catch (e:Dynamic) {}
		}

		// What EventDispatcher's constructor would have set.
		var clone:File = fileClone;
		@:privateAccess {
			clone.__eventMap = null;
			clone.__targetDispatcher = null;
			clone.__nextListenerOrder = 0;
			clone.__walking = 0;
		}
		return clone;
	}

	/**
		Copies the file or directory at the location specified by this File object to the location
		specified by the newLocation parameter. The copy process creates any required parent directories
		(if possible). When overwriting files using copyTo(), the file attributes are also overwritten.

		The source and destination are compared as files, not only as names: a name for the same file in
		another case on Windows, a hard link to it, or a path to it through a junction or a symbolic link is
		the same file, and copying a file onto itself is refused whatever `overwrite` says. A directory
		copied onto an existing directory with `overwrite` is merged into it: its files replace those of
		the same name, and the others stay.

		@param newLocation The target location of the new file. Note that this File object specifies the
		resulting (copied) file or directory, not the path to the containing directory.
		@param overwrite If false, the copy fails if the file specified by the target parameter already
		exists. If true, the operation overwrites existing file or directory of the same name.
		@throws IOError The source does not exist; or the source could not be copied to the target; or
		the source and destination refer to the same file or folder; or a directory would be copied into
		itself. On Windows, you cannot copy a file that is open or a directory that contains a file that
		is open.
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
		// spelling of the same file -- its name in another case, a hard
		// link, a path through a junction -- did the same.
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

		__copyPath(__path, newPath, overwrite);
	}

	/** The copy itself, once copyTo has checked the two ends. **/
	@:noCompletion private static function __copyPath(source:String, target:String, overwrite:Bool):Void {
		try {
			if (FileSystem.isDirectory(source)) {
				FileSystem.createDirectory(target);
				for (item in __listPath(source)) {
					var child:String = Path.join([target, item]);

					if (!overwrite && FileSystem.exists(child)) {
						throw __ioError('"$child" exists, and overwrite is false.', 3011);
					}

					__copyPath(Path.join([source, item]), child, overwrite);
				}
			} else {
				var newDirectory:String = Path.directory(target);
				if (newDirectory != "" && !FileSystem.exists(newDirectory)) {
					FileSystem.createDirectory(newDirectory);
				}
				HaxeFile.copy(source, target);
			}
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
		and destination refer to the same file or folder and overwrite is set to true. On Windows, you cannot
		copy a file that is open or a directory that contains a
		file that is open.
		@throws SecurityError The application does not have the necessary permissions to write to the destination.

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
		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);

		__fileWorker.doWork = __asyncCopyWork;
		__fileWorker.run({"newLocation": newLocation, "overwrite": overwrite});
	}

	private function __onWorkerError(e:ThreadEvent):Void {
		__disposeFileWorker();
		__dispatchIoError(e.message);
	}

	private function __onWorkerComplete(e:ThreadEvent):Void {
		__disposeFileWorker();
		dispatchEvent(new Event(Event.COMPLETE));
	}

	private function __asyncCopyWork(m:Dynamic) {
		try {
			copyTo(m.newLocation, m.overwrite);
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
			return;
		}

		__fileWorker.sendComplete();
	}

	private function __disposeFileWorker():Void {
		__fileWorker.removeEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__fileWorker.removeEventListener(ThreadEvent.ERROR, __onWorkerError);
		__fileWorker.cancel();
		__fileWorker = null;
	}

	/**
		Creates the specified directory and any necessary parent directories. If the directory already exists,
		no action is taken.

		@throws	IOError The directory did not exist and could not be created.
		@throws SecurityError The application does not have the necessary permissions.

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
		FileSystem.createDirectory(__path);
	}

	/**
		Deletes the directory.

		@param deleteDirectoryContents Specifies whether or not to delete a directory that contains files or
		subdirectories. When false, if the directory contains files or directories, a call to this method throws
		an exception.
		@throws	IOError The directory does not exist, or the directory could not be deleted. On Windows, you
		cannot delete a directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions to delete the directory.

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
		if (!FileSystem.exists(__path)) {
			throw new Error("File or directory does not exist.", 3003);
		}

		if (deleteDirectoryContents) {
			for (item in __listPath(__path)) {
				__deletePath(Path.join([__path, item]));
			}
		}

		try {
			FileSystem.deleteDirectory(__path);
		} catch (e:Dynamic) {
			throw new Error("Folder is not empty.", 3010);
		}
	}

	/**
		Deletes the directory asynchronously.

		@param deleteDirectoryContents Specifies whether or not to delete a directory that contains files or
		subdirectories. When false, if the directory contains files or directories, a call to this method throws
		an exception.
		@events complete Dispatched when the directory has been deleted successfully.
		@events ioError The directory does not exist or could not be deleted. On Windows, you cannot delete a
		directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions to delete the directory.

	**/
	public function deleteDirectoryAsync(deleteDirectoryContents:Bool = false):Void {
		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);

		__fileWorker.doWork = __asyncDeleteDirWork;
		__fileWorker.run(deleteDirectoryContents);
	}

	private function __asyncDeleteDirWork(deleteDirectoryContents:Bool):Void {
		try {
			deleteDirectory(deleteDirectoryContents);
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
			return;
		}

		__fileWorker.sendComplete();
	}

	/**
		Deletes the file.

		@throws	IOError The directory does not exist, or the directory could not be deleted. On Windows, you
		cannot delete a directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions to delete the directory.

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
		FileSystem.deleteFile(__path);
	}

	/**
		Deletes the file asynchronously.

		@events complete Dispatched when the directory has been deleted successfully.
		@events ioError The directory does not exist or could not be deleted. On Windows, you cannot delete a
		directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions to delete the directory.
	**/
	public function deleteFileAsync():Void {
		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);

		__fileWorker.doWork = __asyncDeleteFileWork;
		__fileWorker.run();
	}

	private function __asyncDeleteFileWork(m:Dynamic):Void {
		try {
			deleteFile();
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
			return;
		}
		__fileWorker.sendComplete();
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
		if (!isDirectory) {
			throw new Error("Not a directory.", 3007);
		}

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
		if (!isDirectory) {
			throw new Error("Not a directory.", 3007);
		}

		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onAsyncGetDirectoryListingWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onAsyncGetDirectoryListingWorkerError);

		__fileWorker.doWork = __asyncGetDirectoryListingWork;
		__fileWorker.run();
	}

	private function __asyncGetDirectoryListingWork(m:Dynamic):Void {
		var files:Array<File> = [];

		try {
			var directoryItems:Array<String> = __listPath(__path);

			for (item in directoryItems) {
				files.push(new File(Path.join([__path, item])));
			}
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
			return;
		}

		__fileWorker.sendComplete(files);
	}

	private function __onAsyncGetDirectoryListingWorkerError(e:ThreadEvent):Void {
		__disposeAsyncGetDirectoryListingWorker();
		__dispatchIoError(e.message);
	}

	private function __onAsyncGetDirectoryListingWorkerComplete(e:ThreadEvent):Void {
		var files:Array<File> = e.message;

		__disposeAsyncGetDirectoryListingWorker();
		dispatchEvent(new FileListEvent(FileListEvent.DIRECTORY_LISTING, files));
	}

	private function __disposeAsyncGetDirectoryListingWorker():Void {
		__fileWorker.removeEventListener(ThreadEvent.COMPLETE, __onAsyncGetDirectoryListingWorkerComplete);
		__fileWorker.removeEventListener(ThreadEvent.ERROR, __onAsyncGetDirectoryListingWorkerError);
		__fileWorker.cancel();
		__fileWorker = null;
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
		to case on Windows and exactly everywhere else -- macOS included,
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
	**/
	public function load():Void {
		__data = HaxeFile.getBytes(__path);
	}

	/**
		Loads a file asynchronously. The file data is stored in the `data` property and a
		`complete` event is dispatched when loading finishes.
	**/
	public function loadAsync():Void {
		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onAsyncLoadWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onAsyncLoadWorkerError);

		__fileWorker.doWork = __asyncLoadWork;
		__fileWorker.run();
	}

	private function __asyncLoadWork(m:Dynamic):Void {
		try {
			var bytes:Bytes = HaxeFile.getBytes(__path);
			__fileWorker.sendComplete(bytes);
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
		}
	}

	private function __onAsyncLoadWorkerError(e:ThreadEvent):Void {
		__disposeAsyncLoadWorker();
		__dispatchIoError(e.message);
	}

	private function __onAsyncLoadWorkerComplete(e:ThreadEvent):Void {
		__data = ByteArray.fromBytes(cast e.message);
		__disposeAsyncLoadWorker();
		dispatchEvent(new Event(Event.COMPLETE));
	}

	private function __disposeAsyncLoadWorker():Void {
		__fileWorker.removeEventListener(ThreadEvent.COMPLETE, __onAsyncLoadWorkerComplete);
		__fileWorker.removeEventListener(ThreadEvent.ERROR, __onAsyncLoadWorkerError);
		__fileWorker.cancel();
		__fileWorker = null;
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
		nothing of it is left behind. With `overwrite`, an existing destination is replaced -- a
		directory as a whole, not merged into -- and is put back if the move fails.

		@param newLocation The target location for the move. This object specifies the path to the
		resulting (moved) file or directory, not the path to the containing directory.
		@param overwrite If false, the move fails if the target file already exists. If true, the
		operation overwrites any existing file or directory of the same name.
		@throws	IOError  The source does not exist; or the destination exists and overwrite is set to
		false; or the source file or directory could not be moved to the target location; or the source
		and destination refer to the same file or folder (other than by a name changed only in case); or
		a directory would be moved into itself. On Windows, you cannot move a file that is open or a
		directory that contains a file that is open.
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
		// It was a copy followed by a delete, always. Onto itself that copy
		// emptied the file; a rename of a name's case -- the same file to
		// Windows and to macOS by default -- copied the file onto itself and
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

		// Anything else in the way -- a directory, or a file a directory is
		// moving onto -- is set aside first, under a name of its own in the
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
				__copyPath(source, target, false);
			} else {
				FileSystem.rename(source, target);
			}
		} catch (e:Dynamic) {
			if (across && FileSystem.exists(target)) {
				try {
					__deletePath(target);
				} catch (_:Dynamic) {}
			}

			if (aside != null) {
				try {
					FileSystem.rename(aside, target);
				} catch (_:Dynamic) {}
			}

			if (Std.isOfType(e, Error)) {
				throw e;
			}

			throw __ioError('Could not move "$source" to "$target": ${Std.string(e)}', 3006);
		}

		if (across) {
			// The copy is whole; only now does the source go.
			try {
				__deletePath(source);
			} catch (e:Dynamic) {
				throw __ioError('Copied "$source" to "$target", on another volume, but could not then delete it: ${Std.string(e)}', 3012);
			}
		}

		if (aside != null) {
			try {
				__deletePath(aside);
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
			or folder and overwrite is set to true. On Windows, you cannot move a file that is open or a directory
			that contains a file that is open.
			@throws SecurityError The application does not have the necessary permissions to move the file.

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
		__fileWorker = new Worker();
		__fileWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__fileWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);

		__fileWorker.doWork = __asyncMoveWork;
		__fileWorker.run({"newLocation": newLocation, "overwrite": overwrite});
	}

	private function __asyncMoveWork(m:Dynamic):Void {
		try {
			moveTo(m.newLocation, m.overwrite);
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
			return;
		}

		__fileWorker.sendComplete();
	}

	/**
		Opens the file in the application registered by the operating system to open this file type.
	**/
	public function openWithDefaultApplication():Void {
		// System.openFile(__path);
	}

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
		out of the storage root by `..` -- it does not stop one that names
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
	**/
	public function save(data:ByteArray, overwrite:Bool = false):Void {
		if (exists && overwrite == false) {
			throw "File exists at this location and overwrite param is false";
			return;
		}
		try {
			HaxeFile.saveBytes(__path, (data : haxe.io.Bytes));
		} catch (e:Dynamic) {
			throw("File is open");
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
		directory it cannot open comes back as `null` rather than throwing — `sys_read_dir`
		returns `null()` when `FindFirstFileW` hands back `INVALID_HANDLE_VALUE` — and
		iterating that null takes the process down with it, past any `catch` the caller
		wrote. Every listing goes through here so a missing directory raises the same
		catchable `Error` everywhere.
	**/
	@:noCompletion private static function __listPath(path:String):Array<String> {
		var items:Array<String> = FileSystem.readDirectory(path);
		if (items == null) {
			throw new Error("File or directory does not exist.", 3003);
		}
		return items;
	}

	@:noCompletion private function __deletePath(path:String):Void {
		if (FileSystem.isDirectory(path)) {
			for (item in __listPath(path)) {
				__deletePath(Path.join([path, item]));
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
		exclusively -- `O_CREAT | O_EXCL | O_NOFOLLOW`, readable by its owner
		only, or `CREATE_NEW` -- so a name that is taken, by a link or anything
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
		and directory neko asked for threw -- and so did every `Store.put`,
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

	@:noCompletion private function __replaceWindowsEnvVars(path:String):String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no process environment to expand a path against.");
		#else
		// Define the regular expression to match the path component to be replaced
		var pattern:EReg = ~/%(.+?)%/;

		// Find the first match of the regular expression in the path
		var match:Bool = pattern.match(path);

		if (match) {
			// Extract the matched path component
			var matchedPath:String = pattern.matched(0);

			// Get the environment variable name by removing the first and last characters ("%")
			var envVar:String = matchedPath.substring(1, matchedPath.length - 1);

			// Get the value of the environment variable
			var envVarValue:Null<String> = Sys.getEnv(envVar);

			if (envVarValue == null) {
				return path;
			}
			// Replace the matched path component with the environment variable value
			return StringTools.replace(path, matchedPath, envVarValue);
		}
		return path;
		#end
	}

	@:noCompletion private function __winGetHiddenAttr():Bool {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Reading a file attribute means shelling out, and a browser has no shell.");
		#else
		// Shelling out to `attrib` costs a process per call. GetFileAttributesW
		// through a `@:cppInclude` bridge would not, in the style the sodium
		// and blake3 bridges already use -- but only on cpp, and this is
		// reachable from every target with a filesystem, so the shell stays
		// until there is a path for the others.
		#if nodejs
		// Node has no sys.io.Process. It type-checks here, because hxnodejs
		// allows the `sys` package, and generates nothing -- the same trap
		// that made spaceAvailable throw `ReferenceError: sys is not defined`
		// once anything called it.
		var r:String = js.Syntax.code("require('child_process').execSync({0}).toString()", 'attrib "' + nativePath + '"');
		#else
		var process:Process = new Process('attrib "$nativePath"');
		var r:String = process.stdout.readLine();

		process.close();
		#end

		var s:String = r.split(nativePath)[0];
		var flag:Bool = s.indexOf(" H ") > -1;

		return flag;
		#end
	}

	/**
		The names a path gives -- `name`, `extension`, `type` -- which need
		nothing from the disk. What the disk says is asked when it is wanted:
		`size`, `modificationDate` and `creationDate` were a snapshot taken
		when the path was set, while `exists` was live, so a File made before
		its file was written reported a size of 0 for good.
	**/
	@:noCompletion private function __updateNames(path:String):Void {
		extension = Path.extension(path);
		type = extension;
		name = Path.withoutDirectory(path);
	}

	/** The file's stat, or an IOError saying why there is none. **/
	@:noCompletion private function __stat():sys.FileStat {
		var stat:sys.FileStat;

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

	@:noCompletion private inline function get_data():ByteArray {
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
		if (System.isWindows && path.indexOf("%") > -1) {
			path = __replaceWindowsEnvVars(path);
		}
		if (path.charAt(path.length - 1) == ":" /*|| FileSystem.isDirectory(path)*/) {
			path = Path.addTrailingSlash(path);
		}
		// Refuses a bare name, which says nothing about where the file is. An
		// absolute path always says, whatever Path.directory makes of it: the
		// directory of "/root" is "", because its only separator is the root,
		// so every path one level under "/" -- a HOME of /root, a working
		// directory of /app, "/" itself -- was refused as though it were a
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
		// 0 -- so a root asked for new File("") instead, which throws.
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
	 * than failed -- a wrong number is worse than an error for a caller asking
	 * "have I room to write this":
	 *
	 * - Windows matched the line containing "Total bytes", which is the
	 *   volume's capacity. `fsutil` prints free space on the line above, as
	 *   "Total free bytes". A 930 GB disk with 75 GB free reported 930 GB.
	 * - POSIX required `df`'s first column to equal this path, but that column
	 *   is the device. It never matched, so the loop fell through and returned
	 *   zero -- and zero is a legitimate reading, so nothing looked wrong.
	 * - Node compiled and then threw `ReferenceError: sys is not defined` at
	 *   runtime, because `sys.io.Process` type-checks there (hxnodejs allows
	 *   the `sys` package) and generates nothing.
	 */
	@:noCompletion private function get_spaceAvailable():Float {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("Free disk space means asking the filesystem, and a browser has neither a filesystem nor a disk to report on.");
		#elseif nodejs
		// The syscall directly, no shell and no output parsing. Node has had
		// statfsSync since 18.15; older ones are told so rather than handed a
		// zero they cannot distinguish from a full disk.
		var fs:Dynamic = js.Syntax.code("require('fs')");

		if (fs.statfsSync == null) {
			throw new crossbyte.errors.IllegalOperationError("Reading free disk space needs fs.statfsSync, which arrived in Node 18.15; this is " + js.Node.process.version + ".");
		}

		var stats:Dynamic = fs.statfsSync(__path);
		return stats.bsize * stats.bavail;
		#else
		// Sys.systemName(), not `#if windows`. That define says which target the
		// compiler was aimed at, not which machine is running -- eval does not
		// set it at all, so on Windows this took the `df` branch, found no df,
		// and reported a full disk as empty. A conditional that is right on
		// four targets and silently wrong on the fifth is worse than a runtime
		// check that is right on all of them.
		var onWindows:Bool = Sys.systemName() == "Windows";
		var cmd:String = onWindows ? "fsutil" : "df";
		var args:Array<String> = onWindows ? ["volume", "diskfree", Path.addTrailingSlash(__path)] : ["-k", __path];

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
		// whatever line ending the file was checked out with -- a carriage
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
					// zero -- a reading indistinguishable from a full disk.
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
