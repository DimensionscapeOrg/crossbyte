package crossbyte.math;

import utest.Assert;

class MathTest extends utest.Test {
	public function testPointMathHelpers():Void {
		var origin = new Point();
		Assert.floatEquals(0, origin.x);
		Assert.floatEquals(0, origin.y);
		Assert.floatEquals(0, origin.length);

		var a = new Point(3, 4);
		Assert.floatEquals(5, a.length);
		Assert.floatEquals(5, Point.distance(a, origin));
		Assert.floatEquals(1, Point.distance(a, new Point(4, 4)));

		var b = a.clone();
		b.normalize(10);
		Assert.floatEquals(3, a.x);
		Assert.floatEquals(4, a.y);
		Assert.floatEquals(6, b.x);
		Assert.floatEquals(8, b.y);

		var c = a.add(new Point(2, 1));
		Assert.floatEquals(5, c.x);
		Assert.floatEquals(5, c.y);

		var d = a.subtract(new Point(1, 2));
		Assert.floatEquals(2, d.x);
		Assert.floatEquals(2, d.y);
	}

	public function testPointStaticAndMutations():Void {
		var a = new Point(1, 2);
		var b = Point.polar(10, Math.PI / 2);

		Assert.floatEquals(0, Math.round(b.x));
		Assert.floatEquals(10, Math.round(b.y));
		Assert.floatEquals(2, Math.round(a.length));

		a.offset(5, -1);
		Assert.floatEquals(6, a.x);
		Assert.floatEquals(1, a.y);

		a.setTo(2, 3);
		Assert.floatEquals(2, a.x);
		Assert.floatEquals(3, a.y);

		var interpolated = Point.interpolate(new Point(1, 1), new Point(3, 5), 0.5);
		Assert.floatEquals(2, interpolated.x);
		Assert.floatEquals(3, interpolated.y);
		Assert.isTrue(a.equals(a.clone()));
		Assert.isFalse(a.equals(new Point(3, 4)));
		Assert.equals("(x=2, y=3)", a.toString());
	}

	public function testPointCopyAndEqualityEdgeCases():Void {
		var a = new Point(6, 7);
		var b = a.clone();

		Assert.isTrue(a.equals(b));

		b.copyFrom(new Point(-3, 12));
		Assert.floatEquals(-3, b.x);
		Assert.floatEquals(12, b.y);
		Assert.isFalse(a.equals(b));
		Assert.isFalse(a.equals(cast null));
	}

	public function testRectangleContainmentAndProperties():Void {
		var rect = new Rectangle(1, 2, 3, 4);

		Assert.floatEquals(1, rect.left);
		Assert.floatEquals(2, rect.top);
		Assert.floatEquals(4, rect.right);
		Assert.floatEquals(6, rect.bottom);

		rect.right = 10;
		Assert.floatEquals(9, rect.width);
		Assert.floatEquals(10, rect.right);

		rect.bottom = 20;
		Assert.floatEquals(18, rect.height);
		Assert.floatEquals(20, rect.bottom);

		Assert.isTrue(rect.contains(5, 10));
		Assert.isTrue(rect.containsPoint(new Point(5, 10)));
		Assert.isFalse(rect.contains(10, 10));
	}

	public function testRectangleContainRectIntersectionAndUnion():Void {
		var outer = new Rectangle(0, 0, 10, 10);
		var inner = new Rectangle(2, 3, 4, 2);
		var overlap = new Rectangle(8, 8, 5, 5);
		var none = new Rectangle(20, 20, 1, 1);

		Assert.isTrue(outer.containsRect(inner));
		Assert.isFalse(outer.containsRect(overlap));
		Assert.isFalse(outer.intersects(none));
		Assert.isTrue(outer.intersects(overlap));

		var intersect = outer.intersection(overlap);
		Assert.floatEquals(8, intersect.x);
		Assert.floatEquals(8, intersect.y);
		Assert.floatEquals(2, intersect.width);
		Assert.floatEquals(2, intersect.height);

		var union = inner.union(overlap);
		Assert.floatEquals(2, union.x);
		Assert.floatEquals(3, union.y);
		Assert.floatEquals(11, union.width);
		Assert.floatEquals(10, union.height);
	}

	public function testRectangleMutationsAndEdgeCases():Void {
		var rect = new Rectangle(10, 10, 4, 4);

		rect.inflate(1, 2);
		Assert.floatEquals(9, rect.x);
		Assert.floatEquals(8, rect.y);
		Assert.floatEquals(6, rect.width);
		Assert.floatEquals(8, rect.height);

		rect.offset(2, -3);
		Assert.floatEquals(11, rect.x);
		Assert.floatEquals(5, rect.y);

		rect.setEmpty();
		Assert.isTrue(rect.isEmpty());
		Assert.floatEquals(0, rect.width);
		Assert.floatEquals(0, rect.height);
	}

