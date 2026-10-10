package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.math.Point;
import crossbyte.math.Rectangle;

/**
 * ...
 * @author Christopher Speciale
 */
class BitmapData {
	public var width(default, null):Int;
	public var height(default, null):Int;
	public var transparent(default, null):Bool;

	private var pixels:Array<Int>;

	/**
		@throws ArgumentError For a negative width or height, or more pixels
		        than an `Int` counts: taken as they came, a pixel's index
		        `y * width + x` wrapped, and two pixels shared one place.
	**/
	public function new(width:Int, height:Int, transparent:Bool = true, fillColor:Int = 0xFFFFFFFF) {
		// In Floats by `* 1.0`: a type check alone leaves the interpreter
		// multiplying Ints, which wraps.
		if (width < 0 || height < 0 || width * 1.0 * height > 0x7FFFFFFF) {
			throw new ArgumentError('A BitmapData cannot be $width by $height pixels.');
		}
		this.width = width;
		this.height = height;
		this.transparent = transparent;
		this.pixels = new Array<Int>();

		fillColor = __stored(fillColor);
		for (i in 0...width * height) {
			pixels.push(fillColor);
		}
	}

	// A colour as this bitmap holds it: opaque ones always at full alpha, and
	// in a transparent one, a pixel of no alpha holds no colour either, as
	// Flash's premultiplied pixels hold none.
	private inline function __stored(color:Int):Int {
		return transparent ? ((color & 0xFF000000) == 0 ? 0 : color) : ((0xFF << 24) | (color & 0xFFFFFF));
	}

	public function getPixel(x:Int, y:Int):Int {
		__ensureNotDisposed();
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		return pixels[y * width + x] & 0xFFFFFF; // Return RGB, ignoring alpha
	}

	public function setPixel(x:Int, y:Int, color:Int):Void {
		__ensureNotDisposed();
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		var alpha = transparent ? (pixels[y * width + x] & 0xFF000000) : 0xFF000000;
		pixels[y * width + x] = __stored(alpha | (color & 0xFFFFFF));
	}

	public function getPixel32(x:Int, y:Int):Int {
		__ensureNotDisposed();
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		return pixels[y * width + x];
	}

	public function setPixel32(x:Int, y:Int, color:Int):Void {
		__ensureNotDisposed();
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		pixels[y * width + x] = __stored(color);
	}

	/**
		Fills the part of `rect` inside the bitmap with `color`, as Flash's
		does: the rest is clipped away, where it threw part way through.
	**/
	public function fillRect(rect:Rectangle, color:Int):Void {
		__ensureNotDisposed();
		var stored:Int = __stored(color);
		var left:Int = __clampTo(Std.int(rect.x), width);
		var right:Int = __clampTo(Std.int(rect.x + rect.width), width);
		var top:Int = __clampTo(Std.int(rect.y), height);
		var bottom:Int = __clampTo(Std.int(rect.y + rect.height), height);
		for (y in top...bottom) {
			var row:Int = y * width;
			for (x in left...right) {
				pixels[row + x] = stored;
			}
		}
	}

	private static inline function __clampTo(value:Int, size:Int):Int {
		return value < 0 ? 0 : (value > size ? size : value);
	}

	public function clone():BitmapData {
		__ensureNotDisposed();
		var clone = new BitmapData(0, 0, transparent);
		clone.width = width;
		clone.height = height;
		clone.pixels = pixels.copy();
		return clone;
	}

	public function toByteArray():ByteArray {
		__ensureNotDisposed();
		var byteArray = new ByteArray();
		for (i in 0...pixels.length) {
			var color = pixels[i];
			byteArray.writeUnsignedInt(color);
		}
		byteArray.position = 0;
		return byteArray;
	}

	public static function fromByteArray(width:Int, height:Int, byteArray:ByteArray, transparent:Bool = true):BitmapData {
		var bitmap = new BitmapData(width, height, transparent);
		byteArray.position = 0;
		for (i in 0...width * height) {
			bitmap.pixels[i] = bitmap.__stored(byteArray.readUnsignedInt());
		}
		return bitmap;
	}

	public function dispose():Void {
		pixels = null;
	}

	/**
		Copies the pixels of `sourceRect` in `sourceBitmap` to `destPoint`,
		as Flash's does: clipped to both bitmaps, where it threw part way
		through, and whole when the two regions are in the same bitmap and
		overlap, where it read pixels it had already written.
	**/
	public function copyPixels(sourceBitmap:BitmapData, sourceRect:Rectangle, destPoint:Point):Void {
		__ensureNotDisposed();
		sourceBitmap.__ensureNotDisposed();
		var area = __Area.of(sourceBitmap, sourceRect, this, destPoint);
		if (area == null) {
			return;
		}
		var source:Array<Int> = sourceBitmap.pixels;
		var sourceWidth:Int = sourceBitmap.width;
		for (dy in 0...area.rows) {
			var y:Int = area.backwards ? area.top + area.rows - 1 - dy : area.top + dy;
			for (dx in 0...area.columns) {
				var x:Int = area.backwards ? area.left + area.columns - 1 - dx : area.left + dx;
				var color:Int = source[(area.sourceY + y) * sourceWidth + area.sourceX + x];
				pixels[(area.destY + y) * width + area.destX + x] = __stored(color);
			}
		}
	}

