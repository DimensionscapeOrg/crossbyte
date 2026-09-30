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

	/**
		Clearing empties the grid for every reference to it. It replaced the
		rows, so another reference -- the same grid held in two places --
		still saw them.
	**/
	public function testClearIsSeenThroughEveryReference():Void {
		var grid = new crossbyte.ds.Array2D<Int>(2, 2, 7);
		var alias = grid;
		var holder = {grid: grid};
		grid.clear();
		Assert.equals(0, alias.getHeight());
		Assert.equals(0, holder.grid.getHeight());
		Assert.isTrue(alias.isEmpty());
	}

	/**
		`fill` sets every cell. Without a starting value the cells of an
		`Array2D<Int>` are 0 on static targets and null elsewhere; filling
		makes them the same everywhere.
	**/
	public function testFillSetsEveryCell():Void {
		var grid = new crossbyte.ds.Array2D<Int>(3, 2);
		grid.fill(0);
		Assert.same([0, 0, 0, 0, 0, 0], grid.toFlatArray());
		var x:Int = grid.get(2, 1);
		Assert.equals(1, x + 1);
		grid.fill(5);
		Assert.same([5, 5, 5, 5, 5, 5], grid.toFlatArray());
	}
}
