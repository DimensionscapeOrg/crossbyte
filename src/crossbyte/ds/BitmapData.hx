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

	public function new(width:Int, height:Int, transparent:Bool = true, fillColor:Int = 0xFFFFFFFF) {
		this.width = width;
		this.height = height;
		this.transparent = transparent;
		this.pixels = new Array<Int>();

		if (transparent) {
			if ((fillColor & 0xFF000000) == 0) {
				fillColor = 0;
			}
		} else {
			fillColor = (0xFF << 24) | (fillColor & 0xFFFFFF);
		}

		for (i in 0...width * height) {
			pixels.push(fillColor);
		}
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
		pixels[y * width + x] = alpha | (color & 0xFFFFFF);
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
		if (transparent) {
			if ((color & 0xFF000000) == 0) {
				color = 0;
			}
		} else {
			color = (0xFF << 24) | (color & 0xFFFFFF);
		}
		pixels[y * width + x] = color;
	}

	public function fillRect(rect:Rectangle, color:Int):Void {
		__ensureNotDisposed();
		for (y in Std.int(rect.y)...Std.int(rect.y + rect.height)) {
			for (x in Std.int(rect.x)...Std.int(rect.x + rect.width)) {
				setPixel32(x, y, color);
			}
		}
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
			var color = byteArray.readUnsignedInt();
			bitmap.pixels[i] = transparent ? color : (color | 0xFF000000); // Ensure alpha is 0xFF if not transparent
		}
		return bitmap;
	}

	public function dispose():Void {
		pixels = null;
	}

	public function copyPixels(sourceBitmap:BitmapData, sourceRect:Rectangle, destPoint:Point):Void {
		__ensureNotDisposed();
		sourceBitmap.__ensureNotDisposed();
		for (y in 0...Std.int(sourceRect.height)) {
			for (x in 0...Std.int(sourceRect.width)) {
				var sourceColor = sourceBitmap.getPixel32(Std.int(sourceRect.x + x), Std.int(sourceRect.y + y));
				this.setPixel32(Std.int(destPoint.x + x), Std.int(destPoint.y + y), sourceColor);
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
		number of pixels that passed, which was 0 on every call: each case
		of the operation ended in `break`, which in Haxe leaves the loop the
		switch is in, so the first pixel of each row ended the row.

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
		for (y in 0...Std.int(sourceRect.height)) {
			for (x in 0...Std.int(sourceRect.width)) {
				var sourceColor = sourceBitmap.getPixel32(Std.int(sourceRect.x + x), Std.int(sourceRect.y + y));
				var test:Int = (sourceColor & mask) ^ 0x80000000;
				var passed:Bool = switch (op) {
					case 0: test < limit;
					case 1: test <= limit;
					case 2: test > limit;
					case 3: test >= limit;
					case 4: test == limit;
					default: test != limit;
				}
				if (passed) {
					setPixel32(Std.int(destPoint.x + x), Std.int(destPoint.y + y), color);
					hits++;
				} else if (copySource) {
					setPixel32(Std.int(destPoint.x + x), Std.int(destPoint.y + y), sourceColor);
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