	public function getColorBoundsRect(mask:Int, color:Int, findColor:Bool = true):Rectangle {
		__ensureNotDisposed();
		var xMin = width, xMax = 0, yMin = height, yMax = 0;
		var found = false;
		for (y in 0...height) {
			for (x in 0...width) {
				var pixelColor = getPixel32(x, y);
				if (((pixelColor & mask) == color) == findColor) {
					found = true;
					if (x < xMin)
						xMin = x;
					if (x > xMax)
						xMax = x;
					if (y < yMin)
						yMin = y;
					if (y > yMax)
						yMax = y;
				}
			}
		}
		if (!found) {
			return new Rectangle();
		}
		return new Rectangle(xMin, yMin, xMax - xMin + 1, yMax - yMin + 1);
	}

	/**
		Tests each pixel of `sourceRect` in `sourceBitmap` against `threshold`
		and sets those that pass, at the same place relative to `destPoint`,
		to `color`; those that fail are copied from the source when
		`copySource` is set and left as they are otherwise.

		The test is `(pixel & mask) operation (threshold & mask)`, compared
		as unsigned 32-bit values as ActionScript's `uint`s are, so an alpha
		of 0xFF is above one of 0x7F rather than below it. It returns the
		number of pixels that passed.

		@param operation One of `<`, `<=`, `>`, `>=`, `==` and `!=`.
		@throws ArgumentError For any other `operation`.
	**/
	public function threshold(sourceBitmap:BitmapData, sourceRect:Rectangle, destPoint:Point, operation:String, threshold:Int, color:Int = 0,
			mask:Int = 0xFFFFFFFF, copySource:Bool = false):Int {
		__ensureNotDisposed();
		sourceBitmap.__ensureNotDisposed();
		var op:Int = switch (operation) {
			case "<": 0;
			case "<=": 1;
			case ">": 2;
			case ">=": 3;
			case "==": 4;
			case "!=": 5;
			default: throw new ArgumentError('Unknown threshold operation "$operation".');
		}
		// Flipping the sign bit makes a signed comparison an unsigned one.
		var limit:Int = (threshold & mask) ^ 0x80000000;
		var hits = 0;
		// Clipped to both bitmaps, and in the order that reads each pixel
		// before writing over it; see copyPixels.
		var area = __Area.of(sourceBitmap, sourceRect, this, destPoint);
		if (area == null) {
			return 0;
		}
		var source:Array<Int> = sourceBitmap.pixels;
		var sourceWidth:Int = sourceBitmap.width;
		for (dy in 0...area.rows) {
			var y:Int = area.backwards ? area.top + area.rows - 1 - dy : area.top + dy;
			for (dx in 0...area.columns) {
				var x:Int = area.backwards ? area.left + area.columns - 1 - dx : area.left + dx;
				var sourceColor:Int = source[(area.sourceY + y) * sourceWidth + area.sourceX + x];
				var test:Int = (sourceColor & mask) ^ 0x80000000;
				var passed:Bool = switch (op) {
					case 0: test < limit;
					case 1: test <= limit;
					case 2: test > limit;
					case 3: test >= limit;
					case 4: test == limit;
					default: test != limit;
				}
				var at:Int = (area.destY + y) * width + area.destX + x;
				if (passed) {
					pixels[at] = __stored(color);
					hits++;
				} else if (copySource) {
					pixels[at] = __stored(sourceColor);
				}
			}
		}
		return hits;
	}

	@:noCompletion
	private inline function __ensureNotDisposed():Void {
		if (pixels == null) {
			throw "BitmapData has been disposed";
		}
	}
}

/**
	The part of a source rectangle copied to a destination point that lies
	inside both bitmaps: offsets `left` to `left + columns` and `top` to
	`top + rows` from `(sourceX, sourceY)` in the source and `(destX, destY)`
	in the destination. `backwards` when the two are the same bitmap and
	the destination comes after the source, so a copy in that order reads
	each pixel before writing over it, as a `memmove` does.
**/
private class __Area {
	public var sourceX:Int;
	public var sourceY:Int;
	public var destX:Int;
	public var destY:Int;
	public var left:Int;
	public var top:Int;
	public var columns:Int;
	public var rows:Int;
	public var backwards:Bool;

	function new() {}

	public static function of(source:BitmapData, rect:Rectangle, dest:BitmapData, point:Point):Null<__Area> {
		var area = new __Area();
		area.sourceX = Std.int(rect.x);
		area.sourceY = Std.int(rect.y);
		area.destX = Std.int(point.x);
		area.destY = Std.int(point.y);
		var width:Int = Std.int(rect.width);
		var height:Int = Std.int(rect.height);
		// Offsets from the corner, kept inside the source and the destination.
		var left:Int = __max(0, __max(-area.sourceX, -area.destX));
		var top:Int = __max(0, __max(-area.sourceY, -area.destY));
		var right:Int = __min(width, __min(source.width - area.sourceX, dest.width - area.destX));
		var bottom:Int = __min(height, __min(source.height - area.sourceY, dest.height - area.destY));
		if (right <= left || bottom <= top) {
			return null;
		}
		area.left = left;
		area.top = top;
		area.columns = right - left;
		area.rows = bottom - top;
		area.backwards = source == dest && (area.destY > area.sourceY || (area.destY == area.sourceY && area.destX > area.sourceX));
		return area;
	}

	static inline function __max(a:Int, b:Int):Int {
		return a > b ? a : b;
	}

	static inline function __min(a:Int, b:Int):Int {
		return a < b ? a : b;
	}
}
