package crossbyte.ds;

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
		fillColor = (fillColor << 8) | ((fillColor >> 24) & 0xFF);

		for (i in 0...width * height) {
			pixels.push(fillColor);
		}
	}

	public function getPixel(x:Int, y:Int):Int {
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		return pixels[y * width + x] & 0xFFFFFF; // Return RGB, ignoring alpha
	}

	public function setPixel(x:Int, y:Int, color:Int):Void {
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		var alpha = transparent ? (pixels[y * width + x] & 0xFF000000) : 0xFF000000;
		pixels[y * width + x] = alpha | (color & 0xFFFFFF);
	}

	public function getPixel32(x:Int, y:Int):Int {
		if (x < 0 || x >= width || y < 0 || y >= height) {
			throw "Pixel out of bounds";
		}
		return pixels[y * width + x];
	}

	public function setPixel32(x:Int, y:Int, color:Int):Void {
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
		color = (color << 8) | ((color >> 24) & 0xFF);
		pixels[y * width + x] = color;
	}

	public function fillRect(rect:Rectangle, color:Int):Void {
		for (y in Std.int(rect.y)...Std.int(rect.y + rect.height)) {
			for (x in Std.int(rect.x)...Std.int(rect.x + rect.width)) {
				setPixel32(x, y, color);
			}
		}
	}

	public function clone():BitmapData {
		var clone = new BitmapData(width, height, transparent);
		for (i in 0...pixels.length) {
			clone.pixels[i] = pixels[i];
		}
		return clone;
	}

	public function toByteArray():ByteArray {
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
		for (y in 0...Std.int(sourceRect.height)) {
			for (x in 0...Std.int(sourceRect.width)) {
				var sourceColor = sourceBitmap.getPixel32(Std.int(sourceRect.x + x), Std.int(sourceRect.y + y));
				this.setPixel32(Std.int(destPoint.x + x), Std.int(destPoint.y + y), sourceColor);
			}
		}
	}

	public function getColorBoundsRect(mask:Int, color:Int, findColor:Bool = true):Rectangle {
		var xMin = width, xMax = 0, yMin = height, yMax = 0;
		for (y in 0...height) {
			for (x in 0...width) {
				var pixelColor = getPixel32(x, y);
				if (((pixelColor & mask) == color) == findColor) {
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
		return new Rectangle(xMin, yMin, xMax - xMin + 1, yMax - yMin + 1);
	}

	public function threshold(sourceBitmap:BitmapData, sourceRect:Rectangle, destPoint:Point, operation:String, threshold:Int, color:Int = 0,
			mask:Int = 0xFFFFFFFF, copySource:Bool = false):Int {
		var hits = 0;
		for (y in 0...Std.int(sourceRect.height)) {
			for (x in 0...Std.int(sourceRect.width)) {
				var sourceColor = sourceBitmap.getPixel32(Std.int(sourceRect.x + x), Std.int(sourceRect.y + y));
				var test = (sourceColor & mask);
				var passed = false;
				switch (operation) {
					case "==":
						passed = (test == threshold);
						break;
					case "!=":
						passed = (test != threshold);
						break;
					case "<":
						passed = (test < threshold);
						break;
					case ">":
						passed = (test > threshold);
						break;
					case "<=":
						passed = (test <= threshold);
						break;
					case ">=":
						passed = (test >= threshold);
						break;
					default:
						throw "Unknown operation";
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
}
