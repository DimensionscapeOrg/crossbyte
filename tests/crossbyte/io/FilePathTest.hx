package crossbyte.io;

import crossbyte.io._internal.FilePath;
import utest.Assert;

/**
	The path arithmetic under `File.resolvePath` and `File.getRelativePath`,
	for both platforms on whichever one runs it.

	Asked of the strings directly, so the Windows forms, drives, shares,
	`\\?\`: are checked on the Linux and macOS runners too, which have no
	drive to build a `File` on. `FileTest` checks the same rules through
	`File` on the platform it runs on.
**/
class FilePathTest extends utest.Test {
	public function testDotsAreDroppedAndDotDotConsumesItsParent():Void {
		Assert.equals("/a/c", FilePath.normalize("/a/./b/../c", false));
		Assert.equals("C:\\a\\c", FilePath.normalize("C:\\a\\.\\b\\..\\c", true));
		// Either separator, on either platform: nativePath reads both.
		Assert.equals("/a/c", FilePath.normalize("/a\\b/..\\c", false));
		Assert.equals("C:\\a\\c", FilePath.normalize("C:/a/b/../c", true));
	}

	public function testNoDotDotClimbsPastTheRoot():Void {
		Assert.equals("/x", FilePath.normalize("/../../x", false));
		Assert.equals("/", FilePath.normalize("/a/../..", false));
		Assert.equals("C:\\x", FilePath.normalize("C:\\..\\..\\x", true));
		Assert.equals("C:\\", FilePath.normalize("C:\\a\\..\\..", true));
	}

	public function testASharePairIsTheRootOfAUncPath():Void {
		// The share is the volume: `..` stops at it, as it stops at a drive.
		Assert.equals("\\\\server\\share\\x", FilePath.normalize("\\\\server\\share\\a\\..\\..\\..\\x", true));
		Assert.equals("\\\\server\\share\\x", FilePath.normalize("//server/share/../x", true));
		// \\?\ and \\.\ have the same shape.
		Assert.equals("\\\\?\\C:\\b", FilePath.normalize("\\\\?\\C:\\a\\..\\..\\b", true));
		Assert.equals("\\\\?\\C:\\", FilePath.parse("\\\\?\\C:\\a", true).root);
		Assert.equals("\\\\.\\pipe\\", FilePath.parse("\\\\.\\pipe\\name", true).root);
	}

	public function testWhatCountsAsAbsolute():Void {
		Assert.isTrue(FilePath.isAbsolute("/etc/passwd", false));
		Assert.isFalse(FilePath.isAbsolute("etc/passwd", false));
		// A drive letter means nothing on POSIX, where a colon is a name.
		Assert.isFalse(FilePath.isAbsolute("C:\\Windows", false));

		Assert.isTrue(FilePath.isAbsolute("C:\\Windows", true));
		Assert.isTrue(FilePath.isAbsolute("c:/Windows", true));
		// Relative to drive C's own working directory, which nothing here
		// can see. Taken as C:\, rather than appended to a directory as a
		// name, where Windows would read "x:y" as a stream on a file "x".
		Assert.isTrue(FilePath.isAbsolute("C:Windows", true));
		Assert.equals("C:\\Windows", FilePath.normalize("C:Windows", true));
		Assert.isTrue(FilePath.isAbsolute("\\\\server\\share", true));
		Assert.isTrue(FilePath.isAbsolute("\\Windows", true));
		Assert.isTrue(FilePath.isAbsolute("/Windows", true));
		Assert.isFalse(FilePath.isAbsolute("Windows\\System32", true));
	}

	public function testARelativePathKeepsTheDotDotItCannotResolve():Void {
		// It climbs past the working directory, which the string cannot see.
		Assert.equals("../x", FilePath.normalize("a/../../x", false));
		Assert.equals("..\\..\\x", FilePath.normalize("..\\..\\x", true));
		Assert.equals(".", FilePath.normalize("a/..", false));
	}

	public function testAWalkStopsAtTheStorageRootItPasses():Void {
		var storage:Array<String> = ["home", "u", ".local", "share", "app"];

		// From inside it.
		Assert.same(["home", "u", ".local", "share", "app", "x"], FilePath.walk(storage, ["a", "..", "..", "..", "x"], true, storage.length, storage));
		// From above it, through it: once there, no climbing back out.
		Assert.same(["home", "u", ".local", "share", "app", "x"],
			FilePath.walk(["home", "u"], [".local", "share", "app", "..", "..", "x"], true, 0, storage));
		// From above it, without passing through it, the ordinary rule.
		Assert.same(["home", "x"], FilePath.walk(["home", "u"], ["..", "x"], true, 0, storage));
		// Windows compares names without regard to case.
		Assert.same(["C:", "App", "x"], FilePath.walk(["C:"], ["App", "..", "x"], true, 0, ["c:", "app"], true));
	}

	public function testRelativeAnswersOnlyForWhatIsBelowWithoutDotDot():Void {
		Assert.equals("b/c", FilePath.relative("/a", "/a/b/c", false, false));
		Assert.equals("", FilePath.relative("/a", "/a", false, false));
		Assert.isNull(FilePath.relative("/a/b", "/a/c", false, false));
		Assert.isNull(FilePath.relative("/a/b", "/x", false, false));
		Assert.equals("../c", FilePath.relative("/a/b", "/a/c", true, false));
		Assert.equals("../../x/y", FilePath.relative("/a/b", "/x/y", true, false));
		// A prefix of a name is not a parent: /ab is not inside /a.
		Assert.isNull(FilePath.relative("/a", "/ab", false, false));
		// Normalized first, so a climb dressed as a descendant is caught.
		Assert.isNull(FilePath.relative("/a", "/a/../b", false, false));
		Assert.equals("b", FilePath.relative("/a/./x/..", "/a/b", false, false));
	}

	public function testRelativeUsesForwardSlashesOnWindowsToo():Void {
		Assert.equals("b/c", FilePath.relative("C:\\a", "C:\\a\\b\\c", false, true));
		Assert.equals("../c", FilePath.relative("C:\\a\\b", "C:\\a\\c", true, true));
		// Case is not a difference there. The answer is spelled as the
		// reference spells it.
		Assert.equals("B", FilePath.relative("c:\\A", "C:\\a\\B", false, true));
		// It is everywhere else, and a mismatch reads as outside.
		Assert.isNull(FilePath.relative("/A", "/a/b", false, false));
	}

	public function testRelativeNeverCrossesAVolume():Void {
		Assert.isNull(FilePath.relative("C:\\a", "D:\\a\\b", false, true));
		Assert.isNull(FilePath.relative("C:\\a", "D:\\a\\b", true, true));
		Assert.isNull(FilePath.relative("\\\\s\\one\\a", "\\\\s\\two\\a", true, true));
		Assert.isNull(FilePath.relative("C:\\a", "\\\\s\\share\\a", true, true));
		Assert.equals("b", FilePath.relative("\\\\S\\Share\\a", "\\\\s\\share\\a\\b", false, true));
	}

	public function testRelativeBetweenRelativePaths():Void {
		Assert.equals("c", FilePath.relative("a/b", "a/b/c", false, false));
		Assert.equals("../../x", FilePath.relative("a/b", "x", true, false));
		Assert.equals("../b", FilePath.relative("../a", "../b", true, false));
		// Neither says what the working directory is called.
		Assert.isNull(FilePath.relative("../a", "b", true, false));
	}
}
