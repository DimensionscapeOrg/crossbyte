package crossbyte.ds;

/**
 * ...
 * @author Christopher Speciale
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

	public inline function clear():Void {
		this = [];
	}

	public inline function isEmpty():Bool {
		return length == 0;
	}

	public inline function getWidth():Int {
		return this[0].length;
	}

	public inline function getHeight():Int {
		return this.length
	}

	public inline function toFlatArray():Array<T> {
		var flatArray:Array<T> = [];

		for (r in 0...length) {
			for (c in 0...this[r].length) {
				flatArray.push(this[r][c]);
			}
		}

		return flatArray;
	}

	public inline function clone():Array2D {
		return this.clone();
	}
}