	public function testRectangleGeometryHelpers():Void {
		var rect = new Rectangle(4, 5, 8, 10);

		Assert.floatEquals(4, rect.left);
		Assert.floatEquals(5, rect.top);
		Assert.floatEquals(12, rect.right);
		Assert.floatEquals(15, rect.bottom);

		rect.left = 2;
		Assert.floatEquals(2, rect.x);
		Assert.floatEquals(10, rect.width);

		rect.top = 3;
		Assert.floatEquals(3, rect.y);
		Assert.floatEquals(12, rect.height);

		var bottomRight = rect.bottomRight;
		Assert.floatEquals(12, bottomRight.x);
		Assert.floatEquals(15, bottomRight.y);

		var topLeft = rect.topLeft;
		Assert.floatEquals(2, topLeft.x);
		Assert.floatEquals(3, topLeft.y);

		rect.bottomRight = new Point(8, 6);
		Assert.floatEquals(6, rect.width);
		Assert.floatEquals(3, rect.height);
		Assert.floatEquals(8, rect.right);
		Assert.floatEquals(6, rect.bottom);

		rect.topLeft = new Point(5, 9);
		Assert.floatEquals(6, rect.width);
		Assert.floatEquals(5, rect.x);
		Assert.floatEquals(9, rect.y);
		Assert.floatEquals(3, rect.height);
		Assert.floatEquals(11, rect.right);
		Assert.floatEquals(12, rect.bottom);
	}

	public function testRectanglePointMutatorsAndSizeViews():Void {
		var rect = new Rectangle(1, 2, 3, 4);
		Assert.floatEquals(3, rect.size.x);
		Assert.floatEquals(4, rect.size.y);

		rect.size = new Point(8, 9);
		Assert.floatEquals(8, rect.width);
		Assert.floatEquals(9, rect.height);

		rect.inflatePoint(new Point(1, 2));
		Assert.floatEquals(0, rect.x);
		Assert.floatEquals(0, rect.y);
		Assert.floatEquals(10, rect.width);
		Assert.floatEquals(13, rect.height);

		rect.offsetPoint(new Point(5, -1));
		Assert.floatEquals(5, rect.x);
		Assert.floatEquals(-1, rect.y);

		var copy = new Rectangle();
		copy.copyFrom(rect);
		Assert.isTrue(copy.equals(rect));
		Assert.equals("(x=5, y=-1, width=10, height=13)", copy.toString());
	}

	public function testRectangleIntersectionIntersectsAndPointSetters():Void {
		// intersection() of two known overlapping rectangles.
		var a = new Rectangle(0, 0, 10, 10);
		var b = new Rectangle(5, 5, 10, 10);
		var inter = a.intersection(b);
		Assert.floatEquals(5, inter.x);
		Assert.floatEquals(5, inter.y);
		Assert.floatEquals(5, inter.width);
		Assert.floatEquals(5, inter.height);

		// Non-overlapping rectangles yield an empty rect.
		var far = new Rectangle(100, 100, 5, 5);
		var empty = a.intersection(far);
		Assert.floatEquals(0, empty.x);
		Assert.floatEquals(0, empty.y);
		Assert.floatEquals(0, empty.width);
		Assert.floatEquals(0, empty.height);

		// intersects() booleans for overlap / no-overlap / edge-touch.
		Assert.isTrue(a.intersects(b));
		Assert.isFalse(a.intersects(far));
		// Shares only an edge (x from 10) => no positive-area intersection.
		Assert.isFalse(a.intersects(new Rectangle(10, 0, 5, 5)));

		// set_topLeft assigns x/y, leaving bottom-right corner moving with it.
		var rect = new Rectangle(1, 2, 3, 4);
		rect.topLeft = new Point(7, 8);
		Assert.floatEquals(7, rect.x);
		Assert.floatEquals(8, rect.y);
		Assert.floatEquals(3, rect.width);
		Assert.floatEquals(4, rect.height);

		// set_size assigns width/height.
		rect.size = new Point(20, 30);
		Assert.floatEquals(20, rect.width);
		Assert.floatEquals(30, rect.height);
		Assert.floatEquals(7, rect.x);
		Assert.floatEquals(8, rect.y);

		// set_bottomRight derives width/height from the assigned corner.
		rect.bottomRight = new Point(17, 28);
		Assert.floatEquals(10, rect.width);
		Assert.floatEquals(20, rect.height);
		Assert.floatEquals(17, rect.right);
		Assert.floatEquals(28, rect.bottom);

		// Setters return the assigned value (contract preserved without clone()).
		var p = new Point(40, 50);
		var returned = (rect.topLeft = p);
		Assert.isTrue(returned == p);
	}

