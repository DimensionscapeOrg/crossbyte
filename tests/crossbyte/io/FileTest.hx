package crossbyte.io;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.events.Event;
import crossbyte.events.FileListEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.sys.System;
import haxe.io.Bytes;
import sys.io.File as HaxeFile;
import utest.Assert;
import crossbyte.test.Require;

class FileTest extends utest.Test {
	/** The storage directory is created when first asked for: somewhere temporary, then. **/
	public function setupClass():Void {
		StorageSandbox.enter();
	}

	public function teardownClass():Void {
		StorageSandbox.leave();
	}

	public function testACloneHasListenersOfItsOwn():Void {
		// The documentation says registrations are not copied. The clone shared
		// the original's listener map instead, so a listener on either reached
		// both.
		var original = File.applicationDirectory;
		var heardOnOriginal = 0;
		var heardOnCopy = 0;
		// Before cloning, so the original has a listener map for a clone to
		// share: one is made on the first registration.
		original.addEventListener(Event.COMPLETE, _ -> heardOnOriginal++);
		var copy = original.clone();
		copy.addEventListener(Event.COMPLETE, _ -> heardOnCopy++);

		original.dispatchEvent(new Event(Event.COMPLETE));
		Assert.equals(1, heardOnOriginal);
		Assert.equals(0, heardOnCopy, "the clone heard the original's event");

		copy.dispatchEvent(new Event(Event.COMPLETE));
		Assert.equals(1, heardOnOriginal, "the clone carried the original's listener");
		Assert.equals(1, heardOnCopy);

		// And the clone is still the same place.
		Assert.equals(original.nativePath, copy.nativePath);
	}

	public function testSpaceAvailableReportsFreeBytes():Void {
		// Nothing ever called this, which is how it came to be wrong on every
		// target at once: it reported a Windows volume's total capacity rather
		// than its free space, returned zero on POSIX because it compared df's
		// device column against a path, and threw `ReferenceError: sys is not
		// defined` on Node.
		//
		// A greater-than-zero assertion is what is portably available -- the
		// real free figure is not knowable from here without reimplementing the
		// thing under test -- and it is enough to catch three of those four:
		// the POSIX zero, the Node throw, and eval taking the POSIX branch on
		// a Windows machine. The capacity-for-free confusion was found by
		// reading what `fsutil` actually prints.
		var free:Float = File.applicationStorageDirectory.spaceAvailable;

		Assert.isTrue(free > 0, "reported " + free + " bytes free");
		Assert.isFalse(Math.isNaN(free));
		// Bytes, not kilobytes and not blocks. A machine with under a megabyte
		// free would fail this, and would deserve to.
		Assert.isTrue(free > 1024 * 1024, "implausibly small for bytes: " + free);
	}

