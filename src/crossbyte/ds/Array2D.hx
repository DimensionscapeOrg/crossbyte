package crossbyte.ds;

/**
 * Simple row-major two-dimensional array wrapper.
 *
 * **Cells start as `value`.** Leave it out and they start as `null`, which
 * a static target, holding an `Int` or a `Float` or a `Bool`, stores as `0` or
 * `false`, and eval and JavaScript keep as `null`: an `Array2D<Int>` made
 * without a value reads 0 on hxcpp and the jvm and null elsewhere. The
 * constructor cannot tell what `T` is to do better, so pass a value for a
 * basic type, or `fill` one.
 */
abstract Array2D<T>(Array<Array<T>>) from Array<Array<T>> to Array<Array<T>> {
	public inline function new(rows:Int = 0, cols:Int = 0, value:T = null) {
		this = [];

		for (r in 0...rows) {
			var row:Array<T> = [];
			for (c in 0...cols) {
				row.push(value);
			}
			this.push(row);
		}
	}

	public inline function get(row:Int, col:Int):T {
		return this[row][col];
	}

	public inline function set(row:Int, col:Int, value:T):Void {
		this[row][col] = value;
	}

	/** Sets every cell to `value`. **/
	public inline function fill(value:T):Void {
		for (row in this) {
			for (c in 0...row.length) {
				row[c] = value;
			}
		}
	}

	/**
	 * Removes every row. The rows are emptied in place, so every reference
	 * to this grid sees it cleared; it was replaced, which left another
	 * reference to it holding the old rows.
	 */
	public inline function clear():Void {
		this.resize(0);
	}

	public inline function isEmpty():Bool {
		return this.length == 0;
	}

	public inline function getWidth():Int {
		return this.length > 0 ? this[0].length : 0;
	}

	public inline function getHeight():Int {
		return this.length;
	}

	public inline function toFlatArray():Array<T> {
		var flatArray:Array<T> = [];

		for (r in 0...this.length) {
			for (c in 0...this[r].length) {
				flatArray.push(this[r][c]);
			}
		}

		return flatArray;
	}

	public inline function clone():Array2D<T> {
		var copy:Array<Array<T>> = [];
		for (row in this) {
			copy.push(row.copy());
		}
		return copy;
	}
}
