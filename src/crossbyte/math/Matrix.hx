package crossbyte.math;

/**
 * ...
 * @author Christopher Speciale
 */
class Matrix {
	public var a:Float;
	public var b:Float;
	public var c:Float;
	public var d:Float;
	public var tx:Float;
	public var ty:Float;

	public function new(a:Float = 1, b:Float = 0, c:Float = 0, d:Float = 1, tx:Float = 0, ty:Float = 0) {
		this.a = a;
		this.b = b;
		this.c = c;
		this.d = d;
		this.tx = tx;
		this.ty = ty;
	}

	public function clone():Matrix {
		return new Matrix(a, b, c, d, tx, ty);
	}

	public function concat(m:Matrix):Void {
		var a1 = a * m.a + b * m.c;
		b = a * m.b + b * m.d;
		a = a1;

		var c1 = c * m.a + d * m.c;
		d = c * m.b + d * m.d;
		c = c1;

		var tx1 = tx * m.a + ty * m.c + m.tx;
		ty = tx * m.b + ty * m.d + m.ty;
		tx = tx1;
	}

	public function createBox(scaleX:Float, scaleY:Float, rotation:Float = 0, tx:Float = 0, ty:Float = 0):Void {
		a = Math.cos(rotation) * scaleX;
		b = Math.sin(rotation) * scaleY;
		c = -Math.sin(rotation) * scaleX;
		d = Math.cos(rotation) * scaleY;
		this.tx = tx;
		this.ty = ty;
	}

	public function createGradientBox(width:Float, height:Float, rotation:Float = 0, tx:Float = 0, ty:Float = 0):Void {
		createBox(width / 1638.4, height / 1638.4, rotation, tx + width / 2, ty + height / 2);
	}

	public function identity():Void {
		a = 1;
		b = 0;
		c = 0;
		d = 1;
		tx = 0;
		ty = 0;
	}

	public function invert():Void {
		var det = a * d - b * c;
		if (det == 0) {
			identity();
			return;
		}
		var a1 = d / det;
		d = a / det;
		b = -b / det;
		c = -c / det;
		var tx1 = (c * ty - d * tx) / det;
		ty = (a * ty - b * tx) / det;
		tx = tx1;
	}

	public function rotate(angle:Float):Void {
		var cos = Math.cos(angle);
		var sin = Math.sin(angle);
		var a1 = a * cos - b * sin;
		b = a * sin + b * cos;
		a = a1;
		var c1 = c * cos - d * sin;
		d = c * sin + d * cos;
		c = c1;
		var tx1 = tx * cos - ty * sin;
		ty = tx * sin + ty * cos;
		tx = tx1;
	}

	public function scale(sx:Float, sy:Float):Void {
		a *= sx;
		b *= sy;
		c *= sx;
		d *= sy;
		tx *= sx;
		ty *= sy;
	}

	public function translate(dx:Float, dy:Float):Void {
		tx += dx;
		ty += dy;
	}

	public function transformPoint(point:Point):Point {
		return new Point(a * point.x + c * point.y + tx, b * point.x + d * point.y + ty);
	}

	public function deltaTransformPoint(point:Point):Point {
		return new Point(a * point.x + c * point.y, b * point.x + d * point.y);
	}

	public function toString():String {
		return "[Matrix(a=" + a + ", b=" + b + ", c=" + c + ", d=" + d + ", tx=" + tx + ", ty=" + ty + ")]";
	}
}
