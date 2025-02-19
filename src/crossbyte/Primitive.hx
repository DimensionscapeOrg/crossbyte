package crossbyte;

abstract Primitive(Any) from Dynamic to Dynamic {
	public inline function new(value:Any) {
		if (!Primitive.isValid(value)) {
			throw "Invalid Primitive value: " + Std.string(value);
		}
		this = value;
	}

	@:to
	public inline function toString():String {
		return Std.string(this);
	}

	@:to
	public inline function toInt():Int {
		switch (Type.typeof(this)) {
			case TInt:
				return this;
			case TFloat:
				return this;
			case TBool:
				if (this == false) {
					return 0;
				} else {
					return 1;
				}
			case TClass(String):
				return Std.parseInt(this);
			case TNull:
				return 0;
			default:
				throw "Can not convert" + Std.string(this) + "to a Type Int";
		}
	}

	@:to
	public inline function toFloat():Float {
		switch (Type.typeof(this)) {
			case TInt:
				return Std.int(this);
			case TFloat:
				return this;
			case TBool:
				if (this == false) {
					return 0.0;
				} else {
					return 1.0;
				}
			case TClass(String):
				return Std.parseFloat(this);
			case TNull:
				return 0.0;
			default:
				throw "Can not convert" + Std.string(this) + "to a Type Float";
		}
	}

	@:to
	public inline function toBool():Bool {
		switch (Type.typeof(this)) {
			case TInt:
				if (this == 0) {
					return false;
				} else {
					return true;
				}
			case TFloat:
				if (this == 0.0) {
					return false;
				} else {
					return true;
				}
			case TBool:
				return this;
			case TClass(String):
				if (this == "false") {
					return false;
				} else {
					return true;
				}
			case TNull:
				return false;
			default:
				throw "Can not convert" + Std.string(this) + "to a Type Bool";
		}
	}

	@:from public static inline function fromString(s:String):Primitive {
        return s != null ? s : "";
    }
    
    @:from public static inline function fromInt(i:Int):Primitive {
        return i;
    }
    
    @:from public static inline function fromFloat(f:Float):Primitive {
        return !Math.isNaN(f) ? f : 0.0;
    }
    
    @:from public static inline function fromBool(b:Bool):Primitive {
        return b;
    }

	public static function isValid(value:Dynamic):Bool {
		return value != null
			&& (Std.isOfType(value, String) || Std.isOfType(value, Int) || Std.isOfType(value, Float) || Std.isOfType(value, Bool));
	}

    
}
