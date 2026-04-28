package crossbyte.math;

import utest.Assert;

class MathTest extends utest.Test {
	public function testPointMathHelpers():Void {
		var origin = new Point();
		Assert.equals(0, origin.x);
		Assert.equals(0, origin.y);
		Assert.equals(0, origin.length);

		var a = new Point(3, 4);
		Assert.equals(5, a.length);
		Assert.equals(5, Point.distance(a, origin));
		Assert.equals(1, Point.distance(a, new Point(4, 4)));

		var b = a.clone();
		b.normalize(10);
		Assert.equals(3, a.x);
		Assert.equals(4, a.y);
		Assert.equals(6, b.x);
		Assert.equals(8, b.y);

		var c = a.add(new Point(2, 1));
		Assert.equals(5, c.x);
		Assert.equals(5, c.y);

		var d = a.subtract(new Point(1, 2));
		Assert.equals(2, d.x);
		Assert.equals(2, d.y);
	}

	public function testPointStaticAndMutations():Void {
		var a = new Point(1, 2);
		var b = Point.polar(10, Math.PI / 2);

		Assert.equals(0, Math.round(b.x));
		Assert.equals(10, Math.round(b.y));
		Assert.equals(2, Math.round(a.length));

		a.offset(5, -1);
		Assert.equals(6, a.x);
		Assert.equals(1, a.y);

		a.setTo(2, 3);
		Assert.equals(2, a.x);
		Assert.equals(3, a.y);

		var interpolated = Point.interpolate(new Point(1, 1), new Point(3, 5), 0.5);
		Assert.equals(2, interpolated.x);
		Assert.equals(3, interpolated.y);
		Assert.isTrue(a.equals(a.clone()));
		Assert.isFalse(a.equals(new Point(3, 4)));
		Assert.equals("(x=2, y=3)", a.toString());
	}

	public function testPointCopyAndEqualityEdgeCases():Void {
		var a = new Point(6, 7);
		var b = a.clone();

		Assert.isTrue(a.equals(b));

		b.copyFrom(new Point(-3, 12));
		Assert.equals(-3, b.x);
		Assert.equals(12, b.y);
		Assert.isFalse(a.equals(b));
		Assert.isFalse(a.equals(cast null));
	}

	public function testRectangleContainmentAndProperties():Void {
		var rect = new Rectangle(1, 2, 3, 4);

		Assert.equals(1, rect.left);
		Assert.equals(2, rect.top);
		Assert.equals(4, rect.right);
		Assert.equals(6, rect.bottom);

		rect.right = 10;
		Assert.equals(9, rect.width);
		Assert.equals(10, rect.right);

		rect.bottom = 20;
		Assert.equals(18, rect.height);
		Assert.equals(20, rect.bottom);

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
		Assert.equals(8, intersect.x);
		Assert.equals(8, intersect.y);
		Assert.equals(2, intersect.width);
		Assert.equals(2, intersect.height);

		var union = inner.union(overlap);
		Assert.equals(2, union.x);
		Assert.equals(3, union.y);
		Assert.equals(11, union.width);
		Assert.equals(10, union.height);
	}

	public function testRectangleMutationsAndEdgeCases():Void {
		var rect = new Rectangle(10, 10, 4, 4);

		rect.inflate(1, 2);
		Assert.equals(9, rect.x);
		Assert.equals(8, rect.y);
		Assert.equals(6, rect.width);
		Assert.equals(8, rect.height);

		rect.offset(2, -3);
		Assert.equals(11, rect.x);
		Assert.equals(5, rect.y);

		rect.setEmpty();
		Assert.isTrue(rect.isEmpty());
		Assert.equals(0, rect.width);
		Assert.equals(0, rect.height);
	}

