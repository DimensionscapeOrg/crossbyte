package crossbyte.io;

import crossbyte.events.EventDispatcher;
import crossbyte.events.ThreadEvent;
import haxe.io.Path;
import crossbyte.sys.System;
import crossbyte.sys.Worker;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.Error;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.FileListEvent;
import sys.FileSystem;
import sys.io.File as HaxeFile;
import sys.io.Process;

// @:noCompletion private typedef HaxeFile = sys.io.File;
/**
 * ...
 * @author Christopher Speciale
 */
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
		new File("C:\Documents and Settings\joe\My Documents\test.txt")
	```

	The application storage directory is particularly useful. It gives an application-specific
	storage directory for the AIR application. It is defined by the File.applicationStorageDirectory
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
		The creation date of the file on the local disk. If the object is was
		not populated, a call to get the value of this property returns
		`null`.

		@throws IOError               If the file information cannot be
									  accessed, an exception is thrown with a
									  message indicating a file I/O error.
		@throws IllegalOperationError If the `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful. In this case, the value of
									  the `creationDate` property is `null`.
	**/
	public var creationDate(get, null):Date;

	/**
		The Macintosh creator type of the file, which is only used in Mac OS
		versions prior to Mac OS X. In Windows or Linux, this property is
		`null`. If the FileReference object was not populated, a call to get
		the value of this property returns `null`.

		@throws IllegalOperationError On Macintosh, if the
									  `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful. In this case, the value of
									  the `creator` property is `null`.
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
		The date that the file on the local disk was last modified. If the
		FileReference object was not populated, a call to get the value of
		this property returns `null`.

		@throws IOError               If the file information cannot be
									  accessed, an exception is thrown with a
									  message indicating a file I/O error.
		@throws IllegalOperationError If the `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful. In this case, the value of
									  the `modificationDate` property is
									  `null`.
	**/
	public var modificationDate(get, null):Date;

	/**
		The name of the file on the local disk. If the FileReference object
		was not populated (by a valid call to `FileReference.download()` or `
		FileReference.browse()`), Flash Player throws an error when you try to
		get the value of this property.
		All the properties of a FileReference object are populated by calling
		the `browse()` method. Unlike other FileReference properties, if you
		call the `download()` method, the `name` property is populated when
		the `select` event is dispatched.

		@throws IllegalOperationError If the `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful.
	**/
	public var name(get, null):String;

	/**
		The size of the file on the local disk in bytes. If `size` is 0, an
		exception is thrown.
		_Note:_ In the initial version of ActionScript 3.0, the `size`
		property was defined as a uint object, which supported files with
		sizes up to about 4 GB. It is now implemented as a Number object to
		support larger files.

		@throws IOError               If the file cannot be opened or read, or
									  if a similar error is encountered in
									  accessing the file, an exception is
									  thrown with a message indicating a file
									  I/O error.
		@throws IllegalOperationError If the `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful.
	**/
	public var size(get, null):Int;

	/**
		The file type.
		In Windows or Linux, this property is the file extension. On the
		Macintosh, this property is the four-character file type, which is
		only used in Mac OS versions prior to Mac OS X. If the FileReference
		object was not populated, a call to get the value of this property
		returns `null`.

		For Windows, Linux, and Mac OS X, the file extension ?the portion
		of the `name` property that follows the last occurrence of the dot (.)
		character ?identifies the file type.

		@throws IllegalOperationError If the `FileReference.browse()`,
									  `FileReferenceList.browse()`, or
									  `FileReference.download()` method was
									  not called successfully, an exception is
									  thrown with a message indicating that
									  functions were called in the incorrect
									  sequence or an earlier call was
									  unsuccessful. In this case, the value of
									  the `type` property is `null`.
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

		The url* property for this object uses the app URL scheme (not the file URL scheme). This
		means that the url string is specified starting with "app:" (not "file:"). Also, if you
		create a File object relative to the File.applicationDirectory directory (by using the
		resolvePath() method), the url property of the File object also uses the app URL scheme.
		*The url property is currently unsupported on all targets execpt AIR.

		Note: You cannot write to files or directories that have paths that use the app: URL scheme.
		Also, you cannot delete or create files or folders that have paths that use the app: URL
		scheme. Modifying content in the application directory is a bad practice, for security
		reasons, and is blocked by the operating system on some platforms. If you want to store
		application-specific data, consider using the application storage directory
		(File.applicationStorageDirectory). If you want any of the content in the application
		storage directory to have access to the application-privileged functionality (AIR APIs),
		you can expose that functionality by using a sandbox bridge.

		The applicationDirectory property provides a way to reference the application directory
		that works across platforms. If you set a File object to reference the application
		directory using the nativePath or url property, it will only work on the platform for
		which that path is valid.

		On Android, the nativePath property of a File object pointing to the application directory
		is an empty string. Use the url property to access application files.

	**/
	public static var applicationDirectory(get, never):File;

	/**
		The application's private storage directory.

		Each application has a unique, persistent application storage directory, which is
		created when you first access File.applicationStorageDirectory. This directory is unique
		to each application and user. This directory is a convenient location to store user-specific
		or application-specific data.

		The url property* for this object uses the app-storage URL scheme (not the file URL scheme).
		This means that the url string is specified starting with "app-storage:" (not "file:").
		Also, if you create a File object relative to the File.applicationStoreDirectory directory
		(by using the resolvePath() method), the url of the File object also uses the app-storage
		URL scheme (as in the example).
		*The url property is currently unsupported on all targets execpt AIR.

		The applicationStorageDirectory property provides a way to reference the application
		storage directory that works across platforms. If you set a File object to reference the
		application storage directory using the nativePath or url property, it will only work on
		the platform for which that path is valid.

		The following code creates a File object pointing to the "images" subdirectory of the application storage directory.

		```hx
		import openfl.filesystem.File;

		var tempFiles:File = File.applicationStorageDirectory;
		tempFiles = tempFiles.resolvePath("images/");
		trace(tempFiles.url); // app-storage:/images
		```
	**/
	public static var applicationStorageDirectory(get, never):File;

	// public static var cacheDirectory(get, never):File;
	// TODO

	/**
		The user's desktop directory.

		The desktopDirectory property provides a way to reference the desktop directory that works across platforms. If you
		set a File object to reference the desktop directory using the nativePath or url property, it will only work on the
		platform for which that path is valid.

		If an operating system does not support a desktop directory, a suitable directory in the file system is used instead.

		The following code outputs a list of files and directories contained in the user's desktop directory.

		```hx
		import openfl.filesystem.File;
		var desktop:File = File.desktopDirectory;

		var files:Array = desktop.getDirectoryListing();

		for (var i:uint = 0; i < files.length; i++) {
			trace(files[i].nativePath);
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
		platforms. If you set a File object to reference the documents directory using the nativePath or url
		property, it will only work on the platform for which that path is valid.

		If an operating system does not support a documents directory, a suitable directory in the file system
		is used instead.

		The following code uses the File.documentsDirectory property and the File.createDirectory() method to
		ensure that a directory named "OpenFL Test" exists in the user's documents directory.

		```hx
		import openfl.filesystem.File;

		var directory:File = File.documentsDirectory;
		directory = directory.resolvePath("OpenFL Test");

		File.createDirectory(directory);
		trace(directory.exists); // true
		```
	**/
	public static var documentsDirectory(get, never):File;

	// public var downloaded:Bool;
	// TODO

	/**
		Indicates whether the referenced file or directory exists.  The value is true if the File object points
		to an existing file or directory, false otherwise.

		The following code creates a temporary file, then deletes it and uses the File.exists property to check
		for the existence of the file.

		```hx
		import openfl.filesystem.*;

		var temp:File = File.createTempFile();
		trace(temp.exists); // true
		temp.deleteFile();
		trace(temp.exists); // false
		```
	**/
	public var exists(get, never):Bool;

	// public var icon:Icon;
	// TODO

	/**
		Indicates whether the reference is to a directory.  The value is true if the File object points to a directory; false otherwise.

		The following code creates an array of File objects pointing to files and directories in the user directory and then uses the
		isDirectory property to list only those File objects that point to directories (not to files).

		```hx
		import openfl.filesystem.*;

		var userDirFiles:Array = File.userDirectory.getDirectoryListing();
		for (var i:uint = 0; i < userDirFiles.length; i++) {
			if (userDirFiles[i].isDirectory) {
				trace(userDirFiles[i].nativePath);
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
		import openfl.filesystem.*;

		var userDirFiles:Array = File.userDirectory.getDirectoryListing();
		for (var i:uint = 0; i < userDirFiles.length; i++) {
			if (userDirFiles[i].isHidden) {
				trace(userDirFiles[i].nativePath);
			}
		}
		```
	**/
	public var isHidden(get, never):Bool;

	// public var isPackage:Bool;
	// TODO
	// public var isSymbolicLink:Bool;
	// TODO
	public static var lineEnding(get, never):String;

	// TODO: platform specific

	/**
		The full path in the host operating system representation. On Mac OS and Linux, the forward
		slash (/) character is used as the path separator. However, in Windows, you can set the nativePath
		property by using the forward slash character or the backslash (\) character as the path separator,
		and AIR automatically replaces forward slashes with the appropriate backslash character.

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

		@throws ArgumentError The syntax of the path is invalid.
		@throws SecurityError The caller is not in the application security sandbox.

		The following code shows the difference between the nativePath property and the url property of a File object.
		The comments show results on an example Windows computer.

		```hx
		import openfl.filesystem.File;

		var docs:File = File.documentsDirectory;
		trace(docs.nativePath); // C:\Documents and Settings\turing\My Documents
		trace(docs.url); // file:///C:/Documents%20and%20Settings/turing/My%20Documents
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
		import openfl.filesystem.File;

		var tempFile:File = File.createTempDirectory();
		trace(tempFile.parent.nativePath);
		tempFile.deleteFile();
		```
	**/
	public var parent(get, never):File;

	// public static var permissionStatus:String;
	// TODO
	// public var preventBackup:Bool;
	// TODO

	/**
		The host operating system's path component separator character.

		On Mac OS and Linux, this is the forward slash (`/`) character. On
		Windows, it is the backslash (`\`) character.

		Note: When using the backslash character in a String literal, remember
		to type the character twice (as in `"directory\\file.ext"`). Each pair
		of backslashes in a String literal represent a single backslash in the
		String.
	**/
	public static inline var separator:String = #if windows "\\" #else "/" #end;

	public var spaceAvailable(get, null):Float;

	// TODO
	// public static var systemCharset:String;
	// TODO: platorm specific code?
	// public var url:String;
	// TODO

	/**
		The user's directory.

		On Windows, this is the parent of the My Documents directory (for example, C:\Documents and Settings\userName).
		On Mac OS, it is /Users/userName. On Linux, it is /home/userName.

		The userDirectory property provides a way to reference the user directory that works across platforms. If you
		set the nativePath or url property of a File object directly, it will only work on the platform for which that
		path is valid.

		If an operating system does not support a user directory, a suitable directory in the file system is used
		instead.

		The following code outputs a list of files and directories contained in the root level of the user directory:

		```hx
		import openfl.filesystem.File;

		var files:Array = File.userDirectory.listDirectory();
		for (var i:uint = 0; i < files.length; i++) {
			trace(files[i].nativePath);
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
	@:noCompletion private var __fileStatsDirty:Bool = false;
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
		directory name. Before running this example, create a directory named AIR Test on the desktop of your computer.

		```hx
		import openfl.filesystem.*;

		var path:File = File.desktopDirectory.resolvePath("air test");
		trace(path.nativePath);
		path.canonicalize();
		trace(path.nativePath); // ...\AIR Test
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

		var fields:Array<String> = Type.getInstanceFields(fileClass);
		for (field in fields) {
			try {
				Reflect.setProperty(fileClone, field, Reflect.getProperty(this, field));
			} catch (e:Dynamic) {}
		}
		return fileClone;
	}

	/**
		Copies the file or directory at the location specified by this File object to the location
		specified by the newLocation parameter. The copy process creates any required parent directories
		(if possible). When overwriting files using copyTo(), the file attributes are also overwritten.

		@param newLocation The target location of the new file. Note that this File object specifies the
		resulting (copied) file or directory, not the path to the containing directory.
		@param overwrite If false, the copy fails if the file specified by the target parameter already
		exists. If true, the operation overwrites existing file or directory of the same name.
		@throws IOError The source does not exist; or the source could not be copied to the target; or
		the source and destination refer to the same file or folder and overwrite is set to true. On
		Windows, you cannot copy a file that is open or a directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions.

		The following code shows how to use the copyTo() method to copy a file. Before running this code,
		create a test1.txt file in the AIR Test subdirectory of the documents directory on your computer.
		The resulting copied file is named test2.txt, and it is also in the OpenFL Test subdirectory. When
		you set the overwrite parameter to true, the operation overwrites any existing test2.txt file.

		```haxe
		import openfl.filesystem.File;
		import openfl.events.Event;

		var sourceFile:FileReference = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("OpenFL Test/test1.txt");
		var destination:FileReference = File.documentsDirectory;
		destination = destination.resolvePath("OpenFL Test/test2.txt");

		if (sourceFile.copyTo(destination, true)) {
			trace("Done.");
		}
		```

		The following code shows how to use the copyTo() method to copy a file. Before running this code,
		create a test1.txt file in the OpenFL Test subdirectory of the home directory on your computer. The
		resulting copied file is named test2.txt. The try and catch statements show how to respond to errors.

		```hx
		import openfl.filesystem.File;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("OpenFL Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("OpenFL Test/test2.txt");

		try
		{
			sourceFile.copyTo(destination, true);
		}
		catch (error:Error)
		{
			trace("Error:", error.message);
		}
		```
	**/
	public function copyTo(newLocation:File, overwrite:Bool = false):Void {
		if (!overwrite && FileSystem.exists(newLocation.__path)) {
			throw new Error("Overwrite is false.");
		}
		var newPath:String = newLocation.__path;
		/*
			* What if we had an additional argument, duplicate for copy and move that would
			* work like this below:
			*
			if (!overwrite && FileSystem.exists(newPath))
			{
				var ext:String = Path.extension(newPath);

				if (ext.length > 0)
				{
					ext = '.$ext';
				}

				var newPathWithoutExt:String = Path.withoutExtension(newPath);
				var i:Int = 2;

				while (FileSystem.exists(newPath))
				{
					newPath = newPathWithoutExt + '($i)$ext';
					i++;
				}
		}*/

		try {
			if (isDirectory) {
				FileSystem.createDirectory(newPath);
				var files:Array<File> = getDirectoryListing();
				for (file in files) {
					var newFile = new File(Path.join([newPath, file.name]));
					file.copyTo(newFile);
				}
			} else {
				var newDirectory:String = Path.directory(newPath);
				if (!FileSystem.exists(newDirectory)) {
					FileSystem.createDirectory(newDirectory);
				}
				HaxeFile.copy(__path, newPath);
			}
		} catch (e:Dynamic) {
			throw new Error("File or directory does not exist.", 3003);
		}
		// TODO: Error handing
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
		be sure to create a test1.txt file in the OpenFL Test subdirectory of the documents directory on your computer.
		The resulting copied file is named test2.txt, and it is also in the AIR Test subdirectory. When you set the
		overwrite parameter to true, the operation overwrites any existing test2.txt file.

		```hx
		import openfl.filesystem.File;
		import openfl.events.Event;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("OpenFL Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("OpenFL Test/test2.txt");

		sourceFile.copyToAsync(destination, true);
		sourceFile.addEventListener(Event.COMPLETE, fileCopiedHandler);

		function fileCopiedHandler(event:Event):void {
			trace("Done.");
		}
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

		The following code moves a file named test.txt on the desktop to the OpenFL Test subdirectory of the
		documents directory. The call to the createDirectory() method ensures that the OpenFL Test directory
		exists before the file is moved.

		```hx
		import openfl.filesystem.*;

		var source:File = File.desktopDirectory.resolvePath("test.txt");
		var target:File = File.documentsDirectory.resolvePath("OpenFL Test/test.txt");
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
		import openfl.filesystem.File;

		var directory:File = File.documentsDirectory.resolvePath("Empty Junk Directory/");
		File.createDirectory(directory);
		trace(directory.exists); // true
		directory.deleteDirectory();
		trace(directory.exists); // false
		```
	**/
	public function deleteDirectory(deleteDirectoryContents:Bool = false):Void {
		if (deleteDirectoryContents) {
			var files:Array<File> = getDirectoryListing();

			for (file in files) {
				file.deleteFile();
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
		import openfl.filesystem.*;

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
		import openfl.filesystem.File;

		var directory:File = File.userDirectory;
		var list:Array = directory.getDirectoryListing();
		for (var i:uint = 0; i < list.length; i++) {
			trace(list[i].nativePath);
		}
		```
	**/
	public function getDirectoryListing():Array<File> {
		if (!isDirectory) {
			throw new Error("Not a directory.", 3007);
		}

		var directories:Array<String> = FileSystem.readDirectory(__path);
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
		import openfl.filesystem.File;
		import openfl.events.FileListEvent;

		var directory:File = File.userDirectory;
		directory.getDirectoryListingAsync();
		directory.addEventListener(FileListEvent.DIRECTORY_LISTING, directoryListingHandler);

		function directoryListingHandler(event:FileListEvent):void {
			var list:Array = event.files;
			for (var i:uint = 0; i < list.length; i++) {
				trace(list[i].nativePath);
			}
		}
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
			var directoryItems:Array<String> = FileSystem.readDirectory(__path);

			for (item in directoryItems) {
				files.push(new File(__path + item));
			}
		} catch (e:Dynamic) {
			__fileWorker.sendError(e);
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

		@param ref A File object against which the path is given.
		@param useDotDot  Specifies whether the resulting relative path can use ".." components.
		@returns String The relative path between this file (or directory) and the ref file (or directory), if possible; otherwise null.
		@throws	ArgumentError The reference is null.
		@throws SecurityError The caller is not in the application security sandbox.
	**/
	public function getRelativePath(ref:File, useDotDot:Bool = false):Null<String> {
		var thisPath:Array<String> = __path.split(separator);
		var refPath:Array<String> = ref.__path.split(separator);

		var relatives:Array<String> = [];

		var minLength:Int = Std.int(Math.min(thisPath.length, refPath.length));
		var commonSegments:Int = 0;

		// Count the number of common segments
		while (commonSegments < minLength && thisPath[commonSegments] == refPath[commonSegments]) {
			commonSegments++;
		}

		if (useDotDot) {
			// Add ".." for each segment beyond the common segments
			var numUpSegments:Int = thisPath.length - commonSegments;

			for (i in 0...numUpSegments) {
				relatives.push("..");
			}
		}

		// Add remaining segments from the refPath
		for (j in commonSegments...refPath.length) {
			relatives.push(refPath[j]);
		}

		var relativePath:String = relatives.join(separator);

		return relativePath.length == 0 && ref.__path != __path ? null : relativePath;
	}

	/**
		Loads a file synchronously. The data is loaded into the data property of the File instance.
	**/
	public function load():Void {
		__data = HaxeFile.getBytes(__path);
	}

	/**
		Moves the file or directory at the location specified by this File object to the
		location specified by the destination parameter.

		To rename a file, set the destination parameter to point to a path that is in the
		file's directory, but with a different filename.

		The move process creates any required parent directories (if possible).

		@param newLocation The target location for the move. This object specifies the path to the
		resulting (moved) file or directory, not the path to the containing directory.
		@param overwrite If false, the move fails if the target file already exists. If true, the
		operation overwrites any existing file or directory of the same name.
		@throws	IOError  The source does not exist; or the destination exists and overwrite is set to
		false; or the source file or directory could not be moved to the target location; or the source
		and destination refer to the same file or folder and overwrite is set to true. On Windows, you
		cannot move a file that is open or a directory that contains a file that is open.
		@throws SecurityError The application does not have the necessary permissions to move the file.

		The following code shows how to use the moveTo() method to rename a file. The original filename
		is test1.txt and the resulting filename is test2.txt. Since both the source and destination File
		object point to the same directory (the Apollo Test subdirectory of the user's documents directory),
		the moveTo() method renames the file, rather than moving it to a new directory. Before running this
		code, create a test1.txt file in the OpenFL Test subdirectory of the documents directory on your
		computer. When you set the overwrite parameter to true, the operation overwrites any existing test2.txt
		file.

		```hx
		import openfl.filesystem.File;
		import openfl.events.Event;

		var sourceFile:File = File.documentsDirectory;
		sourceFile = sourceFile.resolvePath("OpenFL Test/test1.txt");
		var destination:File = File.documentsDirectory;
		destination = destination.resolvePath("Apollo Test/test2.txt");

		try
		{
			sourceFile.moveTo(destination, true);
		}
		catch (error:Error)
		{
			trace("Error:" + error.message);
		}
		```
	**/
	public function moveTo(newLocation:File, overwrite:Bool = false):Void {
		if (!overwrite && FileSystem.exists(newLocation.__path)) {
			throw new Error("Overwrite is set to false");
		}
		copyTo(newLocation, overwrite);
		if (isDirectory) {
			deleteDirectory(true);
		} else {
			deleteFile();
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
			point to the same directory (the Apollo Test subdirectory of the user's documents directory), the
			moveToAsync() method renames the file, rather than moving it to a new directory. Before running this
			code, create a test1.txt file in the Apollo Test subdirectory of the documents directory on your
			computer. When you set overwrite parameter to true, the operation overwrites any existing test2.txt file.

			```hx
			import openfl.filesystem.File;
			import openfl.events.Event;

			var sourceFile:File = File.documentsDirectory;
			sourceFile = sourceFile.resolvePath("Apollo Test/test1.txt");
			var destination:File = File.documentsDirectory;
			destination = destination.resolvePath("Apollo Test/test2.txt");

			sourceFile.moveToAsync(destination, true);
			sourceFile.addEventListener(Event.COMPLETE, fileMoveCompleteHandler);

			function fileMoveCompleteHandler(event:Event):void
			{
				trace("Done.")
			}
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

		@param path The path to append to this File object's path (if the path parameter is a relative path); or
		the path to return (if the path parameter is an absolute path).
		@returns File A new File object pointing to the resulting path.
	**/
	public function resolvePath(path:String):File {
		var directoryPath:String = Path.removeTrailingSlashes(__path);
		return new File('$directoryPath$separator$path');
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
			HaxeFile.saveBytes(__path, data);
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
		import openfl.File;

		var temp:File = File.createTempDirectory();
		trace(temp.nativePath);
		```

		Each time you run this code, a new (unique) file is created.
	**/
	public static function createTempDirectory():File {
		var tempPath:String = __getTempPath(true);
		FileSystem.createDirectory(tempPath);
		return new File(tempPath);
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
		import openfl.File;

		var temp:File = File.createTempFile();
		trace(temp.nativePath);
		```
	**/
	public static function createTempFile():File {
		var tempPath:String = __getTempPath(false);
		var directory:String = Path.directory(tempPath);
		FileSystem.createDirectory(directory);
		File.saveBytes(tempPath, haxe.io.Bytes.alloc(0));
		return new File(tempPath);
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
		import flash.filesystem.File;
		var rootDirs:Array = File.getRootDirectories();

		for (var i:uint = 0; i < rootDirs.length; i++) {
			trace(rootDirs[i].nativePath);
		}
		```
	**/
	public static function getRootDirectories():Array<File> {
		#if windows
		var rootDirs:Array<File> = [];
		for (letter in __driveLetters) {
			if (FileSystem.exists(letter)) {
				rootDirs.push(new File(letter));
			}
		}

		return rootDirs;
		#else
		return [new File(separator)];
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

	@:noCompletion private static function __getTempPath(dir:Bool):String {
		var path:String;

		#if windows
		path = Sys.getEnv("TEMP");
		#else
		path = Sys.getEnv("TMPDIR");

		if (path == null) {
			path = "/tmp";
		}
		#end

		var tempPath = "";

		while (FileSystem.exists(tempPath = Path.join([path, "ofl" + Math.round(0xFFFFFF * Math.random())]))) {
			// repeat
		}

		if (dir) {
			return Path.addTrailingSlash(tempPath);
		}

		return tempPath + ".tmp";
	}

	#if windows
	@:noCompletion private function __replaceWindowsEnvVars(path:String):String {
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
	}
	#end

	@:noCompletion private function __winGetHiddenAttr():Bool {
		// TODO don't use the command line for this.... instead we should add support in Lime to use
		// the win api.
		var process:Process = new Process('attrib "$nativePath"');
		var r:String = process.stdout.readLine();

		process.close();

		var s:String = r.split(nativePath)[0];
		var flag:Bool = s.indexOf(" H ") > -1;

		return flag;
	}

	@:noCompletion private function __updateFileStats(?path:String):Void {
		if (path == null) {
			path = __path;
		}

		if (FileSystem.exists(path)) {
			var fileInfo = FileSystem.stat(path);
			creationDate = fileInfo.ctime;
			modificationDate = fileInfo.mtime;
			size = fileInfo.size;
		} else {
			creationDate = null;
			modificationDate = null;
			size = 0;
		}
		extension = Path.extension(path);
		type = extension;
		name = Path.withoutDirectory(path);
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

	@:noCompletion private function get_creationDate():Date {
		if (__fileStatsDirty) {
			__updateFileStats();
		}
		return creationDate;
	}

	@:noCompletion private inline function get_data():ByteArray {
		return __data;
	}

	@:noCompletion private function get_modificationDate():Date {
		if (__fileStatsDirty) {
			__updateFileStats();
		}
		return modificationDate;
	}

	@:noCompletion private function get_name():String {
		if (__fileStatsDirty) {
			__updateFileStats();
		}
		return name;
	}

	@:noCompletion private static inline function get_separator():String {
		#if windows
		return "\\";
		#else
		return "/";
		#end
	}

	@:noCompletion private function get_size():Int {
		if (__fileStatsDirty) {
			__updateFileStats();
		}
		return size;
	}

	@:noCompletion private function get_type():String {
		if (__fileStatsDirty) {
			__updateFileStats();
		}
		return type;
	}

	@:noCompletion private function get_nativePath():String {
		return __path;
	}

	@:noCompletion private function set_nativePath(path:String):String {
		#if windows
		if (path.indexOf("%") > -1) {
			path = __replaceWindowsEnvVars(path);
		}
		#end
		if (path.charAt(path.length - 1) == ":" /*|| FileSystem.isDirectory(path)*/) {
			path = Path.addTrailingSlash(path);
		}
		if (Path.directory(path).length == 0) {
			throw new ArgumentError("One of the parameters is invalid.");
		}

		__updateFileStats(path);

		return __path = path.indexOf(#if windows "/" #else "\\" #end) > 0 ? __formatPath(path) : path;
	}

	@:noCompletion private function get_exists():Bool {
		return FileSystem.exists(__path);
	}

	@:noCompletion private function get_isHidden():Bool {
		#if windows
		return __winGetHiddenAttr();
		#else
		return name.charAt(0) == ".";
		#end
	}

	@:noCompletion private function get_isDirectory():Bool {
		// isDirectory throws an exception if the file doesn't exist
		return FileSystem.exists(__path) && FileSystem.isDirectory(__path);
	}

	@:noCompletion private static function get_lineEnding():String {
		#if windows
		return "\r\n";
		#else
		return "\n";
		#end
	}

	@:noCompletion private function get_parent():File {
		// TODO:Can we optimize this?
		var path:String = Path.removeTrailingSlashes(__path);

		var lastIndex:Int = path.lastIndexOf(separator);
		if (lastIndex == path.indexOf(separator)) {
			lastIndex += 1;
		}
		return lastIndex != -1 ? new File(__path.substring(0, (lastIndex - path.length) + path.length)) : null;
	}

	// #if desktop
	@:noCompletion private function get_spaceAvailable():Float {
		var cmd:String;
		var args:Array<String>;
		#if windows
		cmd = "fsutil";
		args = ["volume", "diskfree", Path.addTrailingSlash(__path)];
		#else
		cmd = "df";
		args = ["-k", __path];
		#end

		var process:Process = new Process(cmd, args);

		var output:String = process.stdout.readAll().toString();
		process.close();

		if (process.exitCode() > 0) {
			return 0;
		}

		var lines = output.split("\n");
		var availableSpace:Float = 0.0;
		var parts:Array<String>;

		for (line in lines) {
			try {
				// Parse the output to extract the available space
				#if windows
				if (line.indexOf("Total bytes") >= 0) {
					parts = line.split(":");
					availableSpace = Std.parseFloat(StringTools.replace(StringTools.trim(parts[1]), ",", ""));
					break;
				}
				#else
				parts = new EReg("\\s+", "").split(line);
				if (parts.length >= 4 && parts[0] == __path) {
					availableSpace = Std.parseFloat(parts[3]);
					break;
				}
				#end
			} catch (e:Dynamic) {
				return 0;
			}
		}
		return availableSpace;
	}

	// #end
}
