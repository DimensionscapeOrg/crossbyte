package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.utils.Hash;
import haxe.ds.Vector;

/**
 * `SpatialGrid` with no bounds: ids at positions on a plane, filed into
 * square cells that exist only where something is. A spatial hash, the
 * conventional index for an open world, where a dense grid would need an
 * array entry for every cell of a rectangle fixed up front.
 *
 * Each id sits on a list belonging to its cell, threaded through arrays
 * indexed by id as in `SpatialGrid`, and the cells that hold something are
 * found by their coordinates in a hash table. So `set` costs a comparison
 * when an id stays in its cell, and a lookup or two when it crosses into
 * another; a query looks up each cell its shape overlaps, or walks the cells
 * held when it overlaps more cells than are held, and checks the exact
 * position of everything it finds there. A cell that empties is let go, and
 * made again when something comes back to it.
 *
 * ```haxe
 * // Once, with cells about the size of a view.
 * final grid = new SparseSpatialGrid(VIEW_RADIUS);
 * final found = new IdList();
 *
 * // Every tick: move what moved, then ask each observer's question.
 * for (entity in entities) {
 * 	grid.set(entity.slot, entity.x, entity.y);
 * }
 * found.clear();
 * grid.queryCircleIds(observer.x, observer.y, VIEW_RADIUS, found);
 * ```
 *
 * **This or `SpatialGrid`.** The same questions, answered the same way, where
 * things may be anywhere: a world with no edge, or one too large for an array
 * entry per cell, or a few crowds far apart in empty space. Where the world
 * has bounds that hold most of it, `SpatialGrid` is cheaper: it finds a cell
 * by its index where this hashes its coordinates. Moving costs about the same
 * (an id that stays in its cell is a comparison either way), a view 5 to 20%
 * more, and an id's first cell a table insert (`docs/performance.md`,
 * "Spatial grids").
 *
 * **What it holds** grows with the ids and the cells they are in, never with
 * where they are: one entity a long way from the rest is one more cell. The
 * table of cells grows to keep from two to four slots for each cell held (a
 * power of two, three array entries a slot), at most as many cells as ids,
 * and keeps its size as cells empty, until `clear`. Cells are counted
 * from the origin up to `MAX_CELL` along each axis either way; a position
 * past that is filed in the cell at the limit, and found there by any query
 * that reaches it, only more slowly if much is out there.
 *
 * **Ids** are small non-negative integers, as `SpatialGrid` and `InterestSet`
 * take them: the grid keeps six array entries for every id up to the largest
 * it has been given, and refuses one past `MAX_ID`.
 *
 * **Threading.** None.
 */
final class SparseSpatialGrid {
	/** The largest id a grid holds, as `SpatialGrid.MAX_ID`. **/
	public static inline var MAX_ID:Int = (1 << 24) - 1;

	/**
	 * How far, in cells, cells go from the origin along either axis: cell
	 * coordinates run from `-MAX_CELL` to `MAX_CELL`, and a position past
	 * them is filed at the limit. Far enough for any world (with cells of a
	 * metre, a million kilometres), and small enough that a range of cells
	 * is counted without overflowing.
	 */
	public static inline var MAX_CELL:Int = 1 << 30;

	// As SpatialGrid's: how far past its edge a query reaches when choosing
	// cells, so a position within a rounding error of a cell edge is not
	// missed.
	private static inline var SLACK:Float = 1e-7;

	// `__next` of an id the grid does not hold.
	private static inline var NOT_HELD:Int = -2;

	/** The width and height of a cell. **/
	public var cellSize(default, null):Float;

	/** Ids the grid holds. **/
	public var length(default, null):Int = 0;

	/** Cells that hold at least one id. **/
	public var cellCount(default, null):Int = 0;

	private var __inverse:Float;

	// The cells held, by their coordinates: open addressing, probed in turn,
	// a slot's head -1 while it is empty. Deleting shifts the slots after it
	// back, so no slot is ever a tombstone.
	private var __slotX:Vector<Int>;
	private var __slotY:Vector<Int>;
	private var __slotHead:Vector<Int>;
	private var __slotMask:Int;