	public function testRectangleGeometryHelpers():Void {
		var rect = new Rectangle(4, 5, 8, 10);

		Assert.equals(4, rect.left);
		Assert.equals(5, rect.top);
		Assert.equals(12, rect.right);
		Assert.equals(15, rect.bottom);

		rect.left = 2;
		Assert.equals(2, rect.x);
		Assert.equals(10, rect.width);

		rect.top = 3;
		Assert.equals(3, rect.y);
		Assert.equals(12, rect.height);

		var bottomRight = rect.bottomRight;
		Assert.equals(12, bottomRight.x);
		Assert.equals(15, bottomRight.y);

		var topLeft = rect.topLeft;
		Assert.equals(2, topLeft.x);
		Assert.equals(3, topLeft.y);

		rect.bottomRight = new Point(8, 6);
		Assert.equals(6, rect.width);
		Assert.equals(3, rect.height);
		Assert.equals(8, rect.right);
		Assert.equals(6, rect.bottom);

		rect.topLeft = new Point(5, 9);
		Assert.equals(6, rect.width);
		Assert.equals(5, rect.x);
		Assert.equals(9, rect.y);
		Assert.equals(3, rect.height);
		Assert.equals(11, rect.right);
		Assert.equals(12, rect.bottom);
	}

	public function testMatrixTransformationsAndInversion():Void {
		var matrix = new Matrix();
		matrix.createBox(2, 2);
		Assert.equals(2, matrix.a);
		Assert.equals(2, matrix.d);

		var point = matrix.transformPoint(new Point(3, 5));
		Assert.equals(6, point.x);
		Assert.equals(10, point.y);

		matrix.translate(1, 2);
		var translated = matrix.transformPoint(new Point(1, 1));
		Assert.equals(3, translated.x);
		Assert.equals(4, translated.y);

		var rotated = new Matrix();
		rotated.rotate(Math.PI / 2);
		var rotatedPoint = rotated.transformPoint(new Point(1, 0));
		Assert.equals(0, Math.round(rotatedPoint.x));
		Assert.equals(1, Math.round(rotatedPoint.y));

		var scaled = new Matrix();
		scaled.scale(3, 4);
		var scaledPoint = scaled.deltaTransformPoint(new Point(2, 2));
		Assert.equals(6, scaledPoint.x);
		Assert.equals(8, scaledPoint.y);

		var combined = new Matrix(1, 2, 3, 4, 5, 6);
		combined.concat(new Matrix(2, 0, 0, 2, 10, 10));
		Assert.equals(2, combined.a);
		Assert.equals(4, combined.b);
		Assert.equals(6, combined.c);
		Assert.equals(8, combined.d);
		Assert.equals(20, combined.tx);
		Assert.equals(22, combined.ty);

		var original = new Matrix(2, 0, 0, 2, 5, 5);
		var transformed = original.transformPoint(new Point(3, 7));
		var inverse = original.clone();
		inverse.invert();
		var inverseBack = inverse.transformPoint(transformed);
		Assert.equals(3, inverseBack.x);
		Assert.equals(7, inverseBack.y);

		var singular = new Matrix(1, 2, 2, 4);
		singular.invert();
		Assert.equals(1, singular.a);
		Assert.equals(0, singular.b);
		Assert.equals(0, singular.c);
		Assert.equals(1, singular.d);
		Assert.equals(0, singular.tx);
		Assert.equals(0, singular.ty);

		var identity = new Matrix(3, 4, 1, 2, 9, 7);
		identity.identity();
		Assert.equals(1, identity.a);
		Assert.equals(0, identity.b);
		Assert.equals(0, identity.c);
		Assert.equals(1, identity.d);
		Assert.equals(0, identity.tx);
		Assert.equals(0, identity.ty);

		var cloneA = new Matrix(2, 3, 4, 5, 6, 7);
		var cloneB = cloneA.clone();
		cloneB.scale(2, 2);

		Assert.equals(2, cloneA.a);
		Assert.equals(5, cloneA.d);
		Assert.equals(4, cloneB.a);
		Assert.equals(10, cloneB.d);

		var delta = cloneA.deltaTransformPoint(new Point(2, 1));
		Assert.equals(8, delta.x);
		Assert.equals(11, delta.y);
	}
}
