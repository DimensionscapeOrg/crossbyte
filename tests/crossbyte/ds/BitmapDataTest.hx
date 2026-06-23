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
}