	// Per id: its cell's coordinates (x at 2 * id, y after it, in one vector
	// so a move that stays in its cell reads one line), its neighbours on that
	// cell's list (-1 at either end; `__next` NOT_HELD while the grid does not
	// hold it), and where it was last put.
	private var __cellXY:Vector<Int>;
	private var __next:Vector<Int>;
	private var __previous:Vector<Int>;
	private var __xs:Vector<Float>;
	private var __ys:Vector<Float>;

	/**
	 * @param cellSize The width and height of a cell; about the radius most
	 *        queries use.
	 * @param capacity Ids to make room for at the start; the grid grows to fit
	 *        a larger one when it is set.
	 */
	public function new(cellSize:Float, capacity:Int = 64) {
		if (!Math.isFinite(cellSize) || !(cellSize > 0)) {
			throw new ArgumentError("cellSize must be finite and positive.");
		}
		if (capacity < 0) {
			throw new ArgumentError("capacity cannot be negative.");
		}
		this.cellSize = cellSize;
		__inverse = 1 / cellSize;
		if (!Math.isFinite(__inverse)) {
			throw new ArgumentError('A cellSize of $cellSize is too small to divide by.');
		}
		__makeTable(16);
		__cellXY = new Vector<Int>(0);
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
	 *
	 * @throws ArgumentError For a negative id, one past `MAX_ID`, or a NaN
	 *         position.
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
		if (id > MAX_ID) {
			throw new ArgumentError('An id is at most $MAX_ID, not $id.');
		}
		if (id >= __next.length) {
			__grow(id + 1);
		}

		final cx:Int = __cell(x * __inverse);
		final cy:Int = __cell(y * __inverse);
		final at:Int = id << 1;
		if (__next[id] == NOT_HELD || __cellXY[at] != cx || __cellXY[at + 1] != cy) {
			__place(id, cx, cy);
		}
		__xs[id] = x;
		__ys[id] = y;
	}

	// Files `id` in cell (cx, cy): a new id, or one crossing into another
	// cell. Apart from `set`, so what `set` does every step (the comparison
	// that finds an id in the cell it was in) stays small enough for a
	// compiler to fold into the loop that calls it.
	private function __place(id:Int, cx:Int, cy:Int):Void {
		if (__next[id] == NOT_HELD) {
			length++;
		} else {
			__unlink(id);
		}
		__link(id, cx, cy);
	}

	/**
	 * Takes `id` out of the grid, and its cell with it when it was the last
	 * there.
	 *
	 * @return Whether the grid held it.
	 */
	public function remove(id:Int):Bool {
		if (!has(id)) {
			return false;
		}
		__unlink(id);
		__next[id] = NOT_HELD;
		length--;
		return true;
	}

