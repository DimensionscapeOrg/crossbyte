package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCKinds;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/**
	The bit layout's fields: `@:quantize(min, max, bits)` on a `Float` or
	`Float32` field, `@:range(min, max)` on an integer one. Each is a *bit
	kind*, written into the structure's bit section in its bits, LSB first,
	as `crossbyte.io.BitWriter` lays them out, so a section reads back with a
	`BitReader` too; a structure with one is in the bit layout (`b{...}` in
	a signature).

	A quantized value is one of 2^bits evenly spaced points from `min` to
	`max`, both included, rounded as `floor(t * (2^bits - 1) + 0.5)`:
	`BitWriter.writeQuantized`'s arithmetic, clamped to the range, NaN
	refused. It reads back as `BitReader.readQuantized` reads it. A ranged
	integer takes the bits its range needs (none when `min == max`); one
	outside it is refused, and a read past `max` is unreadable.

	Bounds are number literals (a minus sign allowed), or static inline
	constants of a class (`ShipRules.MAX_ENGINE_HEAT`), resolved by path:
	written out in full, in the structure's package or module, or imported
	in its module; and `+`, `-`, `*` and `/` of those.

	Tokens: `q<bits>(<min>,<max>)`, the bounds as their IEEE 754 binary64
	bits in 16 hex digits, exact from any compiler; `r(<min>,<max>)` in
	decimal. Changing a bound or a width changes the op.
**/
class RPCBits {
	/**
		The kind of a structure's field, given its kind as a type: a bit kind
		when it is marked `@:quantize` or `@:range`, else `kind` itself.
	**/
	public static function fieldKind(field:ClassField, kind:RPCKind, optional:Bool, owner:String, module:Null<String>):RPCKind {
		final quantize = field.meta.extract(":quantize");
		final range = field.meta.extract(":range");
		if (quantize.length == 0 && range.length == 0) {
			return kind;
		}
		final where:String = 'field ${field.name} of $owner';
		if (quantize.length > 0 && range.length > 0) {
			Context.error('RPC $where is marked both @:quantize and @:range: one is its encoding.', field.pos);
		}
		if (optional) {
			Context.error('RPC $where may be absent, and a field marked @:quantize or @:range cannot be: give it a value that stands for none.', field.pos);
		}
		if (quantize.length > 0) {
			if (kind.token != "f64" && kind.token != "f32") {
				Context.error('RPC $where: @:quantize is for a Float or Float32 field, and this one is ${kind.name}.', field.pos);
			}
			final params:Array<Expr> = quantize[0].params;
			if (params == null || params.length != 3) {
				Context.error('RPC $where: @:quantize takes three arguments, (min, max, bits).', field.pos);
			}
			final min:Float = number(params[0], where, module, field.pos);
			final max:Float = number(params[1], where, module, field.pos);
			final width:Float = number(params[2], where, module, field.pos);
			if (width != Math.ffloor(width) || width < 1 || width > 31) {
				Context.error('RPC $where: @:quantize takes from 1 to 31 bits, not $width.', field.pos);
			}
			if (!Math.isFinite(min) || !Math.isFinite(max) || !(max > min) || !Math.isFinite(max - min)) {
				Context.error('RPC $where: @:quantize needs finite bounds with the maximum above the minimum, not $min to $max.', field.pos);
			}
			return quantized(kind, Std.int(width), min, max, where);
		}
		if (["i32", "i8", "u8", "i16", "u16"].indexOf(kind.token) < 0) {
			Context.error('RPC $where: @:range is for an Int, Int8, UInt8, Int16 or UInt16 field, and this one is ${kind.name}.', field.pos);
		}
		final params:Array<Expr> = range[0].params;
		if (params == null || params.length != 2) {
			Context.error('RPC $where: @:range takes two arguments, (min, max).', field.pos);
		}
		final min:Float = number(params[0], where, module, field.pos);
		final max:Float = number(params[1], where, module, field.pos);
		if (min != Math.ffloor(min) || max != Math.ffloor(max) || min < -2147483648.0 || max > 2147483647.0 || max < min || max - min > 2147483647.0) {
			Context.error('RPC $where: @:range takes whole numbers with the maximum not below the minimum, at most 2^31 - 1 apart, not $min to $max.',
				field.pos);
		}
		return ranged(kind, Std.int(min), Std.int(max), where);
	}

