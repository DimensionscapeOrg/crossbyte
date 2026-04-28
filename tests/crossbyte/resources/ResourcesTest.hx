package crossbyte.resources;

import crossbyte.Resources;
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
}
