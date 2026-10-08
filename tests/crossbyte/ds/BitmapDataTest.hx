package crossbyte.ds;

import utest.Assert;

class BitmapDataTest extends utest.Test {
	public function testCloneCopiesMetadataAndPixels():Void {
		var original = new crossbyte.ds.BitmapData(3, 2, true, 0x00000000);
		// Give each pixel a distinct value.
		original.setPixel32(0, 0, 0xFF112233);
		original.setPixel32(1, 0, 0xFF445566);
		original.setPixel32(2, 0, 0xFF778899);
		original.setPixel32(0, 1, 0xFFAABBCC);
		original.setPixel32(1, 1, 0xFFDDEEFF);
		original.setPixel32(2, 1, 0xFF102030);

		var clone = original.clone();

		Assert.equals(original.width, clone.width);
		Assert.equals(original.height, clone.height);
		Assert.equals(original.transparent, clone.transparent);

		for (y in 0...original.height) {
			for (x in 0...original.width) {
				Assert.equals(original.getPixel32(x, y), clone.getPixel32(x, y));
			}
		}
	}

	public function testCloneIsIndependentBothDirections():Void {
		var original = new crossbyte.ds.BitmapData(2, 2, true, 0x00000000);
		original.setPixel32(0, 0, 0xFF010101);
		original.setPixel32(1, 0, 0xFF020202);
		original.setPixel32(0, 1, 0xFF030303);
		original.setPixel32(1, 1, 0xFF040404);

		var clone = original.clone();

		// Mutating the clone must not affect the original.
		clone.setPixel32(0, 0, 0xFFAAAAAA);
		Assert.equals(0xFF010101, original.getPixel32(0, 0));
		Assert.equals(0xFFAAAAAA, clone.getPixel32(0, 0));

		// Mutating the original must not affect the clone.
		original.setPixel32(1, 1, 0xFFBBBBBB);
		Assert.equals(0xFF040404, clone.getPixel32(1, 1));
		Assert.equals(0xFFBBBBBB, original.getPixel32(1, 1));
	}

	public function testCloneOpaqueBitmap():Void {
		var original = new crossbyte.ds.BitmapData(2, 1, false, 0x123456);
		var clone = original.clone();

		Assert.equals(2, clone.width);
		Assert.equals(1, clone.height);
		Assert.isFalse(clone.transparent);
		Assert.equals(original.getPixel32(0, 0), clone.getPixel32(0, 0));
		Assert.equals(original.getPixel32(1, 0), clone.getPixel32(1, 0));
	}

	/**
		Every pixel that passes is counted and recoloured. A `break` ending a
		case of the operation would leave the loop around the switch in Haxe,
		so the first pixel would end each row and every call would return 0.
	**/
	public function testThresholdCountsAndSetsEveryPassingPixel():Void {
		var bitmap = new crossbyte.ds.BitmapData(4, 4, true, 0xFF00FF00);
		bitmap.setPixel32(2, 1, 0xFF0000FF);
		var hits = bitmap.threshold(bitmap, new crossbyte.math.Rectangle(0, 0, 4, 4), new crossbyte.math.Point(0, 0), "==", 0xFF00FF00, 0xFFFF0000);
		Assert.equals(15, hits);
		Assert.equals(0xFFFF0000, bitmap.getPixel32(3, 3));
		Assert.equals(0xFFFF0000, bitmap.getPixel32(0, 0));
		Assert.equals(0xFF0000FF, bitmap.getPixel32(2, 1), "a pixel that failed was changed");

		var other = new crossbyte.ds.BitmapData(4, 4, true, 0xFF00FF00);
		Assert.equals(1, other.threshold(bitmap, new crossbyte.math.Rectangle(0, 0, 4, 4), new crossbyte.math.Point(0, 0), "!=", 0xFFFF0000, 0x11111111));
		Assert.equals(0x11111111, other.getPixel32(2, 1));
		Assert.equals(0xFF00FF00, other.getPixel32(0, 0));
	}

	/**
		The comparison is unsigned, as ActionScript's `uint` is: an alpha of
		0xFF is above 0x7F. Compared as signed Ints, every opaque pixel would
		read as negative and so as less than any threshold with a clear top bit.
	**/
	public function testThresholdComparesAsUnsigned():Void {
		var source = new crossbyte.ds.BitmapData(3, 1, true, 0);
		source.setPixel32(0, 0, 0xFF123456);
		source.setPixel32(1, 0, 0x40123456);
		source.setPixel32(2, 0, 0x7F123456);
		var dest = new crossbyte.ds.BitmapData(3, 1, true, 0xFFFFFFFF);
		// Clear everything whose alpha is below 0x7F: only the 0x40 pixel.
		var hits = dest.threshold(source, new crossbyte.math.Rectangle(0, 0, 3, 1), new crossbyte.math.Point(0, 0), "<", 0x7F000000, 0, 0xFF000000, true);
		Assert.equals(1, hits);
		Assert.equals(0xFF123456, dest.getPixel32(0, 0), "a failing pixel was not copied from the source");
		Assert.equals(0, dest.getPixel32(1, 0));
		Assert.equals(0x7F123456, dest.getPixel32(2, 0));

		Assert.equals(2, dest.threshold(source, new crossbyte.math.Rectangle(0, 0, 3, 1), new crossbyte.math.Point(0, 0), ">=", 0x7F000000, 0, 0xFF000000));
		Assert.raises(() -> dest.threshold(source, new crossbyte.math.Rectangle(0, 0, 3, 1), new crossbyte.math.Point(0, 0), "=>", 0));
	}
}
