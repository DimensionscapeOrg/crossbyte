package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import haxe.ds.Vector;

/**
 * Ids at positions on a plane, filed into square cells, for things that move.
 *
 * Each id sits on a list belonging to the cell its position falls in, and the
 * list is threaded through arrays indexed by id, so `set` costs the same
 * however much the grid holds: a comparison when the id stays in its cell --
 * which, at any ordinary speed, is nearly every step -- and a relink when it
 * crosses into another. Once the arrays have grown to the largest id, moving
 * allocates nothing. A query visits only the cells its shape overlaps and
 * checks the exact position of everything it finds there.
 *
 * ```haxe
 * // Once, with cells about the size of a view.
 * var grid = new SpatialGrid(0, 0, WORLD_WIDTH, WORLD_HEIGHT, VIEW_RADIUS);
 *
 * // Every tick: move what moved, then ask each observer's question.
 * for (entity in entities) {
 * 	grid.set(entity.slot, entity.x, entity.y);
 * }
 * found.resize(0);
 * grid.queryCircle(observer.x, observer.y, VIEW_RADIUS, found);
 * for (slot in found) {
 * 	observer.interest.add(slot);
 * }
 * ```
 *
 * **Grid or `QuadTree`.** A grid's cost follows how many things share the
 * cells a query touches, so it suits many things spread fairly evenly and
 * moving often, asked about at one radius: entities and their views. A
 * `QuadTree` divides where things are, so it suits uneven crowds and things
 * that hold still, but moving what it holds means building it again -- a
 * cost that grows with everything in it, where a grid's grows only with what
 * crossed a cell.
 *
 * **Cell size.** About the radius most queries use: a circle then touches at
 * most nine cells. Much smaller and a query walks many empty cells; much
 * larger and it checks many ids outside its radius.
 *
 * **Bounds** are for speed, not for correctness. A position outside them is
 * filed in the nearest edge cell and is still found by any query that reaches
 * it -- only more slowly, if much is out there. The grid holds one array
 * entry per cell, so the bounds and cell size decide its size up front.
 *
 * **Ids** are small non-negative integers -- entity slots, say -- as
 * `InterestSet` takes them, so what a query finds can be added to one
 * directly. The grid keeps five array entries for every id up to the largest
 * it has been given.
 *
 * **Threading.** None.
 */
final class SpatialGrid {
	/**
	 * The most cells a grid will make. Each costs an array entry whether or
	 * not anything is in it, so a cell size far smaller than the bounds is
	 * refused rather than allocated.
	 */
	public static inline var MAX_CELLS:Int = 1 << 24;

	/**
	 * How far, in cells, a query reaches past its own edge when choosing the
	 * cells to visit. A position within a rounding error of a cell edge must
	 * not be missed because the query's edge rounded the other way; this is
	 * far above that error and far below anything that visits another cell
	 * for no reason.
	 */
	private static inline var SLACK:Float = 1e-7;

	/**
	 * The width and height of a cell.
	 */
	public var cellSize(default, null):Float;

	/**
	 * Cells across and down.
	 */
	public var columns(default, null):Int;

	public var rows(default, null):Int;

	/**
	 * Ids the grid holds.
	 */
	public var length(default, null):Int = 0;

	private var __left:Float;
	private var __top:Float;
	private var __inverse:Float;

	// The first id on each cell's list, or -1.
	private var __heads:Vector<Int>;

	// Per id: the cell it is in, or -1 while it is not held; its neighbours on
	// that cell's list, -1 at either end; and where it was last put.
	private var __cells:Vector<Int>;
	private var __next:Vector<Int>;
	private var __previous:Vector<Int>;
	private var __xs:Vector<Float>;
	private var __ys:Vector<Float>;