	public function has(id:Int):Bool {
		return id >= 0 && id < __next.length && __next[id] != NOT_HELD;
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
		final firstX:Int = __cell((x - radius) * __inverse - SLACK);
		final lastX:Int = __cell((x + radius) * __inverse + SLACK);
		final firstY:Int = __cell((y - radius) * __inverse - SLACK);
		final lastY:Int = __cell((y + radius) * __inverse + SLACK);
		final radiusSquared:Float = radius * radius;
		final heads:Vector<Int> = __slotHead;
		if (__walksHeld(firstX, lastX, firstY, lastY)) {
			for (s in 0...heads.length) {
				var id:Int = heads[s];
				if (id == -1 || !__within(s, firstX, lastX, firstY, lastY)) {
					continue;
				}
				while (id != -1) {
					final dx:Float = __xs[id] - x;
					final dy:Float = __ys[id] - y;
					if (dx * dx + dy * dy <= radiusSquared) {
						found.push(id);
					}
					id = __next[id];
				}
			}
			return found;
		}
		for (cy in firstY...lastY + 1) {
			for (cx in firstX...lastX + 1) {
				final s:Int = __find(cx, cy);
				if (s < 0) {
					continue;
				}
				var id:Int = heads[s];
				while (id != -1) {
					final dx:Float = __xs[id] - x;
					final dy:Float = __ys[id] - y;
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
	 * Adds to `found` every id within `radius` of (`x`, `y`), as
	 * `queryCircle` does, into a list that allocates nothing on any target
	 * once it has grown.
	 *
	 * @return `found`.
	 */
	public function queryCircleIds(x:Float, y:Float, radius:Float, found:IdList):IdList {
		if (!(radius >= 0) || Math.isNaN(x) || Math.isNaN(y)) {
			return found;
		}
		// The same walk as queryCircle's, written out again rather than
		// shared through a call per id.
		final firstX:Int = __cell((x - radius) * __inverse - SLACK);
		final lastX:Int = __cell((x + radius) * __inverse + SLACK);
		final firstY:Int = __cell((y - radius) * __inverse - SLACK);
		final lastY:Int = __cell((y + radius) * __inverse + SLACK);
		final radiusSquared:Float = radius * radius;
		final heads:Vector<Int> = __slotHead;
		if (__walksHeld(firstX, lastX, firstY, lastY)) {
			for (s in 0...heads.length) {
				var id:Int = heads[s];
				if (id == -1 || !__within(s, firstX, lastX, firstY, lastY)) {
					continue;
				}
				while (id != -1) {
					final dx:Float = __xs[id] - x;
					final dy:Float = __ys[id] - y;
					if (dx * dx + dy * dy <= radiusSquared) {
						found.push(id);
					}
					id = __next[id];
				}
			}
			return found;
		}
		for (cy in firstY...lastY + 1) {
			for (cx in firstX...lastX + 1) {
				final s:Int = __find(cx, cy);
				if (s < 0) {
					continue;
				}
				var id:Int = heads[s];
				while (id != -1) {
					final dx:Float = __xs[id] - x;
					final dy:Float = __ys[id] - y;
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
		final right:Float = x + width;
		final bottom:Float = y + height;
		final firstX:Int = __cell(x * __inverse - SLACK);
		final lastX:Int = __cell(right * __inverse + SLACK);
		final firstY:Int = __cell(y * __inverse - SLACK);
		final lastY:Int = __cell(bottom * __inverse + SLACK);
		final heads:Vector<Int> = __slotHead;
		if (__walksHeld(firstX, lastX, firstY, lastY)) {
			for (s in 0...heads.length) {
				var id:Int = heads[s];
				if (id == -1 || !__within(s, firstX, lastX, firstY, lastY)) {
					continue;
				}
				while (id != -1) {
					final px:Float = __xs[id];
					final py:Float = __ys[id];
					if (px >= x && py >= y && px < right && py < bottom) {
						found.push(id);
					}
					id = __next[id];
				}
			}
			return found;
		}
		for (cy in firstY...lastY + 1) {
			for (cx in firstX...lastX + 1) {
				final s:Int = __find(cx, cy);
				if (s < 0) {
					continue;
				}
				var id:Int = heads[s];
				while (id != -1) {
					final px:Float = __xs[id];
					final py:Float = __ys[id];
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
	 * Adds to `found` every id inside the rectangle, as `queryRect` does, into
	 * a list that allocates nothing on any target once it has grown.
	 *
	 * @return `found`.
	 */
	public function queryRectIds(x:Float, y:Float, width:Float, height:Float, found:IdList):IdList {
		if (!(width > 0) || !(height > 0) || Math.isNaN(x) || Math.isNaN(y)) {
			return found;
		}
		final right:Float = x + width;
		final bottom:Float = y + height;
		final firstX:Int = __cell(x * __inverse - SLACK);
		final lastX:Int = __cell(right * __inverse + SLACK);
		final firstY:Int = __cell(y * __inverse - SLACK);
		final lastY:Int = __cell(bottom * __inverse + SLACK);
		final heads:Vector<Int> = __slotHead;
		if (__walksHeld(firstX, lastX, firstY, lastY)) {
			for (s in 0...heads.length) {
				var id:Int = heads[s];
				if (id == -1 || !__within(s, firstX, lastX, firstY, lastY)) {
					continue;
				}
				while (id != -1) {
					final px:Float = __xs[id];
					final py:Float = __ys[id];
					if (px >= x && py >= y && px < right && py < bottom) {
						found.push(id);
					}
					id = __next[id];
				}
			}
			return found;
		}
		for (cy in firstY...lastY + 1) {
			for (cx in firstX...lastX + 1) {
				final s:Int = __find(cx, cy);
				if (s < 0) {
					continue;
				}
				var id:Int = heads[s];
				while (id != -1) {
					final px:Float = __xs[id];
					final py:Float = __ys[id];
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
	 * Takes every id out, and lets the table of cells go back to its
	 * starting size. Costs one pass over the ids the grid has made room for.
	 */
	public function clear():Void {
		__makeTable(16);
		for (i in 0...__next.length) {
			__next[i] = NOT_HELD;
		}
		length = 0;
		cellCount = 0;
	}

	// A position in cell units to its cell along one axis: rounded down, so
	// cell 0 runs from 0 up to one cell and cell -1 from one cell below up to
	// 0, and held to the limit either way (Infinity included).
	private static inline function __cell(units:Float):Int {
		if (units >= MAX_CELL) {
			return MAX_CELL;
		}
		if (units <= -MAX_CELL) {
			return -MAX_CELL;
		}
		// Std.int truncates toward zero, so a negative fraction is a cell lower.
		final whole:Int = Std.int(units);
		return units < whole ? whole - 1 : whole;
	}

	// Whether a range of cells covers more than the grid holds, so walking
	// what it holds is the shorter way. Counted as a Float: a range can run
	// past 2^31 cells. `/ 1` makes each a Float on the interpreter and neko
	// too, where an Int held as a Float still adds as an Int.
	private inline function __walksHeld(firstX:Int, lastX:Int, firstY:Int, lastY:Int):Bool {
		return (lastX / 1 - firstX + 1) * (lastY / 1 - firstY + 1) > cellCount;
	}

	private inline function __within(slot:Int, firstX:Int, lastX:Int, firstY:Int, lastY:Int):Bool {
		final cx:Int = __slotX[slot];
		final cy:Int = __slotY[slot];
		return cx >= firstX && cx <= lastX && cy >= firstY && cy <= lastY;
	}

	// Puts `id` at the head of cell (cx, cy)'s list, making the cell if it
	// is not held: one probe either way, with room made first.
	private function __link(id:Int, cx:Int, cy:Int):Void {
		if ((cellCount + 1) * 2 > __slotHead.length) {
			__rehash(__slotHead.length * 2);
		}
		final mask:Int = __slotMask;
		final heads:Vector<Int> = __slotHead;
		var s:Int = __hash(cx, cy) & mask;
		while (true) {
			final head:Int = heads[s];
			if (head == -1) {
				__slotX[s] = cx;
				__slotY[s] = cy;
				heads[s] = id;
				__next[id] = -1;
				cellCount++;
				break;
			}
			if (__slotX[s] == cx && __slotY[s] == cy) {
				__next[id] = head;
				__previous[head] = id;
				heads[s] = id;
				break;
			}
			s = (s + 1) & mask;
		}
		__previous[id] = -1;
		__cellXY[id << 1] = cx;
		__cellXY[(id << 1) + 1] = cy;
	}

	// Takes `id` off its cell's list, and the cell out when it empties.
	private inline function __unlink(id:Int):Void {
		final previous:Int = __previous[id];
		final next:Int = __next[id];
		if (previous != -1) {
			__next[previous] = next;
		} else {
			final s:Int = __find(__cellXY[id << 1], __cellXY[(id << 1) + 1]);
			if (next == -1) {
				__removeSlot(s);
			} else {
				__slotHead[s] = next;
			}
		}
		if (next != -1) {
			__previous[next] = previous;
		}
	}

	private static inline function __hash(cx:Int, cy:Int):Int {
		var h:Int = Hash.mul32(cx, 0x9E3779B1) ^ cy;
		h = Hash.mul32(h ^ (h >>> 16), 0x85EBCA6B);
		return h ^ (h >>> 13);
	}

	// The slot holding cell (cx, cy), or -1.
	private function __find(cx:Int, cy:Int):Int {
		final mask:Int = __slotMask;
		final heads:Vector<Int> = __slotHead;
		var s:Int = __hash(cx, cy) & mask;
		while (heads[s] != -1) {
			if (__slotX[s] == cx && __slotY[s] == cy) {
				return s;
			}
			s = (s + 1) & mask;
		}
		return -1;
	}

	// Empties slot `s`, shifting back each slot after it in its run that
	// would no longer be found past the gap.
	private function __removeSlot(s:Int):Void {
		final mask:Int = __slotMask;
		final heads:Vector<Int> = __slotHead;
		var gap:Int = s;
		heads[gap] = -1;
		var at:Int = s;
		while (true) {
			at = (at + 1) & mask;
			if (heads[at] == -1) {
				break;
			}
			final home:Int = __hash(__slotX[at], __slotY[at]) & mask;
			// It stays when its home lies after the gap, up to where it is
			// (cyclically): a probe from there never passes the gap.
			final stays:Bool = gap <= at ? (home > gap && home <= at) : (home > gap || home <= at);
			if (stays) {
				continue;
			}
			__slotX[gap] = __slotX[at];
			__slotY[gap] = __slotY[at];
			heads[gap] = heads[at];
			heads[at] = -1;
			gap = at;
		}
		cellCount--;
	}

	private function __makeTable(size:Int):Void {
		__slotX = new Vector<Int>(size, 0);
		__slotY = new Vector<Int>(size, 0);
		__slotHead = new Vector<Int>(size, -1);
		__slotMask = size - 1;
	}

	private function __rehash(size:Int):Void {
		final xs:Vector<Int> = __slotX;
		final ys:Vector<Int> = __slotY;
		final heads:Vector<Int> = __slotHead;
		__makeTable(size);
		final mask:Int = __slotMask;
		for (i in 0...heads.length) {
			final head:Int = heads[i];
			if (head == -1) {
				continue;
			}
			var s:Int = __hash(xs[i], ys[i]) & mask;
			while (__slotHead[s] != -1) {
				s = (s + 1) & mask;
			}
			__slotX[s] = xs[i];
			__slotY[s] = ys[i];
			__slotHead[s] = head;
		}
	}

	private function __grow(needed:Int):Void {
		var size:Int = __next.length < 16 ? 16 : __next.length;
		// Doubling past 2^30 would overflow; past that, exactly what is asked.
		while (size < needed && size < (1 << 30)) {
			size *= 2;
		}
		if (size < needed) {
			size = needed;
		}
		__cellXY = __resizeInt(__cellXY, size * 2, 0);
		__next = __resizeInt(__next, size, NOT_HELD);
		__previous = __resizeInt(__previous, size, -1);
		__xs = __resizeFloat(__xs, size);
		__ys = __resizeFloat(__ys, size);
	}

	// A new vector of `size` holding the old one's entries, the rest set to
	// `fill`. Every entry is written, since a fresh Vector is zeroed on some
	// targets and null on others.
	private static function __resizeInt(old:Vector<Int>, size:Int, fill:Int):Vector<Int> {
		final grown = new Vector<Int>(size);
		for (i in 0...old.length) {
			grown[i] = old[i];
		}
		for (i in old.length...size) {
			grown[i] = fill;
		}
		return grown;
	}

	private static function __resizeFloat(old:Vector<Float>, size:Int):Vector<Float> {
		final grown = new Vector<Float>(size);
		for (i in 0...old.length) {
			grown[i] = old[i];
		}
		for (i in old.length...size) {
			grown[i] = 0.0;
		}
		return grown;
	}
}
