package crossbyte.rpc._internal;

#if macro
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/**
	The kinds of value the compiled lane carries: for each, how it is sized,
	written and read, and the token that names its layout in a method's
	signature. One table, read by the commands macro and the handler macro
	alike, so the two ends of a call cannot disagree on a value's bytes.

	A kind is found from a type, a typedef followed to what it names: a
	typedef renamed is the same kind, a field retyped another. A value that
	may be absent, `Null<T>`, an optional argument, is its kind after a
	byte saying whether it is there.

	Every kind keeps the token it has, and with it every op that names it.
	One made of others names them in its own: an array its element's token
	inside brackets, `[i32]`. `RPCOps.signature` joins whatever tokens it is
	given.

	A kind made of others, an array, is written by code that can throw
	part way through a frame, for a `null` it meets inside the value, and its
	room is what an empty value of its own takes, not the most it can: its
	writer makes more as it goes. Both macros give a frame back that such a
	writer threw out of.
**/
class RPCKinds {
	/** The kind of a value of type `ct`, absence aside, or `null` for a type the compiled lane does not carry. **/
	public static function of(ct:ComplexType, pos:Position):Null<RPCKind> {
		final type:Null<Type> = try Context.resolveType(ct, pos) catch (_:Dynamic) null;
		return type == null ? null : ofType(type, pos);
	}

