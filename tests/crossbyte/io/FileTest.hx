package crossbyte.io;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.FileListEvent;
import crossbyte.events.IOErrorEvent;
import haxe.io.Bytes;
import sys.io.File as HaxeFile;
import utest.Assert;

class FileTest extends utest.Test {
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

			Assert.notNull(directoryEvent);
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

		Assert.notNull(message);
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

		Assert.notNull(message);
		Assert.isTrue(message.indexOf("does not exist") >= 0);

		try root.deleteDirectory(true) catch (_:Dynamic) {}
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