	/** A quantized `Float` or `Float32`. **/
	static function quantized(kind:RPCKind, width:Int, min:Float, max:Float, where:String):RPCKind {
		final steps:Float = width == 31 ? 2147483647.0 : (1 << width) - 1.0;
		final span:Float = max - min;
		final single:Bool = kind.token == "f32";
		final whereExpr:Expr = macro $v{where};
		// A Float32 is held at single precision natively; elsewhere it is
		// rounded first, so every target quantizes the same value.
		final rounded = (value:Expr) -> single ? macro crossbyte.rpc._internal.RPCBits.single($value) : value;
		final step = (value:Expr) -> {
			final v:String = RPCKinds.local();
			final t:String = RPCKinds.local();
			final held:Expr = rounded(macro(cast $value : Float));
			macro {
				final $v:Float = $held;
				if ($i{v} != $i{v}) {
					throw new crossbyte.errors.ArgumentError("A quantized value cannot be NaN: " + $whereExpr);
				}
				final $t:Float = $i{v} <= $v{min} ? 0.0 : ($i{v} >= $v{max} ? 1.0 : ($i{v} - $v{min}) / $v{span});
				Std.int($i{t} * $v{steps} + 0.5);
			};
		};
		// For comparing: NaN as a step of its own, which a write refuses.
		final stepOrNaN = (value:Expr) -> {
			final v:String = RPCKinds.local();
			final held:Expr = rounded(macro(cast $value : Float));
			macro {
				final $v:Float = $held;
				$i{v} != $i{v} ? -1 : Std.int(($i{v} <= $v{min} ? 0.0 : ($i{v} >= $v{max} ? 1.0 : ($i{v} - $v{min}) / $v{span})) * $v{steps} + 0.5);
			};
		};
		return {
			name: kind.name,
			token: "q" + width + "(" + hex(min) + "," + hex(max) + ")",
			size: -1,
			roomOf: value -> macro 0,
			zero: kind.zero,
			compound: false,
			write: (frame, value) -> throw "a bit kind is written in a bit section",
			read: (input, end) -> throw "a bit kind is read from a bit section",
			bits: {
				width: width,
				put: step,
				get: raw -> {
					final t:String = RPCKinds.local();
					macro {
						final $t:Float = $raw / $v{steps};
						$v{min} * (1 - $i{t}) + $v{max} * $i{t};
					};
				}
			},
			same: (a, b) -> macro ${stepOrNaN(a)} == ${stepOrNaN(b)}
		};
	}

	/** A ranged integer. **/
	static function ranged(kind:RPCKind, min:Int, max:Int, where:String):RPCKind {
		final span:Int = max - min;
		var width:Int = 0;
		var left:Int = span;
		while (left != 0) {
			width++;
			left >>>= 1;
		}
		final whereExpr:Expr = macro $v{where};
		return {
			name: kind.name,
			token: "r(" + min + "," + max + ")",
			size: -1,
			roomOf: value -> macro 0,
			zero: kind.zero,
			compound: false,
			write: (frame, value) -> throw "a bit kind is written in a bit section",
			read: (input, end) -> throw "a bit kind is read from a bit section",
			bits: {
				width: width,
				put: value -> {
					final v:String = RPCKinds.local();
					macro {
						final $v:Int = cast $value;
						if ($i{v} < $v{min} || $i{v} > $v{max}) {
							throw new crossbyte.errors.ArgumentError($i{v} + " is outside " + $v{min} + " to " + $v{max} + ": " + $whereExpr);
						}
						$i{v} - $v{min};
					};
				},
				get: raw -> {
					final r:String = RPCKinds.local();
					macro {
						final $r:Int = $raw;
						if ($i{r} > $v{span}) {
							throw "RPC ranged value past its range";
						}
						$i{r} + $v{min};
					};
				}
			},
			same: (a, b) -> macro(cast $a : Int) == (cast $b : Int)
		};
	}

	/** `value` rounded to single precision, as a `Float32` is held natively. **/
	public static inline function single(value:Float):Float {
		#if (cpp || jvm || java || hl || cs)
		return value;
		#else
		return crossbyte.rpc._internal.RPCSame.round(value);
		#end
	}

	// ------------------------------------------------------------ bounds

	/** A bound: a literal, a static inline constant, or arithmetic of them. **/
	static function number(e:Expr, where:String, module:Null<String>, pos:Position):Float {
		return switch (e.expr) {
			case EConst(CInt(text)):
				StringTools.startsWith(text, "0x") ? (Std.parseInt(text) : Float) : Std.parseFloat(text);
			case EConst(CFloat(text)):
				Std.parseFloat(text);
			case EParenthesis(inner):
				number(inner, where, module, pos);
			case EUnop(OpNeg, false, inner):
				-number(inner, where, module, pos);
			case EBinop(op, a, b):
				final x:Float = number(a, where, module, pos);
				final y:Float = number(b, where, module, pos);
				switch (op) {
					case OpAdd: x + y;
					case OpSub: x - y;
					case OpMult: x * y;
					case OpDiv: x / y;
					case _: Context.error('RPC $where: a bound is a number, a constant, or + - * / of them.', e.pos);
				}
			case EField(owner, name):
				constant(pathOf(owner), name, where, module, e.pos);
			case EConst(CIdent(name)):
				constant(null, name, where, module, e.pos);
			case _:
				Context.error('RPC $where: a bound is a number, a constant, or + - * / of them.', e.pos);
		}
	}