	public function testParentTrimsTheLastSegment():Void {
		var root = File.createTempDirectory();
		var nested = root.resolvePath("child");

		// Compared without trailing separators: createTempDirectory() hands
		// back a path with one and parent strips it, which is pre-existing and
		// not what this case is about.
		Assert.equals(haxe.io.Path.removeTrailingSlashes(root.nativePath), haxe.io.Path.removeTrailingSlashes(nested.parent.nativePath));

		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	public function testTheRootAndAPathDirectlyUnderIt():Void {
		// Path.directory("/root") is "": the only separator is the root, so
		// Haxe counts no directory at all. The check meant to refuse a bare
		// name took that for one and refused every absolute path a level
		// under "/" -- a HOME of /root, which is where HTTPServerConfig's
		// default document root comes from, a working directory of /app, and
		// "/" itself. CI never saw it: the runner's HOME is /home/runner.
		if (System.isWindows) {
			// A drive never had the constructor's problem -- the directory of
			// "C:\tmp" is "C:" -- but its root had parent's: the parent of
			// "C:\" was new File(""), which throws.
			Assert.equals("C:\\", Require.notNull(new File("C:\\tmp").parent).nativePath);
			Assert.isNull(new File("C:\\").parent);
			return;
		}

		var root = new File("/");
		Assert.equals("/", root.nativePath);
		Assert.equals("", root.name);
		Assert.isNull(root.parent);

		var tmp = new File("/tmp");
		Assert.equals("/tmp", tmp.nativePath);
		Assert.equals("tmp", tmp.name);
		Assert.equals("/", Require.notNull(tmp.parent).nativePath);

		Assert.equals("/tmp", root.resolvePath("tmp").nativePath);
	}

	public function testRootDirectoriesAreDirectoriesWithNoParent():Void {
		// On POSIX this is new File("/"), so it threw before it could return
		// anything. On Windows every drive root was built and then threw from
		// parent, which the documentation says is null for a root.
		var roots = File.getRootDirectories();

		Assert.isTrue(roots.length > 0);

		for (root in roots) {
			Assert.isTrue(root.isDirectory, root.nativePath);
			Assert.isNull(root.parent, root.nativePath);
		}
	}

	public function testABareNameIsStillRefused():Void {
		// What the check is for: nothing in it says where the file is.
		Assert.raises(() -> new File("foo.txt"), ArgumentError);
		// Nor an empty one. It is what Path.removeTrailingSlashes makes of
		// "/", and it is not the root.
		Assert.raises(() -> new File(""), ArgumentError);
	}

	public function testARelativePathWithADirectoryIsStillAccepted():Void {
		// Deliberately left alone. Refusing everything that is not absolute
		// would be the tidier rule, but callers build relative paths:
		// SQLiteConnection.open hands its string straight to new File, a
		// document root of "./public" is the natural way to write one, and
		// resolvePath keeps a relative File relative.
		var file = new File("foo/bar.txt");

		Assert.equals("bar.txt", file.name);
		Assert.equals("foo" + File.separator + "bar.txt", file.nativePath);
	}

	public function testSaveUpdatesExistsAndSize():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("saved.bin");
		var data = ByteArray.fromBytes(Bytes.ofString("hello"));

		try {
			file.save(data);

			Assert.isTrue(file.exists);
			Assert.equals(5, file.size);
			Assert.equals("saved.bin", file.name);
			Assert.equals("bin", file.extension);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testLoadReadsBytesIntoData():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("payload.bin");

		try {
			HaxeFile.saveBytes(file.nativePath, Bytes.ofString("payload"));
			file.load();

			Assert.notNull(file.data);
			Assert.equals(7, file.data.length);
			Assert.equals("payload", file.data.toString());
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testLoadThrowsForMissingFile():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("missing.bin");
		var threw = false;

		try {
			file.load();
		} catch (_:Dynamic) {
			threw = true;
		}

		Assert.isTrue(threw);
		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testLoadAsyncPopulatesDataAndDispatchesComplete():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("payload.bin");
		var completeSeen = false;

		try {
			HaxeFile.saveBytes(file.nativePath, Bytes.ofString("payload"));
			file.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			file.loadAsync();

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.notNull(file.data);
			Assert.equals(7, file.data.length);
			Assert.equals("payload", file.data.toString());
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testLoadAsyncDispatchesIoErrorForMissingFile():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("missing.bin");
		var errorEvent:IOErrorEvent = null;
		var completeSeen = false;

		try {
			file.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> errorEvent = event);
			file.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			file.loadAsync();

			pumpUntil(() -> errorEvent != null || completeSeen, 2.0);

			Assert.notNull(errorEvent);
			Assert.isFalse(completeSeen);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testDeleteDirectoryRecursivelyRemovesNestedContents():Void {
		var root = File.createTempDirectory();
		var nested = root.resolvePath("a").resolvePath("b");
		var file = nested.resolvePath("payload.txt");

		try {
			nested.createDirectory();
			file.save(ByteArray.fromBytes(Bytes.ofString("payload")));

			Assert.isTrue(file.exists);
			root.deleteDirectory(true);
			Assert.isFalse(root.exists);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testMoveToMovesNestedDirectoryContentsAndRemovesSource():Void {
		var source = File.createTempDirectory();
		var nested = source.resolvePath("nested");
		var payload = nested.resolvePath("payload.txt");
		var destinationRoot = File.createTempDirectory();
		var destination = destinationRoot.resolvePath("moved");

		try {
			nested.createDirectory();
			payload.save(ByteArray.fromBytes(Bytes.ofString("payload")));

			source.moveTo(destination, true);

			Assert.isFalse(source.exists);
			Assert.isTrue(destination.exists);
			Assert.isTrue(destination.resolvePath("nested").isDirectory);
			Assert.equals("payload", HaxeFile.getContent(destination.resolvePath("nested").resolvePath("payload.txt").nativePath));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try source.deleteDirectory(true) catch (_:Dynamic) {}
		try destinationRoot.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCopyToOverwriteReplacesExistingFileContents():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source.txt");
		var destination = root.resolvePath("destination.txt");

		try {
			source.save(ByteArray.fromBytes(Bytes.ofString("new")));
			destination.save(ByteArray.fromBytes(Bytes.ofString("old")));

			source.copyTo(destination, true);

			Assert.equals("new", HaxeFile.getContent(destination.nativePath));
			Assert.isTrue(source.exists);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCopyToOverwriteRecursivelyReplacesNestedDirectoryContents():Void {
		var source = File.createTempDirectory();
		var sourceNested = source.resolvePath("nested");
		var sourceFile = sourceNested.resolvePath("payload.txt");
		var destination = File.createTempDirectory();
		var destinationNested = destination.resolvePath("nested");
		var destinationFile = destinationNested.resolvePath("payload.txt");

		try {
			sourceNested.createDirectory();
			destinationNested.createDirectory();
			sourceFile.save(ByteArray.fromBytes(Bytes.ofString("new")));
			destinationFile.save(ByteArray.fromBytes(Bytes.ofString("old")));

			source.copyTo(destination, true);

			Assert.equals("new", HaxeFile.getContent(destinationFile.nativePath));
			Assert.isTrue(sourceFile.exists);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try source.deleteDirectory(true) catch (_:Dynamic) {}
		try destination.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetDirectoryListingAsyncReturnsResolvedChildren():Void {
		var root = File.createTempDirectory();
		var child = root.resolvePath("child.txt");
		var directoryEvent:FileListEvent = null;

		try {
			child.save(ByteArray.fromBytes(Bytes.ofString("payload")));
			root.addEventListener(FileListEvent.DIRECTORY_LISTING, (event:FileListEvent) -> directoryEvent = event);
			root.getDirectoryListingAsync();

			pumpUntil(() -> directoryEvent != null, 2.0);

			Require.notNull(directoryEvent);
			Assert.equals(1, directoryEvent.files.length);
			Assert.equals(child.nativePath, directoryEvent.files[0].nativePath);
			Assert.equals("child.txt", directoryEvent.files[0].name);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCopyToAsyncDispatchesCompleteAndCopiesContents():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source.txt");
		var destination = root.resolvePath("destination.txt");
		var completeSeen = false;

		try {
			source.save(ByteArray.fromBytes(Bytes.ofString("async-copy")));
			source.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			source.copyToAsync(destination, true);

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.isTrue(destination.exists);
			Assert.equals("async-copy", HaxeFile.getContent(destination.nativePath));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testMoveToAsyncDispatchesCompleteAndRemovesSource():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source.txt");
		var destination = root.resolvePath("destination.txt");
		var completeSeen = false;

		try {
			source.save(ByteArray.fromBytes(Bytes.ofString("async-move")));
			source.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			source.moveToAsync(destination, true);

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.isFalse(source.exists);
			Assert.isTrue(destination.exists);
			Assert.equals("async-move", HaxeFile.getContent(destination.nativePath));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testDeleteDirectoryAsyncDispatchesCompleteAndRemovesContents():Void {
		var root = File.createTempDirectory();
		var nested = root.resolvePath("nested");
		var payload = nested.resolvePath("payload.txt");
		var completeSeen = false;

		try {
			nested.createDirectory();
			payload.save(ByteArray.fromBytes(Bytes.ofString("payload")));
			root.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			root.deleteDirectoryAsync(true);

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.isFalse(root.exists);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testDeleteFileAsyncDispatchesCompleteAndRemovesFile():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("payload.txt");
		var completeSeen = false;

		try {
			file.save(ByteArray.fromBytes(Bytes.ofString("payload")));
			file.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			file.deleteFileAsync();

			pumpUntil(() -> completeSeen, 2.0);

			Assert.isTrue(completeSeen);
			Assert.isFalse(file.exists);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCopyToAsyncDispatchesIoErrorWhenOverwriteIsFalse():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source.txt");
		var destination = root.resolvePath("destination.txt");
		var errorEvent:IOErrorEvent = null;
		var completeSeen = false;

		try {
			source.save(ByteArray.fromBytes(Bytes.ofString("source")));
			destination.save(ByteArray.fromBytes(Bytes.ofString("destination")));
			source.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> errorEvent = event);
			source.addEventListener(Event.COMPLETE, (_:Event) -> completeSeen = true);
			source.copyToAsync(destination, false);

			pumpUntil(() -> errorEvent != null || completeSeen, 2.0);

			Assert.notNull(errorEvent);
			Assert.isFalse(completeSeen);
			Assert.equals("destination", HaxeFile.getContent(destination.nativePath));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetDirectoryListingAsyncThrowsForNonDirectory():Void {
		var root = File.createTempDirectory();
		var file = root.resolvePath("payload.txt");
		var threw = false;

		try {
			file.save(ByteArray.fromBytes(Bytes.ofString("payload")));
			file.getDirectoryListingAsync();
		} catch (_:Dynamic) {
			threw = true;
		}

		Assert.isTrue(threw);
		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testDeleteDirectoryOnAMissingPathThrowsInsteadOfCrashing():Void {
		var directory = File.createTempDirectory();
		directory.deleteDirectory(true);
		Assert.isFalse(directory.exists);

		// hxcpp answers a listing of a directory it cannot open with null rather than
		// an exception, so this second call used to iterate null and take the whole
		// process down — a segfault no `catch` could reach.
		Assert.raises(() -> directory.deleteDirectory(true));
		Assert.raises(() -> directory.deleteDirectory(false));
	}

	public function testMoveToLeavesASourceThatCanBeCleanedUpSafely():Void {
		var source = File.createTempDirectory();
		var nested = source.resolvePath("nested");
		var destinationRoot = File.createTempDirectory();
		var destination = destinationRoot.resolvePath("moved");

		try {
			nested.createDirectory();
			nested.resolvePath("payload.txt").save(ByteArray.fromBytes(Bytes.ofString("payload")));
			source.moveTo(destination, true);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		// The shape every one of these cases ends with: tearing down a source that
		// moveTo already removed has to raise, not crash.
		Assert.raises(() -> source.deleteDirectory(true));

		try destinationRoot.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetDirectoryListingOnAMissingPathThrows():Void {
		var directory = File.createTempDirectory();
		directory.deleteDirectory(true);

		Assert.raises(() -> directory.getDirectoryListing());
	}

	public function testCopyToReportsTheRealCauseRatherThanAMissingFile():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source.txt");
		var blocker = root.resolvePath("blocker");

		try {
			source.save(ByteArray.fromBytes(Bytes.ofString("payload")));
			// A file where copyTo will need a directory, so creating the parent
			// of the destination fails for a reason that is not "missing source".
			blocker.save(ByteArray.fromBytes(Bytes.ofString("in the way")));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		var message:String = null;

		try {
			source.copyTo(blocker.resolvePath("nested").resolvePath("copy.txt"), true);
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		Require.notNull(message);
		// The source is right there. Reporting this as "does not exist" sends
		// whoever is reading the error looking for the wrong thing entirely --
		// the same way the null-listing crash presented as a moveTo bug.
		Assert.isFalse(message.indexOf("does not exist") >= 0);
		Assert.isTrue(message.indexOf("source.txt") >= 0);

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCopyToStillReportsAGenuinelyMissingSource():Void {
		var root = File.createTempDirectory();
		var missing = root.resolvePath("not-here.txt");
		var message:String = null;

		try {
			missing.copyTo(root.resolvePath("copy.txt"), true);
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		Require.notNull(message);
		Assert.isTrue(message.indexOf("does not exist") >= 0);

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testASizeAnIntCannotStateThrowsRatherThanAnsweringWrong():Void {
		// File.size is an Int. On Windows native a 3 GB file and a 5 GB one
		// both read as 0, indistinguishable from an empty file; elsewhere the
		// size wrapped or clamped. It throws instead now.
		if (System.isWindows) {
			// NTFS writes out the gap of a file extended past its end -- three
			// gigabytes of zeros -- unless the file is marked sparse, which
			// nothing here can do. Checked there by hand with a file sized by
			// SetEndOfFile, which allocates without writing.
			Assert.pass();
			return;
		}

		var file = File.createTempFile();
		var output = HaxeFile.write(file.nativePath, true);

		// To 3 GB a gigabyte at a time, because seek takes an Int and neko's
		// Int is 31 bits: 0x3FFFFFFF is the most it holds, and a larger step
		// failed inside neko's file_seek. A sparse file on the filesystems
		// that have them, so this costs no disk.
		output.seek(0x3FFFFFFF, sys.io.FileSeek.SeekBegin);
		output.seek(0x3FFFFFFF, sys.io.FileSeek.SeekCur);
		output.seek(0x3FFFFFFF, sys.io.FileSeek.SeekCur);
		output.writeByte(1);
		output.close();

		var probe = new File(file.nativePath);
		var raised:Dynamic = null;

		try {
			Assert.fail("a 3 GB file reported a size of " + probe.size);
		} catch (e:Dynamic) {
			raised = e;
		}

		try file.deleteFile() catch (_:Dynamic) {}

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "not refused with an IOError: " + Std.string(raised));
	}

	public function testTemporaryNamesAreLongAndDoNotRepeat():Void {
		// They were "ofl" and a Math.random number under 2^24, created after
		// checking the name was free, so on a shared /tmp another user could
		// plant links at the names ahead of time.
		var seen = new Map<String, Bool>();
		var files:Array<File> = [];

		for (_ in 0...40) {
			var file = File.createTempFile();
			files.push(file);

			var name:String = haxe.io.Path.withoutDirectory(file.nativePath);
			Assert.isTrue(~/^ofl[0-9a-f]{16}\.tmp$/.match(name), name);
			Assert.isFalse(seen.exists(name), "a temporary name repeated: " + name);
			Assert.isTrue(file.exists);
			seen.set(name, true);
		}

		for (file in files) {
			try file.deleteFile() catch (_:Dynamic) {}
		}

		var directory = File.createTempDirectory();
		var directoryName:String = haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(directory.nativePath));

		Assert.isTrue(~/^ofl[0-9a-f]{16}$/.match(directoryName), directoryName);
		Assert.isTrue(sys.FileSystem.isDirectory(directory.nativePath));

		try directory.deleteDirectory() catch (_:Dynamic) {}
	}

	public function testATemporaryNameThatIsTakenIsLeftAlone():Void {
		// Created only where nothing is, so whatever holds the name -- a file,
		// a directory, a link -- is reported and left as it was.
		var existing = File.createTempFile();
		HaxeFile.saveContent(existing.nativePath, "someone else's");

		Assert.equals(1, @:privateAccess File.__createExclusive(existing.nativePath, false));
		Assert.equals("someone else's", HaxeFile.getContent(existing.nativePath));

		var directory = File.createTempDirectory();
		var directoryPath:String = haxe.io.Path.removeTrailingSlashes(directory.nativePath);

		Assert.equals(1, @:privateAccess File.__createExclusive(directoryPath, true));

		try existing.deleteFile() catch (_:Dynamic) {}
		try directory.deleteDirectory() catch (_:Dynamic) {}
	}

	#if (cpp || jvm)
	public function testATemporaryFileIsNotCreatedThroughAPlantedLink():Void {
		if (System.isWindows) {
			// A symbolic link needs a privilege there that a test run does
			// not have; CREATE_NEW refuses one all the same.
			Assert.pass();
			return;
		}

		var root:String = @:privateAccess File.__tempRoot();
		var stamp:String = StringTools.hex(Std.random(0x7FFFFFFF), 8);
		var target:String = haxe.io.Path.join([root, "cb-planted-target-" + stamp]);
		var link:String = haxe.io.Path.join([root, "cb-planted-" + stamp + ".tmp"]);

		Assert.equals(0, Sys.command("ln", ["-s", target, link]));

		// The old check-then-write saw no file at a dangling link -- exists()
		// follows it -- and wrote through it, creating the target.
		Assert.equals(1, @:privateAccess File.__createExclusive(link, false));
		Assert.isFalse(sys.FileSystem.exists(target), "the file was created through the link");

		Sys.command("rm", ["-f", link, target]);
	}
	#end

	public function testResolvePathNormalizesDotsAndDotDot():Void {
		// It concatenated: "../x" came back as "<dir>\..\x", with the climb
		// still in it for whatever opened the path to act on.
		var root = File.createTempDirectory();
		var base:String = haxe.io.Path.removeTrailingSlashes(root.nativePath);
		var dir = root.resolvePath("a");

		Assert.equals(base + File.separator + "x", dir.resolvePath("../x").nativePath);
		Assert.equals(base + File.separator + "a" + File.separator + "c", dir.resolvePath("./b/../c").nativePath);
		Assert.equals(base + File.separator + "a" + File.separator + "b", dir.resolvePath("b/").nativePath);
		Assert.raises(() -> dir.resolvePath(null), ArgumentError);

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testResolvePathNeverClimbsPastTheFileSystemRoot():Void {
		var top:File = System.isWindows ? new File("C:\\") : new File("/");
		var expected:String = System.isWindows ? "C:\\x" : "/x";

		Assert.equals(expected, top.resolvePath("../../x").nativePath);
		Assert.equals(expected, top.resolvePath("a/../../../x").nativePath);
	}

	public function testResolvePathReturnsAnAbsolutePathAsItIs():Void {
		// It was appended: "<dir>\C:\Windows\win.ini", a path that names a
		// stream on a file called "C" rather than the file asked for.
		var dir = File.createTempDirectory();

		if (System.isWindows) {
			Assert.equals("C:\\x", dir.resolvePath("C:\\Windows\\..\\x").nativePath);
			Assert.equals("C:\\Windows\\win.ini", dir.resolvePath("C:/Windows/win.ini").nativePath);
			// Rooted, with no drive: this File's own.
			var drive:String = dir.nativePath.substr(0, 3);
			Assert.equals(drive + "x", dir.resolvePath("\\x").nativePath);
		} else {
			Assert.equals("/x", dir.resolvePath("/tmp/../x").nativePath);
			Assert.equals("/etc/passwd", dir.resolvePath("/etc/passwd").nativePath);
		}

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testResolvePathNeverClimbsOutOfTheStorageRoot():Void {
		// The documentation's rule, which nothing implemented: a `..` that
		// reaches the application storage root goes no further. Paths only;
		// nothing is created.
		var storage = File.applicationStorageDirectory;
		var top:String = haxe.io.Path.removeTrailingSlashes(storage.nativePath);
		var expected:String = top + File.separator + "x";

		Assert.equals(expected, storage.resolvePath("../x").nativePath);
		Assert.equals(expected, storage.resolvePath("a/../../x").nativePath);
		Assert.equals(expected, storage.resolvePath("a/b/../../../../x").nativePath);
		Assert.equals(expected, storage.resolvePath("sub").resolvePath("../../x").nativePath);

		// Nor a path that passes through it on the way from above.
		var parent = Require.notNull(storage.parent);
		var name:String = storage.name;
		Assert.equals(expected, parent.resolvePath(name + "/../x").nativePath);

		// Climbing from above it without passing through is the ordinary rule.
		Assert.equals(haxe.io.Path.removeTrailingSlashes(parent.nativePath) + File.separator + "y", parent.resolvePath("z/../y").nativePath);
	}

	public function testTheDocumentedCheckRefusesWhatResolvesOutside():Void {
		// resolvePath is not a sandbox -- an absolute path passes through, as
		// AIR's does -- so its documentation shows the check to run.
		var dir = File.createTempDirectory().resolvePath("uploads");
		var outside:String = System.isWindows ? "C:\\Windows\\win.ini" : "/etc/passwd";

		for (hostile in [outside, "../escape.txt", "a/../../escape.txt", "..\\..\\escape.txt"]) {
			Assert.isNull(dir.getRelativePath(dir.resolvePath(hostile)), hostile + " was taken for a path inside");
		}

		Assert.equals("ok/name.txt", dir.getRelativePath(dir.resolvePath("ok/name.txt")));
		Assert.equals("name.txt", dir.getRelativePath(dir.resolvePath("./x/../name.txt")));

		try Require.notNull(dir.parent).deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetRelativePathAnswersNullForWhatIsNotBelow():Void {
		// A sibling came back as its bare name, "c", which reads as a child.
		var root = File.createTempDirectory();
		var a = root.resolvePath("a");
		var b = a.resolvePath("b");
		var c = a.resolvePath("c");

		Assert.isNull(b.getRelativePath(c));
		Assert.isNull(b.getRelativePath(root));
		Assert.equals("../c", b.getRelativePath(c, true));
		Assert.equals("../..", b.getRelativePath(root, true));
		Assert.equals("", b.getRelativePath(b));

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetRelativePathUsesForwardSlashes():Void {
		// The documented separator. It was the platform's: `\` on Windows.
		var root = File.createTempDirectory();
		var deep = root.resolvePath("b").resolvePath("c");

		Assert.equals("b/c", root.getRelativePath(deep));

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetRelativePathRefusesANullReference():Void {
		// It was a null access.
		var root = File.createTempDirectory();
		Assert.raises(() -> root.getRelativePath(null), ArgumentError);
		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testGetRelativePathDoesNotCrossDrives():Void {
		if (!System.isWindows) {
			// One root on POSIX; FilePathTest checks the rule's Windows form
			// on every platform.
			Assert.pass();
			return;
		}

		// "D:\a" and "C:\a" shared no segment, so the answer was the whole
		// of the other path -- a relative path naming another drive.
		var c = new File("C:\\a");
		var d = new File("D:\\a\\b");
		Assert.isNull(c.getRelativePath(d));
		Assert.isNull(c.getRelativePath(d, true));
	}

	public function testCopyToOntoItselfIsRefusedAndKeepsTheFile():Void {
		// The standard library's copy truncates the destination before it
		// reads the source. Onto itself, with overwrite, that emptied the
		// file and reported success.
		var dir = File.createTempDirectory();
		var file = dir.resolvePath("self.txt");
		HaxeFile.saveContent(file.nativePath, "precious data");

		var spellings:Array<File> = [file, new File(file.nativePath), new File(dir.resolvePath("sub").nativePath + File.separator + ".." + File.separator + "self.txt")];

		if (System.isWindows) {
			// The same file to Windows, in another case.
			spellings.push(dir.resolvePath("SELF.TXT"));
		}

		for (same in spellings) {
			for (overwrite in [true, false]) {
				var raised:Dynamic = null;

				try {
					file.copyTo(same, overwrite);
				} catch (e:Dynamic) {
					raised = e;
				}

				Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), 'copyTo(${same.nativePath}, $overwrite) did not raise an IOError: $raised');
				Assert.equals("precious data", HaxeFile.getContent(file.nativePath), 'copyTo(${same.nativePath}, $overwrite) changed the file');
			}
		}

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testMoveToOntoItselfIsRefusedAndKeepsTheFile():Void {
		var dir = File.createTempDirectory();
		var file = dir.resolvePath("self.txt");
		HaxeFile.saveContent(file.nativePath, "precious data");

		for (overwrite in [true, false]) {
			var raised:Dynamic = null;

			try {
				file.moveTo(new File(file.nativePath), overwrite);
			} catch (e:Dynamic) {
				raised = e;
			}

			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), 'moveTo(itself, $overwrite) did not raise an IOError: $raised');
			Assert.equals("precious data", HaxeFile.getContent(file.nativePath));
		}

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testACaseOnlyRenameRenames():Void {
		// On Windows, and macOS by default, "case.txt" and "CASE.txt" are one
		// file. With overwrite, moveTo copied it onto itself -- emptying it --
		// and deleted it; without, it refused, because the destination
		// "existed". There was no way to change a name's case.
		for (overwrite in [false, true]) {
			var dir = File.createTempDirectory();
			HaxeFile.saveContent(dir.resolvePath("case.txt").nativePath, "precious data");

			try {
				dir.resolvePath("case.txt").moveTo(dir.resolvePath("CASE.txt"), overwrite);
			} catch (e:Dynamic) {
				Assert.fail('the rename threw with overwrite $overwrite: $e');
			}

			Assert.same(["CASE.txt"], sys.FileSystem.readDirectory(dir.nativePath), 'overwrite $overwrite');
			Assert.equals("precious data", HaxeFile.getContent(dir.resolvePath("CASE.txt").nativePath));

			try dir.deleteDirectory(true) catch (_:Dynamic) {}
		}
	}

	public function testCopyToRefusesAHardLinkToItself():Void {
		// Two names for one file, which comparing names cannot see.
		var dir = File.createTempDirectory();
		var file = dir.resolvePath("data.txt");
		var link = dir.resolvePath("link.txt");
		HaxeFile.saveContent(file.nativePath, "precious data");

		// fsutil rather than mklink: Process quotes each argument, and cmd
		// does not recognise a quoted "mklink" as its own command.
		var made:Int = System.isWindows ? __quietly("fsutil", ["hardlink", "create", link.nativePath, file.nativePath]) : __quietly("ln",
			[file.nativePath, link.nativePath]);

		if (made != 0 || !link.exists) {
			// No way to make one here; nothing to check.
			Assert.pass();
			try dir.deleteDirectory(true) catch (_:Dynamic) {}
			return;
		}

		Assert.raises(() -> file.copyTo(link, true), crossbyte.errors.IOError);
		Assert.equals("precious data", HaxeFile.getContent(file.nativePath));
		Assert.equals("precious data", HaxeFile.getContent(link.nativePath));

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testMoveToIsARename():Void {
		// It was a copy and a delete: a new file with the old one's bytes.
		// A rename keeps the file itself, which the file system's own name
		// for it -- its index on the volume -- shows where a target reports
		// one.
		var dir = File.createTempDirectory();
		var source = dir.resolvePath("before.txt");
		HaxeFile.saveContent(source.nativePath, "payload");
		var before:Null<String> = crossbyte.io._internal.FileOps.identity(source.nativePath);

		var target = dir.resolvePath("nested").resolvePath("after.txt");
		source.moveTo(target);

		Assert.isFalse(source.exists);
		Assert.equals("payload", HaxeFile.getContent(target.nativePath));

		if (before != null) {
			Assert.equals(before, crossbyte.io._internal.FileOps.identity(target.nativePath), "the file was copied, not renamed");
		}

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testMoveToReplacesAnExistingDirectory():Void {
		var root = File.createTempDirectory();
		var source = root.resolvePath("source");
		var target = root.resolvePath("target");
		source.createDirectory();
		target.createDirectory();
		HaxeFile.saveContent(source.resolvePath("new.txt").nativePath, "new");
		HaxeFile.saveContent(target.resolvePath("old.txt").nativePath, "old");

		Assert.raises(() -> source.moveTo(target, false), crossbyte.errors.IOError);

		source.moveTo(target, true);

		Assert.isFalse(source.exists);
		Assert.same(["new.txt"], sys.FileSystem.readDirectory(target.nativePath));
		// Nothing set aside is left behind.
		Assert.same(["target"], sys.FileSystem.readDirectory(root.nativePath));

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testADirectoryIsNotCopiedOrMovedIntoItself():Void {
		var root = File.createTempDirectory();
		var dir = root.resolvePath("dir");
		dir.createDirectory();
		HaxeFile.saveContent(dir.resolvePath("a.txt").nativePath, "a");

		Assert.raises(() -> dir.copyTo(dir.resolvePath("inner"), true), crossbyte.errors.IOError);
		Assert.raises(() -> dir.moveTo(dir.resolvePath("inner"), true), crossbyte.errors.IOError);
		Assert.same(["a.txt"], sys.FileSystem.readDirectory(dir.nativePath));

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testAMoveToAnotherVolumeCopiesThenDeletes():Void {
		// One volume here, so the second is pretended: the move takes the
		// path a rename cannot, which is the one the old moveTo always took.
		var root = File.createTempDirectory();
		var source = root.resolvePath("source");
		var target = root.resolvePath("target");
		source.resolvePath("deep").createDirectory();
		HaxeFile.saveContent(source.resolvePath("deep").resolvePath("a.txt").nativePath, "a");
		target.createDirectory();
		HaxeFile.saveContent(target.resolvePath("old.txt").nativePath, "old");

		var original = @:privateAccess File.__sameVolume;
		@:privateAccess File.__sameVolume = (_, _, _) -> false;

		try {
			source.moveTo(target, true);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		@:privateAccess File.__sameVolume = original;

		Assert.isFalse(source.exists);
		Assert.same(["deep"], sys.FileSystem.readDirectory(target.nativePath));
		Assert.equals("a", HaxeFile.getContent(target.resolvePath("deep").resolvePath("a.txt").nativePath));
		Assert.same(["target"], sys.FileSystem.readDirectory(root.nativePath));

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testAFailedMovePutsTheReplacedDirectoryBack():Void {
		if (!System.isWindows) {
			// Needs a rename that fails after the target is set aside. Windows
			// refuses to rename a directory with a file open inside it; POSIX
			// does not.
			Assert.pass();
			return;
		}

		var root = File.createTempDirectory();
		var source = root.resolvePath("source");
		var target = root.resolvePath("target");
		source.createDirectory();
		target.createDirectory();
		HaxeFile.saveContent(source.resolvePath("new.txt").nativePath, "new");
		HaxeFile.saveContent(target.resolvePath("old.txt").nativePath, "old");

		var held = HaxeFile.read(source.resolvePath("new.txt").nativePath, true);
		var raised:Dynamic = null;

		try {
			source.moveTo(target, true);
		} catch (e:Dynamic) {
			raised = e;
		}

		held.close();

		if (raised == null) {
			// This file system let it through; nothing was lost either way.
			Assert.isFalse(source.exists);
			Assert.same(["new.txt"], sys.FileSystem.readDirectory(target.nativePath));
		} else {
			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), Std.string(raised));
			Assert.same(["old.txt"], sys.FileSystem.readDirectory(target.nativePath));
			Assert.same(["new.txt"], sys.FileSystem.readDirectory(source.nativePath));
			var left = sys.FileSystem.readDirectory(root.nativePath);
			left.sort(Reflect.compare);
			Assert.same(["source", "target"], left);
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testSizeAndModificationDateAreReadLive():Void {
		// A snapshot taken when the path was set, while `exists` was live: a
		// File made before its file was written reported a size of 0 for good.
		var dir = File.createTempDirectory();
		var path:String = dir.resolvePath("live.txt").nativePath;
		var probe = new File(path);

		try {
			HaxeFile.saveContent(path, "0123456789");
			Assert.equals(10, probe.size);
			var first:Float = probe.modificationDate.getTime();

			HaxeFile.saveContent(path, "01234567890123456789");
			Assert.equals(20, probe.size);
			Assert.isTrue(probe.modificationDate.getTime() >= first);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testAMissingFileThrowsForItsSizeAndDates():Void {
		// As documented. A missing file read a size of 0 -- the size of an
		// empty one -- and null dates.
		var dir = File.createTempDirectory();
		var missing = dir.resolvePath("missing.txt");

		Assert.raises(() -> missing.size, crossbyte.errors.IOError);
		Assert.raises(() -> missing.modificationDate, crossbyte.errors.IOError);
		Assert.raises(() -> missing.creationDate, crossbyte.errors.IOError);

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testCreationDateIsNotTheChangeTime():Void {
		// It was stat's ctime, which on POSIX is when the file's status last
		// changed: rewriting a file moved its "creation date" along with it.
		var file = File.createTempFile();
		HaxeFile.saveContent(file.nativePath, "a");

		#if (eval || neko || hl)
		if (!System.isWindows) {
			// Their stat has no creation time, so they say so.
			Assert.raises(() -> new File(file.nativePath).creationDate, crossbyte.errors.IllegalOperationError);
			try file.deleteFile() catch (_:Dynamic) {}
			return;
		}
		#end

		var created:Null<Date> = new File(file.nativePath).creationDate;

		if (created == null) {
			// A file system that keeps no creation time; nothing to compare.
			Assert.pass();
			try file.deleteFile() catch (_:Dynamic) {}
			return;
		}

		crossbyte.sys.System.sleep(1.1);
		HaxeFile.saveContent(file.nativePath, "abc");
		if (!System.isWindows) {
			Sys.command("chmod", ["600", file.nativePath]);
		}

		var again = new File(file.nativePath);
		Assert.equals(created.getTime(), Require.notNull(again.creationDate).getTime());
		Assert.isTrue(again.modificationDate.getTime() > created.getTime(), "the file was written after it was made");

		try file.deleteFile() catch (_:Dynamic) {}
	}

	public function testOpenWithDefaultApplicationStartsTheSystemsOpener():Void {
		// It was empty. Checked without opening anything: the launch is
		// recorded rather than made.
		var dir = File.createTempDirectory();
		var note = dir.resolvePath("note.txt");
		HaxeFile.saveContent(note.nativePath, "hello");
		var launched:Null<{command:String, args:Array<String>}> = null;

		var original = @:privateAccess File.__launch;
		@:privateAccess File.__launch = (command:String, args:Array<String>) -> launched = {command: command, args: args};

		try {
			note.openWithDefaultApplication();
			// A directory opens in the file manager.
			dir.openWithDefaultApplication();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		@:privateAccess File.__launch = original;

		var expected:String = System.isWindows ? "explorer.exe" : (System.PLATFORM == "mac" ? "open" : "xdg-open");
		Require.notNull(launched);
		Assert.equals(expected, launched.command);
		Assert.equals(1, launched.args.length);
		Assert.equals(haxe.io.Path.removeTrailingSlashes(dir.nativePath), haxe.io.Path.removeTrailingSlashes(launched.args[0]));

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testOpenWithDefaultApplicationRefusesWhatWouldRunAndWhatIsMissing():Void {
		var dir = File.createTempDirectory();
		var launched:Int = 0;
		var original = @:privateAccess File.__launch;
		@:privateAccess File.__launch = (_, _) -> launched++;

		for (name in ["setup.exe", "run.BAT", "install.sh", "tool.jar", "link.lnk"]) {
			var file = dir.resolvePath(name);
			HaxeFile.saveContent(file.nativePath, "x");
			Assert.raises(() -> file.openWithDefaultApplication(), crossbyte.errors.IllegalOperationError, name);
		}

		if (!System.isWindows) {
			// Marked executable, whatever it is called.
			var script = dir.resolvePath("notes.txt");
			HaxeFile.saveContent(script.nativePath, "#!/bin/sh\n");
			Sys.command("chmod", ["755", script.nativePath]);
			Assert.raises(() -> script.openWithDefaultApplication(), crossbyte.errors.IllegalOperationError);
		}

		Assert.raises(() -> dir.resolvePath("missing.txt").openWithDefaultApplication(), crossbyte.errors.IOError);

		@:privateAccess File.__launch = original;
		Assert.equals(0, launched, "something was started");

		try dir.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testTheLauncherStartsAProgramAndDoesNotWaitForIt():Void {
		// The real launcher, with a program that opens nothing: started, left
		// to run, and waited for elsewhere.
		var started:Float = haxe.Timer.stamp();

		try {
			@:privateAccess File.__launch("hostname", []);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		Assert.isTrue(haxe.Timer.stamp() - started < 5.0);

		if (!System.isWindows) {
			// An opener that is not installed is said to be missing, rather
			// than started into nothing.
			Assert.raises(() -> @:privateAccess File.__launch("cb-no-such-opener", []), crossbyte.errors.IllegalOperationError);
		}
	}

	public function testEachPlatformsOpener():Void {
		var command = (platform:String) -> {
			var launch = @:privateAccess File.__defaultApplicationCommand("/x/y.txt", platform);
			return launch == null ? null : launch.command + " " + launch.args.join(" ");
		};

		Assert.equals("explorer.exe /x/y.txt", command("windows"));
		Assert.equals("open /x/y.txt", command("mac"));
		Assert.equals("xdg-open /x/y.txt", command("linux"));
		Assert.equals("xdg-open /x/y.txt", command("freebsd"));
		Assert.isNull(command("browser"));
		Assert.isNull(command("haiku"));
	}

	/** Runs a command with its output kept out of the test report. **/
	private static function __quietly(command:String, args:Array<String>):Int {
		try {
			var process = new sys.io.Process(command, args);
			process.stdout.readAll();
			process.stderr.readAll();
			var code:Int = process.exitCode();
			process.close();
			return code;
		} catch (_:Dynamic) {
			return -1;
		}
	}

	public function testAnOrdinarySizeIsStillReported():Void {
		var file = File.createTempFile();
		HaxeFile.saveBytes(file.nativePath, Bytes.alloc(1234));

		var probe = new File(file.nativePath);
		Assert.equals(1234, probe.size);

		try file.deleteFile() catch (_:Dynamic) {}
	}

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeoutSeconds;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
