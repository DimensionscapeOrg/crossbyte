package crossbyte.io;

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
}
