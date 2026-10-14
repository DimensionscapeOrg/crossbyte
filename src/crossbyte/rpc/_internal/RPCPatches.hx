package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCKinds;
import crossbyte.rpc._internal.RPCStructs;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/**
	What a class that implements `RPCStruct` is given for replication, beside
	the reader and writer `RPCStructs` makes it: generated the first time a
	contract carries it as a patch, or `RPCCodecs.of` names it, into three
	classes of `crossbyte.rpc._internal.codec`:

	- `R<hash>`, statics: `make`, `copy`, `equals`, `mask` (a bit for each
	  field that differs, at the precision it is sent; `maskHigh` for fields
	  32 to 63), `writePatch`, `readPatch` (into a state), `apply` (a state
	  onto a base), `readInto` (a whole value read into one held), and the
	  arguments' forms of them.
	- `S<hash>`: a patch as read, before it is applied: its mask, the values
	  that arrived, and a state of its own for each nested structure.
	- `I<hash>`: the `RPCCodec<T>` generic code holds, forwarding to `R`.

	A patch on the wire:

	```
	bit section, the first bit the lowest of the first byte:
	  1 bit    on an RPCPatch argument or answer only: set when it is full
	  n bits   the mask: bit i for field i, in wire order
	  0-7 bits zeros, to a whole byte
	byte section, per field whose bit is set, in wire order:
	  a nested structure: its own patch, with no full bit, against the base's
	  anything else: the field as a whole value of its kind is written
	```

	A structure is a tree of a fixed depth, so this recursion ends; the
	generated classes of the structures a structure holds are made first.
**/
class RPCPatches {
	/** The most fields a patched structure can have: two masks. **/
	public static inline final MAX_FIELDS:Int = 64;

	static var made:Map<String, Replication> = new Map();

	/** The kind of `RPCPatch<T>`, `param` being `T`. **/
	public static function patchKind(param:Type, pos:Position):Null<RPCKind> {
		final info:StructInfo = classStruct(param, "RPCPatch", pos);
		final rep:Replication = replicationOf(info, pos);
		final r:Expr = rep.r;
		final patchType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCPatch", params: [TPType(info.type)]});
		return {
			name: "RPCPatch<" + info.name + ">",
			token: "~" + info.token,
			size: -1,
			roomOf: value -> macro 8,
			zero: macro null,
			compound: true,
			patch: true,
			valueType: patchType,
			write: (frame, value) -> macro $r.writePatchArg($frame, $value),
			read: (input, end) -> macro $r.readPatchArg($input, $end, $r.newPatch()),
			reuse: {
				type: patchType,
				make: macro $r.newPatch(),
				readInto: (input, end, held) -> macro $r.readPatchArg($input, $end, $held),
				poison: value -> macro $r.poisonPatch($value)
			}
		};
	}

