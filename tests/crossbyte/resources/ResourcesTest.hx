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
}
