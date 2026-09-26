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
	public function testSpaceAvailableReportsFreeBytes():Void {
		// Nothing ever called this, which is how it came to be wrong on every
		// target at once: it reported a Windows volume's total capacity rather
		// than its free space, returned zero on POSIX because it compared df's
		// device column against a path, and threw `ReferenceError: sys is not
		// defined` on Node.
		//
		// A greater-than-zero assertion is what is portably available, the
		// real free figure is not knowable from here without reimplementing the
		// thing under test, and it is enough to catch three of those four:
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
		// under "/", a HOME of /root, which is where HTTPServerConfig's
		// default document root comes from, a working directory of /app, and
		// "/" itself. CI never saw it: the runner's HOME is /home/runner.
		if (System.isWindows) {
			// A drive never had the constructor's problem, the directory of
			// "C:\tmp" is "C:", but its root had parent's: the parent of
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
		// process down, a segfault no `catch` could reach.
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
		// whoever is reading the error looking for the wrong thing entirely,
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
			// NTFS writes out the gap of a file extended past its end, three
			// gigabytes of zeros, unless the file is marked sparse, which
			// nothing here can do. Checked there by hand with a file sized by
			// SetEndOfFile, which allocates without writing.
			Assert.pass();
			return;
		}

		var file = File.createTempFile();
		var output = HaxeFile.write(file.nativePath, true);

		// To 3 GB in two steps, because seek takes an Int. A sparse file on
		// the filesystems that have them, so this costs no disk.
		output.seek(0x7FFFFFFF, sys.io.FileSeek.SeekBegin);
		output.seek(0x40000000, sys.io.FileSeek.SeekCur);
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
		// Created only where nothing is, so whatever holds the name, a file,
		// a directory, a link, is reported and left as it was.
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

		// The old check-then-write saw no file at a dangling link, exists()
		// follows it, and wrote through it, creating the target.
		Assert.equals(1, @:privateAccess File.__createExclusive(link, false));
		Assert.isFalse(sys.FileSystem.exists(target), "the file was created through the link");

		Sys.command("rm", ["-f", link, target]);
	}
	#end

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
			Sys.sleep(0.001);
		}
	}
}