	/** The kind of `RPCMapPatch<V>`, or of `RPCStringMapPatch<V>`, `param` being `V`. **/
	public static function mapPatchKind(param:Type, stringKeys:Bool, pos:Position):Null<RPCKind> {
		final what:String = stringKeys ? "RPCStringMapPatch" : "RPCMapPatch";
		final info:StructInfo = classStruct(param, what, pos);
		final rep:Replication = replicationOf(info, pos);
		final r:Expr = rep.r;
		final patchType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: what, params: [TPType(info.type)]});
		final write:String = stringKeys ? "writeStringMapPatchArg" : "writeMapPatchArg";
		final read:String = stringKeys ? "readStringMapPatchArg" : "readMapPatchArg";
		final make:String = stringKeys ? "newStringMapPatch" : "newMapPatch";
		return {
			name: what + "<" + info.name + ">",
			token: "~[" + (stringKeys ? "utf8" : "i32") + ":" + info.token + "]",
			size: -1,
			roomOf: value -> macro 8,
			zero: macro null,
			compound: true,
			patch: true,
			valueType: patchType,
			write: (frame, value) -> macro $r.$write($frame, $value),
			read: (input, end) -> macro $r.$read($input, $end, $r.$make()),
			reuse: {
				type: patchType,
				make: macro $r.$make(),
				readInto: (input, end, held) -> macro $r.$read($input, $end, $held),
				poison: value -> macro $value.__poison()
			}
		};
	}

	/**
		How an argument of `kind` is read into what a session keeps for it,
		valid during the call (`@:reuse`): a class's fields set in place, its
		nested structures and arrays read into those it holds; an array's
		length set to the count read, its element instances kept and read
		into; a map cleared and refilled. Of any other kind, `null`, or an
		error when the argument was marked itself (`explicit`): an anonymous
		structure is made each call, so it cannot be kept.
	**/
	public static function reuseOf(kind:RPCKind, where:String, explicit:Bool, pos:Position):Null<RPCReuse> {
		if (kind.struct != null) {
			if (!kind.struct.isClass) {
				if (explicit) {
					Context.error('RPC $where is marked @:reuse, and ${kind.name} is an anonymous structure, which is made each call: declare a class that implements RPCStruct.',
						pos);
				}
				return null;
			}
			final r:Expr = replicationOf(kind.struct, pos).r;
			return {
				type: kind.struct.type,
				make: macro $r.make(),
				readInto: (input, end, held) -> readInto(kind, false, input, end, held),
				poison: value -> macro $r.poison($value)
			};
		}
		if (kind.element != null) {
			final path:TypePath = switch (kind.valueType) {
				case TPath(p): p;
				case _: throw "a collection's type is a path";
			};
			return {
				type: kind.valueType,
				make: kind.mapKey != null ? macro new $path() : macro [],
				readInto: (input, end, held) -> readInto(kind, false, input, end, held),
				poison: value -> poisonField(kind, false, value)
			};
		}
		if (explicit) {
			Context.error('RPC $where is marked @:reuse, and a ${kind.name} has nothing to keep: @:reuse is for structures, arrays and maps.', pos);
		}
		return null;
	}

	/**
		Reads a value of `kind` into `held` (which may be `null`), and answers
		what to keep: the same instance where it can be.
	**/
	public static function readInto(kind:RPCKind, optional:Bool, input:Expr, end:Expr, held:Expr):Expr {
		if (optional) {
			final inner:Expr = readInto(kind, false, input, end, held);
			return macro($input.readByte() != 0 ? $inner : null);
		}
		if (kind.struct != null && kind.struct.isClass) {
			final r:Expr = replicationOf(kind.struct, kind.struct.pos).r;
			final h:String = RPCKinds.local();
			final t:ComplexType = kind.struct.type;
			return macro {
				var $h:$t = $held;
				if ($i{h} == null) {
					$i{h} = $r.make();
				}
				$r.readInto($input, $end, $i{h});
			};
		}
		if (kind.element != null && kind.mapKey == null && !kind.elementOptional && kind.element.struct != null && kind.element.struct.isClass
			&& kind.element.struct.bitsOnly) {
			// One run of bits, its elements read into those `held` has.
			return RPCBits.runRead(kind.element.struct, input, end, held);
		}
		if (kind.element != null) {
			final t:ComplexType = kind.valueType;
			final count:String = RPCKinds.local();
			final list:String = RPCKinds.local();
			final at:String = RPCKinds.local();
			final least:Int = !kind.elementOptional && kind.element.size > 0 ? kind.element.size : 1;
			if (kind.mapKey != null) {
				final path:TypePath = switch (t) {
					case TPath(p): p;
					case _: throw "a map's type is a path";
				};
				final keyLeast:Int = kind.mapKey == "utf8" ? 1 : 4;
				final getKey:Expr = kind.mapKey == "utf8" ? macro $input.readVarUtf() : macro crossbyte.rpc._internal.RPCWire.readI32($input);
				final getValue:Expr = RPCKinds.read(kind.element, kind.elementOptional, input, end);
				return macro {
					final $count:Int = $input.readVarUInt();
					crossbyte.rpc._internal.RPCWire.requireCount($input, $end, $i{count}, $v{least + keyLeast});
					var $list:$t = cast $held;
					if ($i{list} == null) {
						$i{list} = new $path();
					} else {
						$i{list}.clear();
					}
					for (_ in 0...$i{count}) {
						final __key = $getKey;
						$i{list}.set(__key, $getValue);
					}
					$i{list};
				};
			}
			final each:Expr = readInto(kind.element, kind.elementOptional, input, end, macro $i{list}[$i{at}]);
			final fresh:Expr = readInto(kind.element, kind.elementOptional, input, end, macro null);
			final kept:Bool = kind.element.struct != null && kind.element.struct.isClass;
			return macro {
				final $count:Int = $input.readVarUInt();
				crossbyte.rpc._internal.RPCWire.requireCount($input, $end, $i{count}, $v{least});
				var $list:$t = $held;
				if ($i{list} == null) {
					$i{list} = [];
				}
				if ($i{list}.length > $i{count}) {
					$i{list}.resize($i{count});
				}
				for ($i{at} in 0...$i{count}) {
					if ($i{at} < $i{list}.length) {
						$i{list}[$i{at}] = ${kept ? each : RPCKinds.read(kind.element, kind.elementOptional, input, end)};
					} else {
						$i{list}.push($fresh);
					}
				}
				$i{list};
			};
		}
		return RPCKinds.read(kind, optional, input, end);
	}

	/** A statement setting a field of `kind` in place to garbage, or `null` for a kind that has none (a `Bool`, an enum). **/
	public static function poisonField(kind:RPCKind, optional:Bool, value:Expr):Null<Expr> {
		if (kind.struct != null) {
			if (!kind.struct.isClass) {
				return null;
			}
			final r:Expr = replicationOf(kind.struct, kind.struct.pos).r;
			return macro $r.poison($value);
		}
		if (kind.element != null) {
			if (kind.mapKey != null) {
				return macro if ($value != null) $value.clear();
			}
			final at:String = RPCKinds.local();
			final each:Null<Expr> = poisonValue(kind.element, macro $value[$i{at}]);
			if (each == null) {
				return null;
			}
			return macro if ($value != null) for ($i{at} in 0...$value.length) $each;
		}
		final set:Null<Expr> = poisonValue(kind, value);
		return optional && set == null ? macro $value = null : set;
	}

	// A value set to garbage where it is: numbers to 0xDBDBDBDB or NaN,
	// strings to a marker.
	static function poisonValue(kind:RPCKind, value:Expr):Null<Expr> {
		if (kind.struct != null || kind.element != null) {
			return poisonField(kind, false, value);
		}
		if (kind.isEnum == true || kind.token == "bool") {
			return null;
		}
		final token:String = kind.bits != null ? (StringTools.startsWith(kind.token, "q") ? "f64" : "i32") : kind.token;
		return switch (token) {
			case "f64" | "f32": macro $value = cast Math.NaN;
			case "i32" | "i8" | "u8" | "i16" | "u16" | "vu" | "vi": macro $value = cast 0xDBDBDBDB;
			case "utf8": macro $value = cast "\u{FFFD}RPC value used after its call";
			case _: null;
		}
	}

	/** The codec `RPCCodecs.of` answers for a class, as an expression. **/
	public static function codecOf(type:Type, pos:Position):Expr {
		final info:StructInfo = classStruct(type, "RPCCodecs.of", pos);
		final rep:Replication = replicationOf(info, pos);
		final i:Expr = rep.i;
		final codecType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCCodec", params: [TPType(info.type)]});
		return macro($i.instance : $codecType);
	}

	/** The shape of `type`, a class that implements `RPCStruct`, or an error naming `what`. **/
	public static function classStruct(type:Type, what:String, pos:Position):StructInfo {
		final kind:Null<RPCKind> = RPCKinds.ofType(type, pos);
		final info:Null<StructInfo> = kind == null ? null : kind.struct;
		if (info == null || !info.isClass) {
			Context.error('$what takes a class that implements crossbyte.rpc.RPCStruct, and ' + TypeTools.toString(type) + ' is not one.'
				+ (info != null ? ' An anonymous structure has no codec: it cannot be made, copied in place or patched. Declare a class.' : ''), pos);
		}
		if (info.fields.length > MAX_FIELDS) {
			Context.error('$what: ${info.name} has ${info.fields.length} fields, and a patch carries at most $MAX_FIELDS. Group some of them into a structure of their own, which is patched as one field.',
				pos);
		}
		return info;
	}

	/** The generated classes of a structure's replication, made the first time they are asked for. **/
	public static function replicationOf(info:StructInfo, pos:Position):Replication {
		final known:Null<Replication> = made.get(info.key);
		if (known != null) {
			return known;
		}
		// What it holds first: its classes are named in this one's.
		for (field in info.fields) {
			prepare(field.kind, pos);
		}
		final rName:String = RPCStructs.codecName(info.key, "R");
		final iName:String = RPCStructs.codecName(info.key, "I");
		final sName:String = RPCStructs.codecName(info.key, "S");
		final pack:Array<String> = ["crossbyte", "rpc", "_internal", "codec"];
		final rep:Replication = {
			r: macro $p{pack.concat([rName])},
			i: macro $p{pack.concat([iName])},
			sType: TPath({pack: pack, name: sName}),
			sPath: {pack: pack, name: sName}
		};
		made.set(info.key, rep);
		final rPath:String = pack.concat([rName]).join(".");
		if (!RPCStructs.exists(rPath)) {
			Context.defineType(stateClass(info, pack, sName, pos), info.module);
			Context.defineType(staticsClass(info, rep, pack, rName, pos), info.module);
			Context.defineType(codecClass(info, rep, pack, iName, pos), info.module);
		}
		return rep;
	}

	/** Makes the replication of every class a kind holds, for code that names it. **/
	static function prepare(kind:RPCKind, pos:Position):Void {
		if (kind.struct != null) {
			if (kind.struct.isClass) {
				replicationOf(kind.struct, pos);
			} else {
				for (field in kind.struct.fields) {
					prepare(field.kind, pos);
				}
			}
		}
		if (kind.element != null) {
			prepare(kind.element, pos);
		}
	}

	/** Whether a field is patched field by field: a nested class that cannot be absent. **/
	static inline function nested(field:StructField):Bool {
		return !field.optional && field.kind.struct != null && field.kind.struct.isClass;
	}

	/** Whether a field's value is shared, not copied: one nothing can change in place. **/
	static function immutable(kind:RPCKind):Bool {
		return kind.struct == null && kind.element == null && kind.token != "bytes";
	}

	// ------------------------------------------------------------ the state

	static function stateClass(info:StructInfo, pack:Array<String>, name:String, pos:Position):TypeDefinition {
		final type:ComplexType = info.type;
		final ctor:TypePath = ctorOf(info);
		final fields:Array<Field> = [
			{name: "mask", access: [APublic], kind: FVar(macro :Int, macro 0), pos: pos},
			{name: "maskHigh", access: [APublic], kind: FVar(macro :Int, macro 0), pos: pos},
			{name: "full", access: [APublic], kind: FVar(macro :Bool, macro false), pos: pos},
			{name: "values", access: [APublic], kind: FVar(type, null), pos: pos}
		];
		final init:Array<Expr> = [macro values = new $ctor()];
		for (field in info.fields) {
			if (nested(field)) {
				final child:Replication = replicationOf(field.kind.struct, pos);
				final childType:ComplexType = child.sType;
				final childPath:TypePath = child.sPath;
				final name:String = "c_" + field.name;
				fields.push({name: name, access: [APublic], kind: FVar(childType, null), pos: pos});
				init.push(macro $i{name} = new $childPath());
			}
		}
		fields.push({
			name: "new",
			access: [APublic],
			kind: FFun({args: [], ret: null, expr: macro $b{init}}),
			pos: pos
		});
		return {
			pack: pack,
			name: name,
			pos: pos,
			meta: [{name: ":noCompletion", params: [], pos: pos}],
			kind: TDClass(),
			fields: fields
		};
	}

	// ------------------------------------------------------------ the statics

	static function staticsClass(info:StructInfo, rep:Replication, pack:Array<String>, name:String, pos:Position):TypeDefinition {
		final type:ComplexType = info.type;
		final ctor:TypePath = ctorOf(info);
		final sType:ComplexType = rep.sType;
		final sPath:TypePath = rep.sPath;
		final n:Int = info.fields.length;
		final nameExpr:Expr = macro $v{info.name};
		final patchType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCPatch", params: [TPType(type)]});
		final patchName:Expr = macro $v{"RPCPatch<" + info.name + ">"};
		final patchPath:TypePath = {pack: ["crossbyte", "rpc"], name: "RPCPatch", params: [TPType(type)]};

		// mask and maskHigh: a bit for each field that differs.
		final low:Array<Expr> = [];
		final high:Array<Expr> = [];
		for (i in 0...n) {
			final field = info.fields[i];
			final fname:String = field.name;
			final differs:Expr = macro !${same(field.kind, field.optional, macro base.$fname, macro current.$fname)};
			if (i < 32) {
				low.push(macro if ($differs) m |= $v{1 << i});
			} else {
				high.push(macro if ($differs) m |= $v{1 << (i - 32)});
			}
		}

		// copy: every field onto `into`.
		final copies:Array<Expr> = [];
		for (field in info.fields) {
			final fname:String = field.name;
			copies.push(macro into.$fname = ${copy(field.kind, field.optional, macro from.$fname, macro into.$fname)});
		}

		// writePatch and readPatch: the bit section, then the byte section.
		final writeBits:Array<Expr> = [(macro var __acc:Int = 0), (macro var __fill:Int = 0), macro if (flag >= 0) {
			__acc = flag;
			__fill = 1;
		}];
		for (chunk in maskChunks(n)) {
			final source:Expr = chunk.high ? macro maskHigh : macro mask;
			final value:Expr = macro($source >>> $v{chunk.shift}) & $v{(1 << chunk.bits) - 1};
			for (e in putBits(value, chunk.bits)) {
				writeBits.push(e);
			}
		}
		// After the mask, per field that changed: in the bit layout its
		// presence bit if it may be absent, and its bits if a bit kind.
		final bitLayout:Bool = info.bitLayout;
		for (i in 0...n) {
			final field = info.fields[i];
			final bits = field.kind.bits;
			final fname:String = field.name;
			final p:String = RPCBits.presence(i);
			final each:Array<Expr> = [];
			if (bitLayout && field.optional) {
				writeBits.push(macro var $p:Bool = false);
				each.push(macro $i{p} = current.$fname != null);
				for (e in putBits(macro $i{p} ? 1 : 0, 1)) {
					each.push(e);
				}
			}
			if (bits != null) {
				final put:Array<Expr> = putBits(bits.put(macro current.$fname), bits.width);
				each.push(field.optional ? macro if ($i{p}) $b{put} : macro $b{put});
			}
			if (each.length > 0) {
				writeBits.push(macro if (${bitTest(i)}) $b{each});
			}
		}
		writeBits.push(macro if (__fill > 0) frame.putByte(__acc & 0xFF));
		final writeBytes:Array<Expr> = [];
		final readBits:Array<Expr> = [(macro var __acc:Int = 0), (macro var __have:Int = 0), (macro var __full:Bool = false)];
		readBits.push(macro if (flagged) __full = ${takeBits(1)} != 0);
		readBits.push(macro var __mask:Int = 0);
		readBits.push(macro var __maskHigh:Int = 0);
		for (chunk in maskChunks(n)) {
			final target:String = chunk.high ? "__maskHigh" : "__mask";
			readBits.push(macro $i{target} |= ${takeBits(chunk.bits)} << $v{chunk.shift});
		}
		final readBytes:Array<Expr> = [];
		final readBitFields:Array<Expr> = [];
		final applies:Array<Expr> = [];
		for (i in 0...n) {
			final field = info.fields[i];
			final fname:String = field.name;
			final set:Expr = bitTest(i);
			if (nested(field)) {
				final child:Replication = replicationOf(field.kind.struct, pos);
				final cr:Expr = child.r;
				final childState:String = "c_" + fname;
				final fieldName:Expr = macro $v{field.kind.name};
				writeBytes.push(macro if ($set) {
					var __b = base.$fname;
					if (__b == null) {
						__b = $cr.defaultValue();
					}
					final __c = current.$fname;
					if (__c == null) {
						throw crossbyte.rpc._internal.RPCFrame.nullValue($fieldName);
					}
					$cr.writePatch(frame, __b, __c, $cr.mask(__b, __c), $cr.maskHigh(__b, __c), -1);
				});
				readBytes.push(macro if ($set) $cr.readPatch(input, end, state.$childState, false));
				applies.push(macro {
					var __t = into.$fname;
					if (__t == null) {
						__t = $cr.make();
					}
					if ($set) {
						into.$fname = $cr.apply(state.$childState, from.$fname, __t);
					} else if (other) {
						final __f = from.$fname;
						into.$fname = __f == null ? $cr.copy($cr.defaultValue(), __t) : $cr.copy(__f, __t);
					}
				});
			} else if (field.kind.bits != null) {
				final bits = field.kind.bits;
				final p:String = RPCBits.presence(i);
				final get:Expr = bits.get(takeBits(bits.width));
				if (field.optional) {
					readBitFields.push(macro var $p:Bool = false);
					readBitFields.push(macro if ($set) {
						$i{p} = ${takeBits(1)} != 0;
						state.values.$fname = $i{p} ? $get : null;
					});
				} else {
					readBitFields.push(macro if ($set) state.values.$fname = $get);
				}
				applies.push(macro if ($set) into.$fname = state.values.$fname else if (other) into.$fname = from.$fname);
			} else if (bitLayout && field.optional) {
				// Its presence in the bit section, the value in the byte section.
				final p:String = RPCBits.presence(i);
				readBitFields.push(macro var $p:Bool = false);
				readBitFields.push(macro if ($set) $i{p} = ${takeBits(1)} != 0);
				writeBytes.push(macro if ($set && $i{p}) ${RPCKinds.write(field.kind, false, macro frame, macro current.$fname)});
				readBytes.push(macro if ($set) state.values.$fname = $i{p} ? ${RPCKinds.read(field.kind, false, macro input, macro end)} : null);
				if (immutable(field.kind)) {
					applies.push(macro if ($set) into.$fname = state.values.$fname else if (other) into.$fname = from.$fname);
				} else {
					applies.push(macro if ($set) into.$fname = ${copy(field.kind, field.optional, macro state.values.$fname, macro into.$fname)} else if (other)
						into.$fname = ${copy(field.kind, field.optional, macro from.$fname, macro into.$fname)});
				}
			} else {
				writeBytes.push(macro if ($set) ${RPCKinds.write(field.kind, field.optional, macro frame, macro current.$fname)});
				readBytes.push(macro if ($set) state.values.$fname = ${RPCKinds.read(field.kind, field.optional, macro input, macro end)});
				if (immutable(field.kind)) {
					applies.push(macro if ($set) into.$fname = state.values.$fname else if (other) into.$fname = from.$fname);
				} else {
					applies.push(macro if ($set) into.$fname = ${copy(field.kind, field.optional, macro state.values.$fname, macro into.$fname)} else if (other)
						into.$fname = ${copy(field.kind, field.optional, macro from.$fname, macro into.$fname)});
				}
			}
		}

		// readInto: a whole value, as the codec reads one, into `into`.
		final readsInto:Array<Expr> = [];
		if (bitLayout) {
			final assign = (field:StructField, i:Int, value:Expr) -> {
				final fname:String = field.name;
				return macro into.$fname = $value;
			};
			final kept = (field:StructField) -> {
				final fname:String = field.name;
				return readInto(field.kind, false, macro input, macro end, macro into.$fname);
			};
			for (e in RPCBits.readValue(info.fields, macro input, macro end, assign, kept)) {
				readsInto.push(e);
			}
		}
		for (field in info.fields) {
			final fname:String = field.name;
			if (bitLayout) {
				break;
			}
			if (nested(field)) {
				final cr:Expr = replicationOf(field.kind.struct, pos).r;
				readsInto.push(macro {
					var __t = into.$fname;
					if (__t == null) {
						__t = $cr.make();
					}
					into.$fname = $cr.readInto(input, end, __t);
				});
			} else {
				readsInto.push(macro into.$fname = ${readInto(field.kind, field.optional, macro input, macro end, macro into.$fname)});
			}
		}

		// poison: every field set to what reads as garbage, for
		// -D crossbyte_check_events.
		final poisons:Array<Expr> = [];
		for (field in info.fields) {
			final fname:String = field.name;
			final each:Null<Expr> = poisonField(field.kind, field.optional, macro value.$fname);
			if (each != null) {
				poisons.push(each);
			}
		}
		final statePoisons:Array<Expr> = [macro poison(state.values)];
		for (field in info.fields) {
			if (nested(field)) {
				final cr:Expr = replicationOf(field.kind.struct, pos).r;
				final childState:String = "c_" + field.name;
				statePoisons.push(macro $cr.poisonState(state.$childState));
			}
		}

		// The most a patch takes: its mask and full bit, and every field.
		final bound:Int = info.size < 0 ? -1 : ((n + 1 + 7) >> 3) + info.size + nestedMasks(info, pos);

		final meta:Metadata = [{name: ":noCompletion", params: [], pos: pos}];
		for (path in info.access) {
			meta.push({name: ":access", params: [Context.parse(path, pos)], pos: pos});
		}
		final fields:Array<Field> = [
			{
				name: "__default",
				access: [APrivate, AStatic],
				kind: FVar(TPath({pack: [], name: "Null", params: [TPType(type)]}), macro null),
				pos: pos
			},
			fn("defaultValue", [], type, macro {
				var made = __default;
				if (made == null) {
					made = __default = new $ctor();
				}
				return made;
			}, pos, "The structure as its constructor makes it, made once: the base of a full patch. Never changed."),
			fn("make", [], type, macro return new $ctor(), pos),
			fn("copy", [arg("from", type), arg("into", type)], type, macro {
				if (from == null || into == null) {
					throw new crossbyte.errors.ArgumentError("RPC codec copy: " + $nameExpr + " to copy from and into");
				}
				$b{copies};
				return into;
			}, pos),
			fn("mask", [arg("base", type), arg("current", type)], macro :Int, macro {
				if (base == current) {
					return 0;
				}
				var m:Int = 0;
				$b{low};
				return m;
			}, pos),
			fn("maskHigh", [arg("base", type), arg("current", type)], macro :Int, high.length == 0 ? macro return 0 : macro {
				if (base == current) {
					return 0;
				}
				var m:Int = 0;
				$b{high};
				return m;
			}, pos),
			fn("equals", [arg("a", type), arg("b", type)], macro :Bool,
				macro return a == b || (a != null && b != null && mask(a, b) == 0 && maskHigh(a, b) == 0), pos),
			fn("writePatch", [
				arg("frame", macro :crossbyte.rpc._internal.RPCFrame),
				arg("base", type),
				arg("current", type),
				arg("mask", macro :Int),
				arg("maskHigh", macro :Int),
				arg("flag", macro :Int)
			], macro :Void, macro $b{[
				macro if (current == null) {
					throw crossbyte.rpc._internal.RPCFrame.nullValue($nameExpr);
				}
			].concat(writeBits).concat(writeBytes)}, pos, "Writes the patch from `base` to `current` whose fields `mask` names; `flag` is the full bit (0 or 1) of an argument's patch, or -1 for none."),
			fn("readPatch", [
				arg("input", macro :crossbyte.io.ByteArrayInput),
				arg("end", macro :Int),
				arg("state", sType),
				arg("flagged", macro :Bool)
			], macro :Void, macro $b{readBits.concat([
				macro state.mask = __mask,
				macro state.maskHigh = __maskHigh,
				macro state.full = __full,
				(macro final mask:Int = __mask),
				(macro final maskHigh:Int = __maskHigh)
			]).concat(readBitFields).concat(readBytes)}, pos),
			fn("apply", [arg("state", sType), arg("base", TPath({pack: [], name: "Null", params: [TPType(type)]})), arg("into", type)], type, macro {
				final from:$type = state.full || base == null ? defaultValue() : base;
				final mask:Int = state.mask;
				final maskHigh:Int = state.maskHigh;
				final other:Bool = into != from;
				$b{applies};
				return into;
			}, pos),
			fn("readInto", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("into", type)], type,
				macro $b{readsInto.concat([macro return into])}, pos),
			fn("poison", [arg("value", type)], macro :Void, macro if (value != null) $b{poisons}, pos,
				"Sets what `value` holds to garbage: a value used after its call is seen at once (-D crossbyte_check_events)."),
			fn("poisonState", [arg("state", sType)], macro :Void, macro $b{statePoisons}, pos),
			fn("poisonPatch", [arg("patch", patchType)], macro :Void, macro {
				final state:$sType = cast patch.__state;
				if (state != null) {
					poisonState(state);
				}
			}, pos),
			fn("newPatch", [], patchType, macro {
				final patch = new $patchPath(${rep.i}.instance);
				patch.__state = new $sPath();
				return patch;
			}, pos),
			fn("writePatchArg", [arg("frame", macro :crossbyte.rpc._internal.RPCFrame), arg("patch", patchType)], macro :Void, macro {
				if (patch == null) {
					throw crossbyte.rpc._internal.RPCFrame.nullValue($patchName);
				}
				final current = patch.__current;
				if (current == null) {
					throw new crossbyte.errors.ArgumentError(patch.__received ? "A patch that arrived cannot be sent on: apply it, and diff the value." : "Diff the patch before sending it: patch.diff(base, current).");
				}
				final base = patch.__base;
				writePatch(frame, base == null ? defaultValue() : base, current, patch.__mask, patch.__maskHigh, base == null ? 1 : 0);
			}, pos),
			fn("readPatchArg", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("patch", patchType)], patchType, macro {
				var state:$sType = cast patch.__state;
				if (state == null) {
					state = new $sPath();
					patch.__state = state;
				}
				readPatch(input, end, state, true);
				patch.__receive(state.mask, state.maskHigh, state.full);
				return patch;
			}, pos),
			{
				name: "PATCH_BOUND",
				access: [APublic, AStatic, AInline],
				kind: FVar(macro :Int, macro $v{bound}),
				pos: pos
			}
		];
		for (field in mapPatchFields(info, rep, false, pos)) {
			fields.push(field);
		}
		for (field in mapPatchFields(info, rep, true, pos)) {
			fields.push(field);
		}
		return {
			pack: pack,
			name: name,
			pos: pos,
			meta: meta,
			kind: TDClass(),
			fields: fields
		};
	}

	/**
		A map patch's writer, reader and maker, for values of this structure,
		`Int` keys or `String` ones:

		```
		varuint  head      the removed count twice, plus 1 when full
		varuint  added     count
		varuint  updated   count
		removed  keys, ascending
		added    per entry, ascending: its key, then its value's patch from the default
		updated  per entry, ascending: its key, then its value's patch from the base's
		```

		An `Int` key is key-coded (`RPCKeys`); a `String` key is written whole.
		The counts are checked against what is left of the frame before any
		pool grows, at the least an entry takes (a byte of key and one of
		mask); a full patch that removes or updates is unreadable.
	**/
	static function mapPatchFields(info:StructInfo, rep:Replication, stringKeys:Bool, pos:Position):Array<Field> {
		final type:ComplexType = info.type;
		final sType:ComplexType = rep.sType;
		final what:String = stringKeys ? "RPCStringMapPatch" : "RPCMapPatch";
		final patchType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: what, params: [TPType(type)]});
		final patchPath:TypePath = {pack: ["crossbyte", "rpc"], name: what, params: [TPType(type)]};
		final patchName:Expr = macro $v{what + "<" + info.name + ">"};
		final wide:Bool = info.fields.length > 32;
		final addedHigh:Expr = wide ? macro crossbyte.rpc._internal.RPCKeys.at(patch.__addedMasksHigh, i) : macro 0;
		final updatedHigh:Expr = wide ? macro crossbyte.rpc._internal.RPCKeys.at(patch.__updatedMasksHigh, i) : macro 0;
		final keyType:ComplexType = stringKeys ? macro :String : macro :Int;
		final putRemoved:Expr = stringKeys ? macro crossbyte.rpc._internal.RPCKeys.putStringKeys(frame,
			patch.removed) : macro crossbyte.rpc._internal.RPCKeys.putKeys(frame, patch.removed);
		final putKey:Expr = stringKeys ? macro frame.putString(key) : macro {
			crossbyte.rpc._internal.RPCKeys.putKey(frame, i == 0, previous, key);
			previous = key;
		};
		final keyAt = (list:Expr) -> stringKeys ? macro $list[i] : macro crossbyte.rpc._internal.RPCKeys.at($list, i);
		final addedKey:Expr = keyAt(macro added);
		final updatedKey:Expr = keyAt(macro updated);
		final getRemoved:Expr = stringKeys ? macro crossbyte.rpc._internal.RPCKeys.getStringKeys(input, removedCount,
			patch.removed) : macro crossbyte.rpc._internal.RPCKeys.getKeys(input, removedCount, patch.removed);
		final previousType:ComplexType = stringKeys ? macro :Null<String> : macro :Int;
		final previousZero:Expr = stringKeys ? macro null : macro 0;
		final getKey:Expr = stringKeys ? macro crossbyte.rpc._internal.RPCKeys.nextStringKey(input,
			previous) : macro crossbyte.rpc._internal.RPCKeys.getKey(input, i == 0, previous);
		final suffix:String = stringKeys ? "StringMapPatch" : "MapPatch";
		return [
			fn("write" + suffix + "Arg", [arg("frame", macro :crossbyte.rpc._internal.RPCFrame), arg("patch", patchType)], macro :Void, macro {
				if (patch == null) {
					throw crossbyte.rpc._internal.RPCFrame.nullValue($patchName);
				}
				if (!patch.__sending) {
					throw new crossbyte.errors.ArgumentError(patch.__received ? "A map patch that arrived cannot be sent on: apply it, and diff the maps." : "Diff the map patch before sending it: patch.diff(base, current).");
				}
				final added = patch.__added;
				final updated = patch.__updated;
				frame.putVarUInt((patch.removed.length << 1) | (patch.isFull ? 1 : 0));
				frame.putVarUInt(added.length);
				frame.putVarUInt(updated.length);
				$putRemoved;
				final initial:$type = defaultValue();
				var previous:Int = 0;
				for (i in 0...added.length) {
					final key:$keyType = $addedKey;
					$putKey;
					writePatch(frame, initial, patch.__sentAdded[i], crossbyte.rpc._internal.RPCKeys.at(patch.__addedMasks, i), $addedHigh, -1);
				}
				previous = 0;
				for (i in 0...updated.length) {
					final key:$keyType = $updatedKey;
					$putKey;
					writePatch(frame, patch.__sentBase[i], patch.__sentCurrent[i], crossbyte.rpc._internal.RPCKeys.at(patch.__updatedMasks, i), $updatedHigh, -1);
				}
			}, pos),
			fn("read" + suffix + "Arg", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("patch", patchType)], patchType, macro {
				final head:Int = input.readVarUInt();
				final added:Int = input.readVarUInt();
				final updated:Int = input.readVarUInt();
				final removedCount:Int = head >>> 1;
				final full:Bool = (head & 1) != 0;
				if (added < 0 || updated < 0 || (full && (removedCount != 0 || updated != 0))) {
					throw "RPC map patch counts do not read";
				}
				final limit:Int = end < input.length ? end : input.length;
				// At the least a byte a removed key, and two an entry: its key and its mask.
				if ((removedCount : Float) + 2.0 * added + 2.0 * updated > limit - input.position) {
					throw "RPC frame names more than it holds";
				}
				patch.__beginRead(full, added, updated);
				$getRemoved;
				final state:$sType = cast patch.__addedState;
				var previous:$previousType = $previousZero;
				for (i in 0...added) {
					previous = $getKey;
					patch.__added.push(previous);
					readPatch(input, end, state, false);
					apply(state, null, patch.__addedValues[i]);
				}
				previous = $previousZero;
				for (i in 0...updated) {
					previous = $getKey;
					patch.__updated.push(previous);
					readPatch(input, end, cast patch.__updatedStates[i], false);
				}
				return patch;
			}, pos),
			fn("new" + suffix, [], patchType, macro return new $patchPath(${rep.i}.instance), pos)
		];
	}

	/** The bytes the masks of nested structures add to a patch, at most. **/
	static function nestedMasks(info:StructInfo, pos:Position):Int {
		var extra:Int = 0;
		for (field in info.fields) {
			if (nested(field)) {
				final child:StructInfo = field.kind.struct;
				extra += ((child.fields.length + 7) >> 3) + nestedMasks(child, pos);
			}
		}
		return extra;
	}

	// ------------------------------------------------------------ the codec

	static function codecClass(info:StructInfo, rep:Replication, pack:Array<String>, name:String, pos:Position):TypeDefinition {
		final type:ComplexType = info.type;
		final r:Expr = rep.r;
		final c:Expr = macro $p{pack.concat([info.codec])};
		final sType:ComplexType = rep.sType;
		final sPath:TypePath = rep.sPath;
		final patchPath:TypePath = {pack: ["crossbyte", "rpc"], name: "RPCPatch", params: [TPType(type)]};
		final self:ComplexType = TPath({pack: pack, name: name});
		final selfPath:TypePath = {pack: pack, name: name};
		final patchType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCPatch", params: [TPType(type)]});
		final nullType:ComplexType = TPath({pack: [], name: "Null", params: [TPType(type)]});
		final mapType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCMapPatch", params: [TPType(type)]});
		final stringMapType:ComplexType = TPath({pack: ["crossbyte", "rpc"], name: "RPCStringMapPatch", params: [TPType(type)]});
		final layout:Int = crossbyte.utils.Hash.fnv1a32(haxe.io.Bytes.ofString(info.token));
		final fields:Array<Field> = [
			{
				name: "instance",
				access: [APublic, AStatic, AFinal],
				kind: FVar(self, macro new $selfPath()),
				pos: pos
			},
			{name: "new", access: [APrivate], kind: FFun({args: [], ret: null, expr: macro {}}), pos: pos},
			method("make", [], type, macro return $r.make(), pos),
			method("copy", [arg("from", type), arg("into", type)], type, macro return $r.copy(from, into), pos),
			method("equals", [arg("a", type), arg("b", type)], macro :Bool, macro return $r.equals(a, b), pos),
			method("write", [arg("value", type), arg("out", macro :crossbyte.io.ByteArray)], macro :Void, macro {
				final frame = new crossbyte.rpc._internal.RPCFrame(64);
				frame.beginScratch();
				$c.write(frame, value);
				out.writeBytes(frame, 0, frame.position);
			}, pos),
			method("read", [arg("input", macro :crossbyte.io.ByteArray), optArg("into", nullType)], type, macro {
				final from:crossbyte.io.ByteArrayInput = input;
				final value:$type = into == null ? $c.read(from, input.length) : $r.readInto(from, input.length, into);
				crossbyte.rpc._internal.RPCWire.requireWithin(from, input.length);
				return value;
			}, pos),
			method("writePatch", [arg("base", nullType), arg("current", type), arg("out", macro :crossbyte.io.ByteArray)], macro :Void, macro {
				final patch = new $patchPath(this);
				patch.diff(base, current).write(out);
			}, pos),
			method("readPatch", [arg("input", macro :crossbyte.io.ByteArray), arg("base", nullType), arg("into", type)], type, macro {
				final patch = $r.newPatch();
				return patch.read(input).apply(base, into);
			}, pos),
			method("__default", [], type, macro return $r.defaultValue(), pos),
			method("__mask", [arg("base", type), arg("current", type)], macro :Int, macro return $r.mask(base, current), pos),
			method("__maskHigh", [arg("base", type), arg("current", type)], macro :Int, macro return $r.maskHigh(base, current), pos),
			method("__patchBound", [], macro :Int, macro return $r.PATCH_BOUND, pos),
			method("__newState", [], macro :Any, macro return new $sPath(), pos),
			method("__apply", [arg("state", macro :Any), arg("base", nullType), arg("into", type)], type, macro {
				final held:$sType = cast state;
				return $r.apply(held, base, into);
			}, pos),
			method("__writePatch", [arg("frame", macro :crossbyte.rpc._internal.RPCFrame), arg("patch", patchType)], macro :Void,
				macro $r.writePatchArg(frame, patch), pos),
			method("__readPatch", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("patch", patchType)], macro :Void, macro {
				$r.readPatchArg(input, end, patch);
			}, pos),
			method("__writeMapPatch", [arg("frame", macro :crossbyte.rpc._internal.RPCFrame), arg("patch", mapType)], macro :Void,
				macro $r.writeMapPatchArg(frame, patch), pos),
			method("__readMapPatch", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("patch", mapType)], macro :Void, macro {
				$r.readMapPatchArg(input, end, patch);
			}, pos),
			method("__writeStringMapPatch", [arg("frame", macro :crossbyte.rpc._internal.RPCFrame), arg("patch", stringMapType)], macro :Void,
				macro $r.writeStringMapPatchArg(frame, patch), pos),
			method("__readStringMapPatch", [arg("input", macro :crossbyte.io.ByteArrayInput), arg("end", macro :Int), arg("patch", stringMapType)], macro :Void, macro {
				$r.readStringMapPatchArg(input, end, patch);
			}, pos)
		];
		for (each in [
			{name: "name", type: macro :String, value: macro $v{info.name}},
			{name: "layout", type: macro :Int, value: macro $v{layout}},
			{name: "fieldCount", type: macro :Int, value: macro $v{info.fields.length}},
			{name: "maxSize", type: macro :Int, value: macro $v{info.size}}
		]) {
			for (field in prop(each.name, each.type, each.value, pos)) {
				fields.push(field);
			}
		}
		return {
			pack: pack,
			name: name,
			pos: pos,
			meta: [{name: ":noCompletion", params: [], pos: pos}],
			kind: TDClass(null, [{pack: ["crossbyte", "rpc"], name: "RPCCodec", params: [TPType(type)]}], false, true),
			fields: fields
		};
	}

	// ------------------------------------------------------------ equality and copies

	/**
		Whether `a` and `b`, values of `kind`, would go as the same bytes. It
		may say they differ when they would not (an enum holding a structure
		compared by reference), which sends a field that did not change, but
		never that two values are the same when they are not.
	**/
	public static function same(kind:RPCKind, optional:Bool, a:Expr, b:Expr):Expr {
		if (optional) {
			final inner:Expr = sameValue(kind, a, b, true);
			return macro($a == null ? $b == null : ($b != null && $inner));
		}
		return sameValue(kind, a, b, false);
	}

	// Of an optional value, known not to be null: numbers compared as what
	// they are, never as boxes.
	static function sameValue(kind:RPCKind, rawA:Expr, rawB:Expr, optional:Bool):Expr {
		if (kind.same != null) {
			return kind.same(rawA, rawB);
		}
		if (kind.struct != null) {
			if (kind.struct.isClass) {
				final r:Expr = replicationOf(kind.struct, kind.struct.pos).r;
				final t:ComplexType = kind.struct.type;
				return macro $r.equals((cast $rawA : $t), (cast $rawB : $t));
			}
			// An anonymous structure: field by field.
			final t:ComplexType = kind.struct.type;
			final x:String = RPCKinds.local();
			final y:String = RPCKinds.local();
			var all:Expr = macro true;
			for (field in kind.struct.fields) {
				final fname:String = field.name;
				final each:Expr = same(field.kind, field.optional, macro $i{x}.$fname, macro $i{y}.$fname);
				all = macro $all && $each;
			}
			return macro {
				final $x:$t = cast $rawA;
				final $y:$t = cast $rawB;
				$i{x} == $i{y} || ($i{x} != null && $i{y} != null && $all);
			};
		}
		if (kind.element != null) {
			final t:ComplexType = kind.valueType;
			final x:String = RPCKinds.local();
			final y:String = RPCKinds.local();
			final r:String = RPCKinds.local();
			if (kind.mapKey != null) {
				final k:String = RPCKinds.local();
				final count:String = RPCKinds.local();
				final each:Expr = same(kind.element, kind.elementOptional, macro $i{x}.get($i{k}), macro $i{y}.get($i{k}));
				return macro {
					final $x:$t = cast $rawA;
					final $y:$t = cast $rawB;
					var $r:Bool = $i{x} == $i{y};
					if (!$i{r} && $i{x} != null && $i{y} != null) {
						$i{r} = true;
						var $count:Int = 0;
						for ($i{k} in $i{x}.keys()) {
							$i{count}++;
							if (!$i{y}.exists($i{k}) || !$each) {
								$i{r} = false;
								break;
							}
						}
						if ($i{r}) {
							for (_ in $i{y}.keys()) {
								$i{count}--;
							}
							$i{r} = $i{count} == 0;
						}
					}
					$i{r};
				};
			}
			final at:String = RPCKinds.local();
			final each:Expr = same(kind.element, kind.elementOptional, macro $i{x}[$i{at}], macro $i{y}[$i{at}]);
			return macro {
				final $x:$t = cast $rawA;
				final $y:$t = cast $rawB;
				var $r:Bool = $i{x} == $i{y};
				if (!$i{r} && $i{x} != null && $i{y} != null && $i{x}.length == $i{y}.length) {
					$i{r} = true;
					for ($i{at} in 0...$i{x}.length) {
						if (!$each) {
							$i{r} = false;
							break;
						}
					}
				}
				$i{r};
			};
		}
		if (kind.isEnum == true) {
			return macro crossbyte.rpc._internal.RPCSame.enums($rawA, $rawB);
		}
		return switch (kind.token) {
			case "f64":
				macro crossbyte.rpc._internal.RPCSame.floats((cast $rawA : Float), (cast $rawB : Float));
			case "f32":
				macro crossbyte.rpc._internal.RPCSame.singles((cast $rawA : Float), (cast $rawB : Float));
			case "bytes":
				macro crossbyte.rpc._internal.RPCSame.bytes($rawA, $rawB);
			case "i32" | "i8" | "u8" | "i16" | "u16" | "vu" | "vi" if (optional):
				macro(cast $rawA : Int) == (cast $rawB : Int);
			case "bool" if (optional):
				macro(cast $rawA : Bool) == (cast $rawB : Bool);
			case "i64" if (optional):
				macro(cast $rawA : haxe.Int64) == (cast $rawB : haxe.Int64);
			case _:
				macro $rawA == $rawB;
		}
	}

	/**
		A copy of `from`, a value of `kind`, to set where `into` was: a nested
		structure copied into the one `into` holds, an array into its array,
		so the result shares nothing that can change with `from`. Numbers,
		strings and enums are themselves.
	**/
	public static function copy(kind:RPCKind, optional:Bool, from:Expr, into:Expr):Expr {
		if (kind.struct != null) {
			final t:ComplexType = kind.struct.type;
			if (kind.struct.isClass) {
				final r:Expr = replicationOf(kind.struct, kind.struct.pos).r;
				final s:String = RPCKinds.local();
				final d:String = RPCKinds.local();
				return macro {
					final $s:$t = $from;
					var $d:$t = $into;
					if ($i{s} == null) {
						$i{d} = null;
					} else {
						if ($i{d} == null) {
							$i{d} = $r.make();
						}
						$i{d} = $r.copy($i{s}, $i{d});
					}
					$i{d};
				};
			}
			// An anonymous structure: made again, field by field.
			final s:String = RPCKinds.local();
			final made:Array<ObjectField> = [];
			for (field in kind.struct.fields) {
				final fname:String = field.name;
				made.push({field: fname, expr: copy(field.kind, field.optional, macro $i{s}.$fname, macro null)});
			}
			final literal:Expr = {expr: EObjectDecl(made), pos: kind.struct.pos};
			return macro {
				final $s:$t = $from;
				$i{s} == null ? null : $literal;
			};
		}
		if (kind.element != null) {
			final t:ComplexType = kind.valueType;
			final s:String = RPCKinds.local();
			final d:String = RPCKinds.local();
			if (kind.mapKey != null) {
				final path:TypePath = switch (t) {
					case TPath(p): p;
					case _: throw "a map's type is a path";
				};
				final k:String = RPCKinds.local();
				final each:Expr = copy(kind.element, kind.elementOptional, macro $i{s}.get($i{k}), macro null);
				return macro {
					final $s:$t = cast $from;
					var $d:$t = cast $into;
					if ($i{s} == null) {
						$i{d} = null;
					} else if ($i{s} != $i{d}) {
						if ($i{d} == null) {
							$i{d} = new $path();
						} else {
							$i{d}.clear();
						}
						for ($i{k} in $i{s}.keys()) {
							$i{d}.set($i{k}, $each);
						}
					}
					cast $i{d};
				};
			}
			final at:String = RPCKinds.local();
			final each:Expr = immutable(kind.element) ? macro $i{s}[$i{at}] : copy(kind.element, kind.elementOptional, macro $i{s}[$i{at}],
				macro $i{d}[$i{at}]);
			return macro {
				final $s:$t = $from;
				var $d:$t = $into;
				if ($i{s} == null) {
					$i{d} = null;
				} else if ($i{s} != $i{d}) {
					if ($i{d} == null) {
						$i{d} = [];
					}
					$i{d}.resize($i{s}.length);
					for ($i{at} in 0...$i{s}.length) {
						$i{d}[$i{at}] = $each;
					}
				}
				$i{d};
			};
		}
		if (kind.token == "bytes") {
			return macro crossbyte.rpc._internal.RPCSame.copyBytes($from, $into);
		}
		return from;
	}

	// ------------------------------------------------------------ the bit cursor

	/**
		Statements putting the low `bits` bits of `value` (no higher ones
		set) into the bit section being written: gathered in `__acc`, `__fill`
		of them, and stored a byte at a time, the first bit the lowest of the
		first byte, as `crossbyte.io.BitWriter` lays them out. Wider than 24,
		in two.
	**/
	public static function putBits(value:Expr, bits:Int):Array<Expr> {
		if (bits > 24) {
			final held:String = RPCKinds.local();
			return [macro var $held:Int = $value].concat(putBits(macro $i{held} & 0xFFFF, 16)).concat(putBits(macro $i{held} >>> 16, bits - 16));
		}
		return [
			macro __acc |= ($value) << __fill,
			macro __fill += $v{bits},
			macro while (__fill >= 8) {
				frame.putByte(__acc & 0xFF);
				__acc >>>= 8;
				__fill -= 8;
			}
		];
	}

	/**
		The next `bits` bits of the bit section being read, as an `Int`:
		bytes taken as they are needed into `__acc`, `__have` of them unread.
	**/
	public static function takeBits(bits:Int):Expr {
		if (bits > 24) {
			final low:String = RPCKinds.local();
			return macro {
				final $low:Int = ${takeBits(16)};
				$i{low} | (${takeBits(bits - 16)} << 16);
			};
		}
		final v:String = RPCKinds.local();
		final mask:Int = (1 << bits) - 1;
		return macro {
			while (__have < $v{bits}) {
				__acc |= input.readByte() << __have;
				__have += 8;
			}
			final $v:Int = __acc & $v{mask};
			__acc >>>= $v{bits};
			__have -= $v{bits};
			$i{v};
		};
	}

	/** The mask's bits in pieces of at most 16: of `mask` for fields 0 to 31, of `maskHigh` past them. **/
	static function maskChunks(n:Int):Array<{high:Bool, shift:Int, bits:Int}> {
		final chunks = [];
		var at:Int = 0;
		while (at < n) {
			final high:Bool = at >= 32;
			final base:Int = high ? at - 32 : at;
			final left:Int = (high ? n - 32 : (n < 32 ? n : 32)) - base;
			final bits:Int = left > 16 ? 16 : left;
			chunks.push({high: high, shift: base, bits: bits});
			at += bits;
		}
		return chunks;
	}

	/** Whether field `i`'s bit is set in `mask`, or `maskHigh` past 31. **/
	static function bitTest(i:Int):Expr {
		return i < 32 ? macro(mask & $v{1 << i}) != 0 : macro(maskHigh & $v{1 << (i - 32)}) != 0;
	}

	// ------------------------------------------------------------ fields

	static function ctorOf(info:StructInfo):TypePath {
		return switch (info.type) {
			case TPath(path): path;
			case _: throw "a class's type is a path";
		};
	}

	static inline function arg(name:String, type:ComplexType):FunctionArg {
		return {name: name, type: type};
	}

	static inline function optArg(name:String, type:ComplexType):FunctionArg {
		return {name: name, type: type, opt: true};
	}

	static function fn(name:String, args:Array<FunctionArg>, ret:ComplexType, body:Expr, pos:Position, ?doc:String):Field {
		return {
			name: name,
			doc: doc,
			access: [APublic, AStatic],
			kind: FFun({args: args, ret: ret, expr: body}),
			pos: pos
		};
	}

	static function method(name:String, args:Array<FunctionArg>, ret:ComplexType, body:Expr, pos:Position):Field {
		return {
			name: name,
			access: [APublic],
			kind: FFun({args: args, ret: ret, expr: body}),
			pos: pos
		};
	}

	/** A read-only property answering `value`, and its getter. **/
	static function prop(name:String, type:ComplexType, value:Expr, pos:Position):Array<Field> {
		return [
			{
				name: name,
				access: [APublic],
				kind: FProp("get", "never", type, null),
				pos: pos
			},
			{
				name: "get_" + name,
				access: [APrivate, AInline],
				kind: FFun({args: [], ret: type, expr: macro return $value}),
				pos: pos
			}
		];
	}
}

/** The generated classes of a structure's replication. **/
typedef Replication = {
	/** `R<hash>`, its statics. **/
	final r:Expr;
	/** `I<hash>`, its codec. **/
	final i:Expr;
	/** `S<hash>`, a patch as read. **/
	final sType:ComplexType;
	final sPath:TypePath;
}
#end
