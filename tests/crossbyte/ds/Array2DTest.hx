package crossbyte.ds;

import utest.Assert;

class Array2DTest extends utest.Test {
	public function testDimensionsAndAccess():Void {
		var grid = new crossbyte.ds.Array2D<Int>(2, 3, 7);

		Assert.equals(2, grid.getHeight());
		Assert.equals(3, grid.getWidth());
		Assert.equals(7, grid.get(1, 2));

		grid.set(1, 2, 9);
		Assert.equals(9, grid.get(1, 2));
	}

	public function testFlatArrayAndClone():Void {
		var grid = new crossbyte.ds.Array2D<Int>(2, 2, 1);
		grid.set(0, 1, 2);
		grid.set(1, 0, 3);
		grid.set(1, 1, 4);

		Assert.same([1, 2, 3, 4], grid.toFlatArray());

		var clone = grid.clone();
		clone.set(0, 0, 99);
		Assert.equals(1, grid.get(0, 0));
		Assert.equals(99, clone.get(0, 0));
	}

	public function testClearAndEmpty():Void {
		var grid = new crossbyte.ds.Array2D<String>(1, 1, "x");
		Assert.isFalse(grid.isEmpty());

		grid.clear();
		Assert.isTrue(grid.isEmpty());
	}
}
