package crossbyte.resources;

import crossbyte.Resources;
import StringTools;
import utest.Assert;

class ResourcesTest extends utest.Test {
	public function testMissingResourceHelpersAreSafe():Void {
		Assert.isFalse(Resources.exists("__missing__.txt"));
		Assert.equals(-1, Resources.resourceSize("__missing__.txt"));
	}

	public function testResourceTreeExistsWithoutResourcesDirectory():Void {
		Assert.notNull(Resources.tree);
		Assert.notNull(Resources.resourcesDir);
	}

	public function testResourceTreeExposesCompileTimePaths():Void {
		Assert.equals("testsuite/sample.txt", Resources.tree.testsuite.sample_txt);
		Assert.equals("testsuite/sample.json", Resources.tree.testsuite.sample_json);
		Assert.equals("testsuite/nested/child.txt", Resources.tree.testsuite.nested.child_txt);
	}

	public function testTextBytesJsonAndLinesLoadResourceContent():Void {
		Assert.isTrue(Resources.exists("testsuite/sample.txt"));
		Assert.equals("alpha\nbeta\ngamma\n", Resources.getText("testsuite/sample.txt"));
		Assert.equals("alpha\nbeta\ngamma\n", Resources.getBytes("testsuite/sample.txt").toString());

		var lines = Resources.getLines("testsuite/sample.txt");
		Assert.same(["alpha", "beta", "gamma"], lines);

		var json:crossbyte.TypedObject<{name:String, count:Int}> = Resources.getJSON("testsuite/sample.json");
		Assert.equals("crossbyte", json.name);
		Assert.equals(3, json.count);
	}

	public function testResourceListingAndAbsolutePathsStayRelativeToResourcesRoot():Void {
		var direct = Resources.listResources("testsuite");
		direct.sort(Reflect.compare);
		Assert.same(["nested", "sample.json", "sample.txt"], direct);

		var recursive = Resources.listResourcesRecursive("testsuite");
		recursive.sort(Reflect.compare);
		Assert.same(["testsuite/nested/child.txt", "testsuite/sample.json", "testsuite/sample.txt"], recursive);

		var absolutePath = StringTools.replace(Resources.getAbsolutePath("testsuite/sample.txt"), "\\", "/");
		Assert.notEquals(-1, absolutePath.indexOf("/resources/"));
		Assert.isTrue(StringTools.endsWith(absolutePath, "/sample.txt"));
		Assert.equals(Resources.getBytes("testsuite/sample.txt").length, Resources.resourceSize("testsuite/sample.txt"));
	}

	/**
		A path that climbs out of the resources directory reads nothing.

		Paths were joined to the directory as given, so a server loading a
		map by the name a client sent, `getText("maps/" + name)`, read
		whatever `"../../config.json"` named. A file is put just outside the
		directory here, so the climb has something real to find.
	**/
	public function testAPathThatClimbsOutOfTheResourcesDirectoryIsRefused():Void {
		var outside:String = Resources.resourcesDir + ".." + crossbyte.io.File.separator + "cb-resources-escape-probe.txt";
		sys.io.File.saveContent(outside, "secret");
		try {
			for (climb in ["../cb-resources-escape-probe.txt", "testsuite/../../cb-resources-escape-probe.txt",
				"testsuite\\..\\..\\cb-resources-escape-probe.txt", "./testsuite/nested/../../../cb-resources-escape-probe.txt"]) {
				Assert.isFalse(Resources.exists(climb), climb + " was found");
				Assert.equals(-1, Resources.resourceSize(climb), climb + " was sized");
				Assert.raises(() -> Resources.getText(climb), crossbyte.errors.SecurityError, climb + " was read as text");
				Assert.raises(() -> Resources.getBytes(climb), crossbyte.errors.SecurityError, climb + " was read as bytes");
				Assert.raises(() -> Resources.getLines(climb), crossbyte.errors.SecurityError, climb + " was read as lines");
				Assert.raises(() -> Resources.getAbsolutePath(climb), crossbyte.errors.SecurityError, climb + " was resolved");
			}
			Assert.raises(() -> Resources.listResources(".."), crossbyte.errors.SecurityError);
			Assert.raises(() -> Resources.listResourcesRecursive("testsuite/../.."), crossbyte.errors.SecurityError);
		} catch (e:haxe.Exception) {
			sys.FileSystem.deleteFile(outside);
			throw e;
		}
		sys.FileSystem.deleteFile(outside);
	}

	/** Absolute paths, drive letters and stream names never name a resource. **/
	public function testAbsolutePathsAndDriveLettersAreRefused():Void {
		// The NUL is made at run time: HashLink reads a string constant only
		// up to its first NUL, so on hl the ".png" after it was never there.
		for (path in ["/etc/passwd", "\\Windows\\win.ini", "\\\\server\\share\\x", "C:/Windows/win.ini", "C:secret.txt",
			"testsuite/sample.txt::$DATA", "file:testsuite/sample.txt", "testsuite/sample.txt" + String.fromCharCode(0) + ".png"]) {
			Assert.isFalse(Resources.exists(path), path + " was found");
			Assert.equals(-1, Resources.resourceSize(path), path + " was sized");
			Assert.raises(() -> Resources.getText(path), crossbyte.errors.SecurityError, path + " was read");
		}
		Assert.isFalse(Resources.exists(null));
	}

	/** What only looks unusual still resolves inside the directory. **/
	public function testHarmlessSpellingsOfAPathStillResolve():Void {
		for (path in ["./testsuite/sample.txt", "testsuite//sample.txt", "testsuite/./sample.txt", "testsuite\\sample.txt"]) {
			Assert.isTrue(Resources.exists(path), path + " was not found");
			Assert.equals("alpha\nbeta\ngamma\n", Resources.getText(path), path + " was not read");
		}
		var listed = Resources.listResourcesRecursive("./testsuite/");
		listed.sort(Reflect.compare);
		Assert.same(["testsuite/nested/child.txt", "testsuite/sample.json", "testsuite/sample.txt"], listed);
	}
}