	/** What a type not carried is called in the error that says so. **/
	public static function nameOf(ct:ComplexType, pos:Position):String {
		try {
			return nameOfType(Context.resolveType(ct, pos));
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

	/** Its token in a signature: `?` before one that may be absent. **/
	public static inline function token(kind:RPCKind, optional:Bool):String {
		return optional ? "?" + kind.token : kind.token;
	}

	/** The bytes a value takes whatever it is, or -1 when that depends on the value: see `room`. **/
	public static inline function size(kind:RPCKind, optional:Bool):Int {
		return kind.size < 0 ? -1 : kind.size + (optional ? 1 : 0);
	}

	/**
		For a kind whose `size` is -1, the bytes to begin a frame with for
		`value`, as an expression of it: the most it takes, or, for a kind
		made of others, what it takes empty. For one that cannot be absent,
		it throws for a value that cannot be sent, `null`, before anything
		is framed.
	**/
	public static function room(kind:RPCKind, optional:Bool, value:Expr):Expr {
		final present:Expr = kind.roomOf(value);
		if (optional) {
			return macro 1 + ($value == null ? 0 : $present);
		}
		final name:Expr = macro $v{kind.name};
		return macro($value == null ? throw crossbyte.rpc._internal.RPCFrame.nullValue($name) : $present);
	}

	/**
		Writes `value` into `frame`, an `RPCFrame` begun with room for it, or
		with room for what it takes empty when the kind is `compound`, whose
		writer makes the rest as it goes.
	**/
	public static function write(kind:RPCKind, optional:Bool, frame:Expr, value:Expr):Expr {
		if (!optional) {
			return kind.write(frame, value);
		}
		final held:String = local();
		final put:Expr = kind.write(frame, macro $i{held});
		return macro {
			var $held = $value;
			if ($i{held} == null) {
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

	/** What a local of this kind holds before a value has been read into it. **/
	public static inline function zero(kind:RPCKind, optional:Bool):Expr {
		return optional ? macro null : kind.zero;
	}

	/** Whether any of `kinds`' writers can throw part way through a frame. **/
	public static function anyCompound(kinds:Array<RPCKind>):Bool {
		for (kind in kinds) {
			if (kind.compound) {
				return true;
			}
		}
		return false;
	}

	// ------------------------------------------------------------ the kinds

	static final INT:RPCKind = {
		name: "Int",
		token: "i32",
		size: 4,
		roomOf: null,
		zero: macro 0,
		compound: false,
		write: (frame, value) -> macro $frame.putInt($value),
		read: (input, end) -> macro $input.readInt(),
		put: (data, at, value) -> macro crossbyte.rpc._internal.RPCBytes.setI32($data, $at, $value),
		get: (data, at) -> macro crossbyte.rpc._internal.RPCBytes.getI32($data, $at)
	};

	static final BOOL:RPCKind = {
		name: "Bool",
		token: "bool",
		size: 1,
		roomOf: null,
		zero: macro false,
		compound: false,
		write: (frame, value) -> macro $frame.putBool($value),
		read: (input, end) -> macro($input.readByte() != 0),
		put: (data, at, value) -> macro crossbyte.rpc._internal.RPCBytes.set8($data, $at, $value ? 1 : 0),
		get: (data, at) -> macro(crossbyte.rpc._internal.RPCBytes.getU8($data, $at) != 0)
	};

	static final FLOAT:RPCKind = {
		name: "Float",
		token: "f64",
		size: 8,
		roomOf: null,
		zero: macro 0.0,
		compound: false,
		write: (frame, value) -> macro $frame.putDouble($value),
		read: (input, end) -> macro $input.readDouble(),
		put: (data, at, value) -> macro crossbyte.rpc._internal.RPCBytes.setF64($data, $at, $value),
		get: (data, at) -> macro crossbyte.rpc._internal.RPCBytes.getF64($data, $at)
	};

	// UTF-8 is at most three bytes a UTF-16 unit, after a varint count.
	static final STRING:RPCKind = {
		name: "String",
		token: "utf8",
		size: -1,
		roomOf: value -> macro $value.length * 3 + 5,
		zero: macro null,
		compound: false,
		write: (frame, value) -> macro $frame.putString($value),
		read: (input, end) -> macro $input.readVarUTF()
	};

	static final BYTES:RPCKind = {
		name: "Bytes",
		token: "bytes",
		size: -1,
		roomOf: value -> macro $value.length + 5,
		zero: macro null,
		compound: false,
		write: (frame, value) -> macro $frame.putBytes($value),
		read: (input, end) -> macro {
			var __len:Int = $input.readVarUInt();
			crossbyte.rpc._internal.RPCWire.requireRoom($input, $end, __len);
			var __bytes = haxe.io.Bytes.alloc(__len);
			$input.readBytes(__bytes, 0, __len);
			__bytes;
		}
	};

	/**
		`Array<T>` of a kind the lane carries, `T` a `Null<>` too: a varint
		count, then each element as its kind is written, with no tag or
		length of its own. The count is checked against what the frame has
		left before anything is made for it, a count is the peer's to
		choose, at the least each element can take, so twenty bytes cannot
		ask for an array of two billion.
	**/
	static function arrayKind(element:RPCKind, optional:Bool, elementType:ComplexType):RPCKind {
		// The least an element takes: its size, or a byte, a String's count,
		// an absent element's presence byte, which every kind takes at least.
		final least:Int = !optional && element.size > 0 ? element.size : 1;
		// Numbers and Bools that cannot be absent: all of them made room for,
		// or checked, at once.
		final fixed:Bool = !optional && element.put != null && element.get != null;
		return {
			name: "Array<" + element.name + ">",
			token: "[" + token(element, optional) + "]",
			size: -1,
			roomOf: value -> macro $value.length * $v{least} + 5,
			zero: macro null,
			compound: true,
			write: (frame, value) -> {
				final list:String = local();
				final item:String = local();
				final name:Expr = macro $v{"Array<" + element.name + ">"};
				final each:Expr = if (fixed) {
					// Room for every element at once, then each put where it
					// goes: no check of room an element, nor a move of the
					// frame's position.
					final at:String = local();
					final put:Expr = element.put(frame, macro $i{at}, macro $i{item});
					macro {
						$frame.fit($i{list}.length * $v{least});
						var $at:Int = $frame.position;
						for ($i{item} in $i{list}) {
							$put;
							$i{at} += $v{least};
						}
						$frame.position = $i{at};
					};
				} else {
					final put:Expr = write(element, optional, frame, macro $i{item});
					macro for ($i{item} in $i{list}) {
						$put;
					};
				};
				macro {
					var $list = $value;
					if ($i{list} == null) {
						throw crossbyte.rpc._internal.RPCFrame.nullValue($name);
					}
					$frame.putVarUInt($i{list}.length);
					$each;
				};
			},
			read: (input, end) -> {
				final count:String = local();
				final list:String = local();
				final at:String = local();
				final arrayType:ComplexType = TPath({pack: [], name: "Array", params: [TPType(optional ? nullOf(elementType) : elementType)]});
				if (fixed) {
					// Checked once for all of them, within the frame and within
					// what was read, then each read where it is.
					final data:String = local();
					final from:String = local();
					final limit:String = local();
					final get:Expr = element.get(macro $i{data}, macro $i{from});
					final fill:Expr = Context.defined("js") ? macro for (_ in 0...$i{count}) {
						$i{list}.push($get);
						$i{from} += $v{least};
					} : macro {
						$i{list}.resize($i{count});
						for ($i{at} in 0...$i{count}) {
							$i{list}[$i{at}] = $get;
							$i{from} += $v{least};
						}
					};
					return macro {
						var $count:Int = $input.readVarUInt();
						var $limit:Int = $end;
						if ($i{limit} > $input.length) {
							$i{limit} = $input.length;
						}
						crossbyte.rpc._internal.RPCWire.requireCount($input, $i{limit}, $i{count}, $v{least});
						var $data:crossbyte.io.ByteArray.ByteArrayData = cast $input;
						var $from:Int = $input.position;
						var $list:$arrayType = [];
						$fill;
						$input.position = $i{from};
						$i{list};
					};
				}
				final get:Expr = read(element, optional, input, end);
				final fill:Expr = Context.defined("js") ? macro for (_ in 0...$i{count}) {
					$i{list}.push($get);
				} : macro {
					$i{list}.resize($i{count});
					for ($i{at} in 0...$i{count}) {
						$i{list}[$i{at}] = $get;
					}
				};
				macro {
					var $count:Int = $input.readVarUInt();
					crossbyte.rpc._internal.RPCWire.requireCount($input, $end, $i{count}, $v{least});
					var $list:$arrayType = [];
					$fill;
					$i{list};
				};
			}
		};
	}

	// ------------------------------------------------------------ types

	/**
		The kind of `type`, absence aside, a `Null<T>` is `T`'s kind, which
		a caller asks `isNullType` about, or `null` when the lane does not
		carry it.
	**/
	public static function ofType(type:Type, pos:Position):Null<RPCKind> {
		return switch (type) {
			case TMono(ref):
				ref.get() == null ? null : ofType(ref.get(), pos);
			case TLazy(lazy):
				ofType(lazy(), pos);
			case TType(_, _):
				// One typedef at a time, as it names its kind.
				ofType(Context.follow(type, true), pos);
			case TAbstract(ref, params):
				final abs = ref.get();
				switch (pathKey(abs.pack, abs.name)) {
					case "Int": INT;
					case "Bool": BOOL;
					case "Float": FLOAT;
					case "Null" if (params.length == 1): ofType(params[0], pos);
					case _: null;
				}
			case TInst(ref, params):
				final cls = ref.get();
				switch (pathKey(cls.pack, cls.name)) {
					case "String": STRING;
					case "haxe.io.Bytes": BYTES;
					case "Array" if (params.length == 1):
						final element:Null<RPCKind> = ofType(params[0], pos);
						element == null ? null : arrayKind(element, isNullType(params[0]), RPCContractMacroTools.fullComplexType(stripNull(params[0])));
					case _: null;
				}
			case _:
				null;
		}
	}

	/** Whether `type` is `Null<T>`, however it is named: one typedef at a time, since a full follow drops the `Null`. **/
	public static function isNullType(type:Type):Bool {
		var current:Null<Type> = type;
		while (current != null) {
			switch (current) {
				case TAbstract(ref, [_]) if (ref.get().name == "Null" && ref.get().pack.length == 0):
					return true;
				case TType(_, _):
					current = Context.follow(current, true);
				case TMono(ref):
					current = ref.get();
				case TLazy(lazy):
					current = lazy();
				case _:
					return false;
			}
		}
		return false;
	}

	/** `type` without the `Null<>` around it, however it is named. **/
	public static function stripNull(type:Type):Type {
		var current:Type = type;
		while (true) {
			switch (current) {
				case TAbstract(ref, [inner]) if (ref.get().name == "Null" && ref.get().pack.length == 0):
					return inner;
				case TType(_, _):
					final next:Type = Context.follow(current, true);
					if (next == current) {
						return type;
					}
					current = next;
				case TMono(ref) if (ref.get() != null):
					current = ref.get();
				case TLazy(lazy):
					current = lazy();
				case _:
					return type;
			}
		}
	}

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

	static function nullOf(ct:ComplexType):ComplexType {
		return TPath({pack: [], name: "Null", params: [TPType(ct)]});
	}

	static function nameOfType(type:Type):String {
		return switch (Context.follow(type)) {
			case TAbstract(t, []):
				pathKey(t.get().pack, t.get().name);
			case TInst(t, []):
				pathKey(t.get().pack, t.get().name);
			case TType(t, []):
				pathKey(t.get().pack, t.get().name);
			case _:
				TypeTools.toString(type);
		}
	}

	static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}

	static var locals:Int = 0;

	/** A local's name no other generated local has, for kinds whose code nests. **/
	public static function local():String {
		return "__rpc" + (locals++);
	}
}

/**
	A kind of value on the compiled lane.

	- `name`: what it is called in an error.
	- `token`: its layout's name in a method's signature; see `RPCOps`.
	- `size`: the bytes every value of it takes, or -1 when that depends on
	  the value, and then `roomOf` is the bytes to begin a frame with for a
	  value that is there: the most it takes, or for a `compound` kind what
	  it takes empty.
	- `zero`: what a local of it holds before a value is read into it.
	- `compound`: made of other values, so its writer can throw part way
	  through a frame (for a `null` inside it) and makes room as it goes.
	- `write`: writes a value into a frame, an `RPCFrame`.
	- `read`: reads one from a `ByteArrayInput`, in a frame ending at `end`.
	- `put` and `get`, for a kind of fixed size that is a number or a
	  `Bool`: writes a value at a place in a `Bytes`, or reads one, with no
	  check, an array of them makes room for, or checks it has, all of
	  them at once, then puts or gets each where it goes.
**/
typedef RPCKind = {
	final name:String;
	final token:String;
	final size:Int;
	final roomOf:Null<Expr->Expr>;
	final zero:Expr;
	final compound:Bool;
	final write:(Expr, Expr) -> Expr;
	final read:(Expr, Expr) -> Expr;
	@:optional final put:(Expr, Expr, Expr) -> Expr;
	@:optional final get:(Expr, Expr) -> Expr;
}
#end
