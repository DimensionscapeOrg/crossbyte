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
	`max`, both included: its step `floor((v - min) * (2^bits - 1) / (max -
	min) + 0.5)`, the factor folded into one constant, clamped to the range,
	NaN refused, as `BitWriter.writeQuantized` quantizes. It reads back as
	`BitReader.readQuantized` reads it, the ends exact. A ranged
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
		// The step of a value: floor((v - min) * (steps / span) + 0.5), its
		// ends exact. One multiplication where BitWriter divides by the span
		// and multiplies by the steps: a patch compares and writes many of
		// them, and a division is most of their cost. The same arithmetic
		// on every target; a value at an exact half step may round to the
		// other neighbour than BitWriter's would, within half a step either way.
		final scale:Float = steps / span;
		final topStep:Int = width == 31 ? 2147483647 : (1 << width) - 1;
		final stepOf = (v:String) -> macro $i{v} <= $v{min} ? 0 : ($i{v} >= $v{max} ? $v{topStep} : Std.int(($i{v} - $v{min}) * $v{scale} + 0.5));
		final step = (value:Expr) -> {
			final v:String = RPCKinds.local();
			final held:Expr = rounded(macro(cast $value : Float));
			macro {
				final $v:Float = $held;
				if ($i{v} != $i{v}) {
					throw new crossbyte.errors.ArgumentError("A quantized value cannot be NaN: " + $whereExpr);
				}
				${stepOf(v)};
			};
		};
		// For comparing: NaN as a step of its own, which a write refuses.
		final stepOrNaN = (value:Expr) -> {
			final v:String = RPCKinds.local();
			final held:Expr = rounded(macro(cast $value : Float));
			macro {
				final $v:Float = $held;
				$i{v} != $i{v} ? -1 : ${stepOf(v)};
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
				// As BitReader.readQuantized reads it: the ends exact.
				get: raw -> {
					final t:String = RPCKinds.local();
					macro {
						final $t:Float = $raw / $v{steps};
						$v{min} * (1 - $i{t}) + $v{max} * $i{t};
					};
				}
			},
			// The same value is the same step, which most fields that did not
			// change are: quantized only when they differ.
			same: (a, b) -> macro(cast $a : Float) == (cast $b : Float) || ${stepOrNaN(a)} == ${stepOrNaN(b)}
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

	// ------------------------------------------------------------ the layout

	/**
		Whether a structure of `fields` is in the bit layout: `marked`
		(`@:rpcBits`), or one of its fields is a bit kind.
	**/
	public static function isBitLayout(fields:Array<RPCStructs.StructField>, marked:Bool):Bool {
		if (marked) {
			return true;
		}
		for (field in fields) {
			if (field.kind.bits != null) {
				return true;
			}
		}
		return false;
	}

	/** `fields`, a `Bool` among them one bit, as the bit layout has it. **/
	public static function withBoolBits(fields:Array<RPCStructs.StructField>):Array<RPCStructs.StructField> {
		return [
			for (field in fields)
				field.kind.token == "bool" && field.kind.bits == null ? {
					name: field.name,
					pinned: field.pinned,
					type: field.type,
					optional: field.optional,
					kind: BOOL_BIT,
					pos: field.pos
				} : field
		];
	}

	/** Whether every field of a structure in the bit layout is in its bit section: an array of it is one run of bits. **/
	public static function bitsOnly(fields:Array<RPCStructs.StructField>):Bool {
		for (field in fields) {
			if (field.kind.bits == null) {
				return false;
			}
		}
		return fields.length > 0;
	}

	/** The fewest bits a value of a structure all of bits takes: its presence bits and the bits of the fields that cannot be absent. **/
	public static function leastBits(fields:Array<RPCStructs.StructField>):Int {
		var bits:Int = 0;
		for (field in fields) {
			bits += field.optional ? 1 : field.kind.bits.width;
		}
		return bits;
	}

	/** A `Bool` in the bit layout: one bit. **/
	static final BOOL_BIT:RPCKind = {
		name: "Bool",
		token: "bool",
		size: -1,
		roomOf: value -> macro 0,
		zero: macro false,
		compound: false,
		write: (frame, value) -> throw "a bit kind is written in a bit section",
		read: (input, end) -> throw "a bit kind is read from a bit section",
		bits: {
			width: 1,
			put: value -> macro((cast $value : Bool) ? 1 : 0),
			get: raw -> macro($raw != 0)
		},
		same: (a, b) -> macro(cast $a : Bool) == (cast $b : Bool)
	};

	/**
		Statements writing a whole value in the bit layout, `value` being an
		expression of it, into `frame`:

		```
		bit section, LSB first:
		  per field in wire order: its presence bit, if it may be absent;
		                           its bits, if a bit kind and there
		  0-7 bits of zeros, to a whole byte
		byte section: per field in wire order that is not a bit kind and is
		              there, as the byte layout writes it (with no presence byte)
		```
	**/
	public static function writeValue(fields:Array<RPCStructs.StructField>, value:Expr):Array<Expr> {
		final stmts:Array<Expr> = [(macro var __acc:Int = 0), (macro var __fill:Int = 0)];
		for (e in writeFieldBits(fields, value, true)) {
			stmts.push(e);
		}
		stmts.push(macro if (__fill > 0) frame.putByte(__acc & 0xFF));
		for (i in 0...fields.length) {
			final field = fields[i];
			if (field.kind.bits != null) {
				continue;
			}
			final name:String = field.name;
			final put:Expr = RPCKinds.write(field.kind, false, macro frame, macro $value.$name);
			stmts.push(field.optional ? macro if ($i{presence(i)}) $put : put);
		}
		return stmts;
	}

	/**
		The bit section's statements for a value's fields (`declare`: with
		the presence locals declared), leaving `__p<i>` set for each field
		that may be absent.
	**/
	public static function writeFieldBits(fields:Array<RPCStructs.StructField>, value:Expr, declare:Bool):Array<Expr> {
		final stmts:Array<Expr> = [];
		for (i in 0...fields.length) {
			final field = fields[i];
			final name:String = field.name;
			final get:Expr = macro $value.$name;
			final p:String = presence(i);
			if (field.optional) {
				stmts.push(declare ? macro var $p:Bool = $get != null : macro $i{p} = $get != null);
				for (e in RPCPatches.putBits(macro $i{p} ? 1 : 0, 1)) {
					stmts.push(e);
				}
			}
			final bits = field.kind.bits;
			if (bits != null) {
				final put:Array<Expr> = RPCPatches.putBits(bits.put(get), bits.width);
				stmts.push(field.optional ? macro if ($i{p}) $b{put} : macro $b{put});
			}
		}
		return stmts;
	}

	/**
		Statements reading a whole value in the bit layout: `assign(field, i,
		value)` sets each field; `readBytes(field)`, a field of the byte
		section that is there (as the byte layout reads it, with no presence
		byte; `null`: as `RPCKinds` reads it).
	**/
	public static function readValue(fields:Array<RPCStructs.StructField>, input:Expr, end:Expr, assign:(RPCStructs.StructField, Int, Expr) -> Expr,
			?readBytes:RPCStructs.StructField->Expr):Array<Expr> {
		final stmts:Array<Expr> = [(macro var __acc:Int = 0), (macro var __have:Int = 0)];
		for (e in readFieldBits(fields, assign, true)) {
			stmts.push(e);
		}
		for (i in 0...fields.length) {
			final field = fields[i];
			if (field.kind.bits != null) {
				continue;
			}
			final get:Expr = readBytes != null ? readBytes(field) : RPCKinds.read(field.kind, false, input, end);
			stmts.push(assign(field, i, field.optional ? macro($i{presence(i)} ? $get : null) : get));
		}
		return stmts;
	}

	/** The bit section's statements for a value's fields, reading `input` (`declare`: with the presence locals declared). **/
	public static function readFieldBits(fields:Array<RPCStructs.StructField>, assign:(RPCStructs.StructField, Int, Expr) -> Expr, declare:Bool):Array<Expr> {
		final stmts:Array<Expr> = [];
		for (i in 0...fields.length) {
			final field = fields[i];
			final p:String = presence(i);
			if (field.optional) {
				final take:Expr = RPCPatches.takeBits(1);
				stmts.push(declare ? macro var $p:Bool = $take != 0 : macro $i{p} = $take != 0);
			}
			final bits = field.kind.bits;
			if (bits != null) {
				final get:Expr = bits.get(RPCPatches.takeBits(bits.width));
				stmts.push(assign(field, i, field.optional ? macro($i{p} ? $get : null) : get));
			}
		}
		return stmts;
	}

	/**
		An array of a class whose fields are all in its bit section, as one
		run: a varint count, then every element's bits, one after another,
		and zeros to a whole byte once at the end, where each element alone
		would pad its own.
	**/
	public static function runWrite(info:RPCStructs.StructInfo, frame:Expr, list:Expr, name:String):Expr {
		final item:String = RPCKinds.local();
		final nameExpr:Expr = macro $v{name};
		final elementName:Expr = macro $v{info.name};
		final each:Array<Expr> = writeFieldBits(info.fields, macro $i{item}, true);
		final held:String = RPCKinds.local();
		return macro {
			final $held = $list;
			if ($i{held} == null) {
				throw crossbyte.rpc._internal.RPCFrame.nullValue($nameExpr);
			}
			$frame.putVarUInt($i{held}.length);
			var __acc:Int = 0;
			var __fill:Int = 0;
			${named(frame, "frame")};
			for ($i{item} in $i{held}) {
				if ($i{item} == null) {
					throw crossbyte.rpc._internal.RPCFrame.nullValue($elementName);
				}
				$b{each};
			}
			if (__fill > 0) {
				frame.putByte(__acc & 0xFF);
			}
		};
	}

	/**
		Reads a run `runWrite` wrote into `held` (`null`: a new array), its
		element instances kept and read into, and answers the array. The count
		is checked first against what the frame has left, at the fewest bits
		an element takes.
	**/
	public static function runRead(info:RPCStructs.StructInfo, input:Expr, end:Expr, held:Expr):Expr {
		final ctor:TypePath = switch (info.type) {
			case TPath(path): path;
			case _: throw "a class's type is a path";
		};
		final t:ComplexType = info.type;
		final count:String = RPCKinds.local();
		final list:String = RPCKinds.local();
		final at:String = RPCKinds.local();
		final made:String = RPCKinds.local();
		final least:Int = leastBits(info.fields);
		final assign = (field:RPCStructs.StructField, i:Int, value:Expr) -> {
			final fname:String = field.name;
			return macro $i{made}.$fname = $value;
		};
		final each:Array<Expr> = readFieldBits(info.fields, assign, true);
		return macro {
			final $count:Int = $input.readVarUInt();
			final __limit:Int = $end < $input.length ? $end : $input.length;
			if ($i{count} < 0 || ($i{count} : Float) * $v{least} > (__limit - $input.position) * 8.0) {
				throw "RPC frame names more than it holds";
			}
			var $list:Array<$t> = $held;
			if ($i{list} == null) {
				$i{list} = [];
			}
			if ($i{list}.length > $i{count}) {
				$i{list}.resize($i{count});
			}
			var __acc:Int = 0;
			var __have:Int = 0;
			${named(input, "input")};
			for ($i{at} in 0...$i{count}) {
				var $made:$t = $i{at} < $i{list}.length ? $i{list}[$i{at}] : null;
				if ($i{made} == null) {
					$i{made} = new $ctor();
				}
				$b{each};
				if ($i{at} < $i{list}.length) {
					$i{list}[$i{at}] = $i{made};
				} else {
					$i{list}.push($i{made});
				}
			}
			$i{list};
		};
	}

	/** `e` as a local called `name`, which the bit cursor's code names: nothing when it is one already. **/
	static function named(e:Expr, name:String):Expr {
		return switch (e.expr) {
			case EConst(CIdent(n)) if (n == name): macro {};
			case _: macro final $name = $e;
		}
	}

	/** The local saying whether field `i` is there. **/
	public static inline function presence(i:Int):String {
		return "__p" + i;
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