	/**
		The value of the static inline constant `name` of the class at `path`
		(`null`: the structure's own module), found as the structure's module
		would find it.
	**/
	static function constant(path:Null<String>, name:String, where:String, module:Null<String>, pos:Position):Float {
		final candidates:Array<String> = [];
		final moduleParts:Array<String> = module == null ? [] : module.split(".");
		final pack:Array<String> = moduleParts.slice(0, moduleParts.length - 1);
		if (path == null) {
			// A constant of a class in the structure's own module.
			if (module != null) {
				for (type in Context.getModule(module)) {
					switch (type) {
						case TInst(ref, _):
							final found = staticValue(ref.get(), name);
							if (found != null) {
								return found;
							}
						case _:
					}
				}
			}
			Context.error('RPC $where: no constant $name in its module; name its class, ShipRules.$name.', pos);
		}
		candidates.push(path);
		if (pack.length > 0) {
			candidates.push(pack.join(".") + "." + path);
		}
		if (module != null) {
			candidates.push(module + "." + path);
		}
		for (imported in importsOf(pos)) {
			final parts:Array<String> = imported.split(".");
			if (parts[parts.length - 1] == path.split(".")[0]) {
				candidates.push(parts.slice(0, parts.length - 1).concat(path.split(".")).join("."));
			}
		}
		for (candidate in candidates) {
			final type:Null<Type> = try Context.getType(candidate) catch (_:Dynamic) null;
			if (type == null) {
				continue;
			}
			switch (type) {
				case TInst(ref, _):
					final found = staticValue(ref.get(), name);
					if (found != null) {
						return found;
					}
					Context.error('RPC $where: $path.$name is not a static inline constant number.', pos);
				case _:
			}
		}
		Context.error('RPC $where: no class $path found for $path.$name. Write its path out in full, or use a number.', pos);
		return 0;
	}

	/** The value of a static inline number of `cls`, or `null`. **/
	static function staticValue(cls:ClassType, name:String):Null<Float> {
		for (field in cls.statics.get()) {
			if (field.name != name) {
				continue;
			}
			switch (field.kind) {
				case FVar(AccInline, _):
				case _:
					return null;
			}
			final typed:Null<TypedExpr> = field.expr();
			return typed == null ? null : valueOf(typed);
		}
		return null;
	}

	static function valueOf(e:TypedExpr):Null<Float> {
		return switch (e.expr) {
			case TConst(TInt(v)): v;
			case TConst(TFloat(text)): Std.parseFloat(text);
			case TParenthesis(inner) | TCast(inner, null) | TMeta(_, inner): valueOf(inner);
			case TUnop(OpNeg, false, inner):
				final v = valueOf(inner);
				v == null ? null : -v;
			case _: null;
		}
	}

	/** The types the module holding `pos` imports, read from its source. **/
	static function importsOf(pos:Position):Array<String> {
		final file:String = Context.getPosInfos(pos).file;
		final found:Array<String> = [];
		final source:Null<String> = try sys.io.File.getContent(file) catch (_:Dynamic) null;
		if (source == null) {
			return found;
		}
		final pattern = ~/^\s*import\s+([A-Za-z0-9_.]+)\s*;/m;
		var rest:String = source;
		while (pattern.match(rest)) {
			found.push(pattern.matched(1));
			rest = pattern.matchedRight();
		}
		return found;
	}

	static function pathOf(e:Expr):String {
		return switch (e.expr) {
			case EConst(CIdent(name)): name;
			case EField(owner, name): pathOf(owner) + "." + name;
			case _: Context.error("A bound's class is a type path.", e.pos);
		}
	}

	/** `value`'s IEEE 754 binary64 bits, 16 hex digits. **/
	static function hex(value:Float):String {
		final bits = haxe.io.FPHelper.doubleToI64(value);
		return StringTools.hex(bits.high, 8).toLowerCase() + StringTools.hex(bits.low, 8).toLowerCase();
	}
}

/** How a bit kind goes into a bit section: its width, the bits of a value, and a value of the bits. **/
typedef RPCBitField = {
	final width:Int;
	final put:(value:Expr) -> Expr;
	final get:(raw:Expr) -> Expr;
}
#else
/** At run time: the rounding generated bit-layout code calls. **/
@:noCompletion
class RPCBits {
	/** `value` rounded to single precision, as a `Float32` is held natively. **/
	public static inline function single(value:Float):Float {
		#if (cpp || jvm || java || hl || cs)
		return value;
		#else
		return crossbyte.rpc._internal.RPCSame.round(value);
		#end
	}
}
#end
