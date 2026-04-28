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

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeoutSeconds;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}
