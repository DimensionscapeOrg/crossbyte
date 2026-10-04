package crossbyte.rpc._internal;

#if macro
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

/**
	The kinds of value the compiled lane carries: for each, how it is sized,
	written and read, and the token that names its layout in a method's
	signature. One table, read by the commands macro and the handler macro
	alike, so the two ends of a call cannot disagree on a value's bytes.

	A kind is found from a type, a typedef followed to what it names: a
	typedef renamed is the same kind, a field retyped another. A value that
	may be absent, `Null<T>`, an optional argument, is its kind after a
	byte saying whether it is there.

	A kind added later gives a token of its own, and every kind here keeps
	the token it has, and with it every op that names it.
**/
class RPCKinds {
	/** The kind of a value of type `ct`, absence aside, or `null` for a type the compiled lane does not carry. **/
	public static function of(ct:ComplexType, pos:Position):Null<RPCKind> {
		return switch (typeKey(ct, pos)) {
			case "Int": INT;
			case "Bool": BOOL;
			case "Float": FLOAT;
			case "String": STRING;
			case "haxe.io.Bytes": BYTES;
			case _: null;
		}
	}

	/** What a type not carried is called in the error that says so. **/
	public static function nameOf(ct:ComplexType, pos:Position):String {
		return typeKey(ct, pos);
	}

	/** Its token in a signature: `?` before one that may be absent. **/
	public static inline function token(kind:RPCKind, optional:Bool):String {
		return optional ? "?" + kind.token : kind.token;
	}

	/** The bytes a value takes whatever it is, or -1 when that depends on the value: see `room`. **/
	public static inline function size(kind:RPCKind, optional:Bool):Int {
		return kind.size < 0 ? -1 : kind.size + (optional ? 1 : 0);
	}

	/**
		For a kind whose `size` is -1, the most bytes `value` takes, as an
		expression of it. For one that cannot be absent, it throws for a
		value that cannot be sent, `null`, before anything is framed.
	**/
	public static function room(kind:RPCKind, optional:Bool, value:Expr):Expr {
		final present:Expr = kind.roomOf(value);
		if (optional) {
			return macro 1 + ($value == null ? 0 : $present);
		}
		final name:Expr = macro $v{kind.name};
		return macro($value == null ? throw crossbyte.rpc._internal.RPCFrame.nullValue($name) : $present);
	}

	/** Writes `value` into `frame`, an `RPCFrame` begun with room for it. **/
	public static function write(kind:RPCKind, optional:Bool, frame:Expr, value:Expr):Expr {
		final put:Expr = kind.write(frame, value);
		if (!optional) {
			return put;
		}
		return macro {
			if ($value == null) {
				$frame.putByte(0);
			} else {
				$frame.putByte(1);
				$put;
			}
		};
	}

	/** Reads a value from `input`, a `ByteArrayInput`, in a frame ending at `end`. **/
	public static function read(kind:RPCKind, optional:Bool, input:Expr, end:Expr):Expr {
		final get:Expr = kind.read(input, end);
		return optional ? macro($input.readByte() != 0 ? $get : null) : get;
	}

	static final INT:RPCKind = {
		name: "Int",
		token: "i32",
		size: 4,
		roomOf: null,
		write: (frame, value) -> macro $frame.putInt($value),
		read: (input, end) -> macro $input.readInt()
	};

	static final BOOL:RPCKind = {
		name: "Bool",
		token: "bool",
		size: 1,
		roomOf: null,
		write: (frame, value) -> macro $frame.putBool($value),
		read: (input, end) -> macro($input.readByte() != 0)
	};

	static final FLOAT:RPCKind = {
		name: "Float",
		token: "f64",
		size: 8,
		roomOf: null,
		write: (frame, value) -> macro $frame.putDouble($value),
		read: (input, end) -> macro $input.readDouble()
	};

	// UTF-8 is at most three bytes a UTF-16 unit, after a varint count.
	static final STRING:RPCKind = {
		name: "String",
		token: "utf8",
		size: -1,
		roomOf: value -> macro $value.length * 3 + 5,
		write: (frame, value) -> macro $frame.putString($value),
		read: (input, end) -> macro $input.readVarUTF()
	};

	static final BYTES:RPCKind = {
		name: "Bytes",
		token: "bytes",
		size: -1,
		roomOf: value -> macro $value.length + 5,
		write: (frame, value) -> macro $frame.putBytes($value),
		read: (input, end) -> macro {
			var __len:Int = $input.readVarUInt();
			crossbyte.rpc._internal.RPCWire.requireRoom($input, $end, __len);
			var __bytes = haxe.io.Bytes.alloc(__len);
			$input.readBytes(__bytes, 0, __len);
			__bytes;
		}
	};

	// ------------------------------------------------------------------ types

	public static function isNullWrapped(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath({name: "Null", params: _}): true;
			case _: false;
		}
	}

	public static function unwrapNull(ct:ComplexType):ComplexType {
		return switch (ct) {
			case TPath({name: "Null", params: [TPType(inner)]}): inner;
			case _: ct;
		}
	}

	static function typeKey(ct:ComplexType, pos:Position):String {
		try {
			return resolvedTypeKey(Context.resolveType(ct, pos));
		} catch (_:Dynamic) {
			return switch (ct) {
				case TPath(tp):
					var pack:String = tp.pack.length > 0 ? tp.pack.join(".") + "." : "";
					pack + tp.name;
				case _:
					ComplexTypeTools.toString(ct);
			}
		}
	}

	static function resolvedTypeKey(type:Type):String {
		return switch (Context.follow(type)) {
			case TAbstract(t, _):
				pathKey(t.get().pack, t.get().name);
			case TInst(t, _):
				pathKey(t.get().pack, t.get().name);
			case TType(t, _):
				pathKey(t.get().pack, t.get().name);
			case _:
				Std.string(type);
		}
	}

	static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}
}

/**
	A kind of value on the compiled lane.

	- `name`: what it is called in an error.
	- `token`: its layout's name in a method's signature; see `RPCOps`.
	- `size`: the bytes every value of it takes, or -1 when that depends on
	  the value, and then `roomOf` is the most a value takes, as an
	  expression of a value that is there.
	- `write`: writes a value into a frame, an `RPCFrame`.
	- `read`: reads one from a `ByteArrayInput`, in a frame ending at `end`.
**/
typedef RPCKind = {
	final name:String;
	final token:String;
	final size:Int;
	final roomOf:Null<Expr->Expr>;
	final write:(Expr, Expr) -> Expr;
	final read:(Expr, Expr) -> Expr;
}
#end