	/**
	 * @param x The left edge of the area most positions fall in.
	 * @param y The top edge.
	 * @param width How far across it is.
	 * @param height How far down.
	 * @param cellSize The width and height of a cell; about the radius most
	 *        queries use.
	 * @param capacity Ids to make room for at the start; the grid grows to fit
	 *        a larger one when it is set.
	 */
	public function new(x:Float, y:Float, width:Float, height:Float, cellSize:Float, capacity:Int = 64) {
		if (!Math.isFinite(x) || !Math.isFinite(y)) {
			throw new ArgumentError("The bounds must start at a finite position.");
		}
		if (!Math.isFinite(width) || !Math.isFinite(height) || !(width > 0) || !(height > 0)) {
			throw new ArgumentError("The bounds must have a finite, positive width and height.");
		}
		if (!Math.isFinite(cellSize) || !(cellSize > 0)) {
			throw new ArgumentError("cellSize must be finite and positive.");
		}
		if (capacity < 0) {
			throw new ArgumentError("capacity cannot be negative.");
		}

		// Counted in Float: a small cell over large bounds overflows an Int
		// long before it is refused for being too many.
		var across:Float = Math.fceil(width / cellSize);
		var down:Float = Math.fceil(height / cellSize);
		if (across * down > MAX_CELLS) {
			throw new ArgumentError('${across} by ${down} cells is more than the ${MAX_CELLS} a grid will make; use a larger cellSize.');
		}

		this.cellSize = cellSize;
		columns = Std.int(across);
		rows = Std.int(down);
		__left = x;
		__top = y;
		__inverse = 1 / cellSize;

		__heads = new Vector<Int>(columns * rows);
		for (i in 0...__heads.length) {
			__heads[i] = -1;
		}

		__cells = new Vector<Int>(0);
		__next = new Vector<Int>(0);
		__previous = new Vector<Int>(0);
		__xs = new Vector<Float>(0);
		__ys = new Vector<Float>(0);
		if (capacity > 0) {
			__grow(capacity);
		}
	}

	/**
	 * Puts `id` at (`x`, `y`): adds it if the grid does not hold it, and moves
	 * it if it does. Costs a comparison when it stays in its cell.
	 */
	public function set(id:Int, x:Float, y:Float):Void {
		if (id < 0) {
			throw new ArgumentError("An id cannot be negative.");
		}
		// A NaN position is in no cell, and every distance to it is NaN, so
		// it could never be found again.
		if (Math.isNaN(x) || Math.isNaN(y)) {
			throw new ArgumentError("A position cannot be NaN.");
		}
		if (id >= __cells.length) {
			__grow(id + 1);
		}

		var cell:Int = __row((y - __top) * __inverse) * columns + __column((x - __left) * __inverse);
		var was:Int = __cells[id];
		if (was != cell) {
			if (was == -1) {
				length++;
			} else {
				__unlink(id, was);
			}
			__link(id, cell);
		}
		__xs[id] = x;
		__ys[id] = y;
	}

	/**
	 * Takes `id` out of the grid.
	 *
	 * @return Whether the grid held it.
	 */
	public function remove(id:Int):Bool {
		if (!has(id)) {
			return false;
		}
		__unlink(id, __cells[id]);
		__cells[id] = -1;
		length--;
		return true;
	}

	public function has(id:Int):Bool {
		return id >= 0 && id < __cells.length && __cells[id] != -1;
	}

	/**
	 * Adds to `found` every id within `radius` of (`x`, `y`), a distance of
	 * exactly `radius` included, in no particular order.
	 *
	 * @param found Where to add them; a new array by default. Handing the same
	 *        one back each tick, emptied, saves allocating another.
	 */
	public function queryCircle(x:Float, y:Float, radius:Float, ?found:Array<Int>):Array<Int> {
		if (found == null) {
			found = [];
		}
		// Negative or NaN: a circle that reaches nothing. A NaN centre is
		// nowhere at all.
		if (!(radius >= 0) || Math.isNaN(x) || Math.isNaN(y)) {
			return found;
		}

		var firstColumn:Int = __column((x - radius - __left) * __inverse - SLACK);
		var lastColumn:Int = __column((x + radius - __left) * __inverse + SLACK);
		var firstRow:Int = __row((y - radius - __top) * __inverse - SLACK);
		var lastRow:Int = __row((y + radius - __top) * __inverse + SLACK);
		var radiusSquared:Float = radius * radius;

		for (row in firstRow...lastRow + 1) {
			var base:Int = row * columns;
			for (column in firstColumn...lastColumn + 1) {
				var id:Int = __heads[base + column];
				while (id != -1) {
					var dx:Float = __xs[id] - x;
					var dy:Float = __ys[id] - y;
					if (dx * dx + dy * dy <= radiusSquared) {
						found.push(id);
					}
					id = __next[id];
				}
			}
		}
		return found;
	}