	public function testMatrixTransformationsAndInversion():Void {
		var matrix = new Matrix();
		matrix.createBox(2, 2);
		Assert.floatEquals(2, matrix.a);
		Assert.floatEquals(2, matrix.d);

		var point = matrix.transformPoint(new Point(3, 5));
		Assert.floatEquals(6, point.x);
		Assert.floatEquals(10, point.y);

		matrix.translate(1, 2);
		var translated = matrix.transformPoint(new Point(1, 1));
		Assert.floatEquals(3, translated.x);
		Assert.floatEquals(4, translated.y);

		var rotated = new Matrix();
		rotated.rotate(Math.PI / 2);
		var rotatedPoint = rotated.transformPoint(new Point(1, 0));
		Assert.floatEquals(0, Math.round(rotatedPoint.x));
		Assert.floatEquals(1, Math.round(rotatedPoint.y));

		var scaled = new Matrix();
		scaled.scale(3, 4);
		var scaledPoint = scaled.deltaTransformPoint(new Point(2, 2));
		Assert.floatEquals(6, scaledPoint.x);
		Assert.floatEquals(8, scaledPoint.y);

		var combined = new Matrix(1, 2, 3, 4, 5, 6);
		combined.concat(new Matrix(2, 0, 0, 2, 10, 10));
		Assert.floatEquals(2, combined.a);
		Assert.floatEquals(4, combined.b);
		Assert.floatEquals(6, combined.c);
		Assert.floatEquals(8, combined.d);
		Assert.floatEquals(20, combined.tx);
		Assert.floatEquals(22, combined.ty);

		var original = new Matrix(2, 0, 0, 2, 5, 5);
		var transformed = original.transformPoint(new Point(3, 7));
		var inverse = original.clone();
		inverse.invert();
		var inverseBack = inverse.transformPoint(transformed);
		Assert.floatEquals(3, inverseBack.x);
		Assert.floatEquals(7, inverseBack.y);

		var singular = new Matrix(1, 2, 2, 4);
		singular.invert();
		Assert.floatEquals(1, singular.a);
		Assert.floatEquals(0, singular.b);
		Assert.floatEquals(0, singular.c);
		Assert.floatEquals(1, singular.d);
		Assert.floatEquals(0, singular.tx);
		Assert.floatEquals(0, singular.ty);

		var identity = new Matrix(3, 4, 1, 2, 9, 7);
		identity.identity();
		Assert.floatEquals(1, identity.a);
		Assert.floatEquals(0, identity.b);
		Assert.floatEquals(0, identity.c);
		Assert.floatEquals(1, identity.d);
		Assert.floatEquals(0, identity.tx);
		Assert.floatEquals(0, identity.ty);

		var cloneA = new Matrix(2, 3, 4, 5, 6, 7);
		var cloneB = cloneA.clone();
		cloneB.scale(2, 2);

		Assert.floatEquals(2, cloneA.a);
		Assert.floatEquals(5, cloneA.d);
		Assert.floatEquals(4, cloneB.a);
		Assert.floatEquals(10, cloneB.d);

		var delta = cloneA.deltaTransformPoint(new Point(2, 1));
		Assert.floatEquals(8, delta.x);
		Assert.floatEquals(11, delta.y);
	}

	public function testMatrixGradientBoxAndStringOutput():Void {
		var matrix = new Matrix();
		matrix.createGradientBox(1638.4, 819.2, 0, 10, 20);

		Assert.floatEquals(1, matrix.a);
		Assert.floatEquals(0, matrix.b);
		Assert.floatEquals(0, matrix.c);
		Assert.floatEquals(0.5, matrix.d);
		Assert.floatEquals(829.2, matrix.tx);
		Assert.floatEquals(429.6, matrix.ty);
		var asString = matrix.toString();
		Assert.isTrue(asString.indexOf("a=1") != -1);
		Assert.isTrue(asString.indexOf("d=0.5") != -1);
		Assert.isTrue(asString.indexOf("tx=829.2") != -1);
		Assert.isTrue(asString.indexOf("ty=429.6") != -1);
	}

	public function testCreateBoxAppliesScaleToCorrectBasis():Void {
		// scaleX != scaleY with a rotation exposes b/c basis mix-ups (invisible at
		// rotation 0). cos(90)=0, sin(90)=1 => a=0, b=scaleX, c=-scaleY, d=0.
		var m = new Matrix();
		m.createBox(2, 3, Math.PI / 2);
		Assert.floatEquals(0, m.a);
		Assert.floatEquals(2, m.b);
		Assert.floatEquals(-3, m.c);
		Assert.floatEquals(0, m.d);
	}
}