	/**
	 * Adds to `found` every id inside the rectangle, by the rule
	 * `Rectangle.contains` uses: its left and top edges included, its right
	 * and bottom edges not.
	 *
	 * @param found Where to add them; a new array by default.
	 */
	public function queryRect(x:Float, y:Float, width:Float, height:Float, ?found:Array<Int>):Array<Int> {
		if (found == null) {
			found = [];
		}
		if (!(width > 0) || !(height > 0) || Math.isNaN(x) || Math.isNaN(y)) {
			return found;
		}

		var right:Float = x + width;
		var bottom:Float = y + height;
		var firstColumn:Int = __column((x - __left) * __inverse - SLACK);
		var lastColumn:Int = __column((right - __left) * __inverse + SLACK);
		var firstRow:Int = __row((y - __top) * __inverse - SLACK);
		var lastRow:Int = __row((bottom - __top) * __inverse + SLACK);

		for (row in firstRow...lastRow + 1) {
			var base:Int = row * columns;
			for (column in firstColumn...lastColumn + 1) {
				var id:Int = __heads[base + column];
				while (id != -1) {
					var px:Float = __xs[id];
					var py:Float = __ys[id];
					if (px >= x && py >= y && px < right && py < bottom) {
						found.push(id);
					}
					id = __next[id];
				}
			}
		}
		return found;
	}

	/**
	 * Takes every id out. Costs one pass over the cells and one over the ids
	 * the grid has made room for.
	 */
	public function clear():Void {
		for (i in 0...__heads.length) {
			__heads[i] = -1;
		}
		for (i in 0...__cells.length) {
			__cells[i] = -1;
		}
		length = 0;
	}

	// A position in cell units to the column it falls in. Below the first
	// column counts as the first and past the last as the last, which is what
	// files an out-of-bounds position at the edge and keeps a query that
	// reaches past the bounds from asking for a column that does not exist.
	// `< 1` rather than `< 0` puts the fraction below one straight into column
	// 0 and leaves only positive values for Std.int, which truncates toward
	// zero and so floors exactly those. Infinity lands at an edge like
	// anything else out of bounds.
	private inline function __column(units:Float):Int {
		return units < 1 ? 0 : (units >= columns ? columns - 1 : Std.int(units));
	}

	private inline function __row(units:Float):Int {
		return units < 1 ? 0 : (units >= rows ? rows - 1 : Std.int(units));
	}

	private inline function __link(id:Int, cell:Int):Void {
		var head:Int = __heads[cell];
		__next[id] = head;
		__previous[id] = -1;
		if (head != -1) {
			__previous[head] = id;
		}
		__heads[cell] = id;
		__cells[id] = cell;
	}

	private inline function __unlink(id:Int, cell:Int):Void {
		var previous:Int = __previous[id];
		var next:Int = __next[id];
		if (previous != -1) {
			__next[previous] = next;
		} else {
			__heads[cell] = next;
		}
		if (next != -1) {
			__previous[next] = previous;
		}
	}

	private function __grow(needed:Int):Void {
		var size:Int = __cells.length < 16 ? 16 : __cells.length;
		// Doubling past 2^30 would overflow; past that, exactly what is asked.
		while (size < needed && size < (1 << 30)) {
			size *= 2;
		}
		if (size < needed) {
			size = needed;
		}

		__cells = __resizeInt(__cells, size, -1);
		__next = __resizeInt(__next, size, -1);
		__previous = __resizeInt(__previous, size, -1);
		__xs = __resizeFloat(__xs, size);
		__ys = __resizeFloat(__ys, size);
	}

	// A new vector of `size` holding the old one's entries, the rest set to
	// `fill`. Every entry is written, since a fresh Vector is zeroed on some
	// targets and null on others.
	private static function __resizeInt(old:Vector<Int>, size:Int, fill:Int):Vector<Int> {
		var grown = new Vector<Int>(size);
		for (i in 0...old.length) {
			grown[i] = old[i];
		}
		for (i in old.length...size) {
			grown[i] = fill;
		}
		return grown;
	}

	private static function __resizeFloat(old:Vector<Float>, size:Int):Vector<Float> {
		var grown = new Vector<Float>(size);
		for (i in 0...old.length) {
			grown[i] = old[i];
		}
		for (i in old.length...size) {
			grown[i] = 0;
		}
		return grown;
	}
}
