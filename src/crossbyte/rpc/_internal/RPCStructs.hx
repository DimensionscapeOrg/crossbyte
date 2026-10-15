package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCKinds;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/**
	Structures on the compiled lane: classes that implement
	`crossbyte.rpc.RPCStruct`, and anonymous structures (typedef'd or
	written out).

	A structure is its fields' values one after another, with no names,
	tags or lengths: positional, as hxwire's binary is. The fields go in the
	order of their names, so moving a declaration changes nothing, after
	those pinned with `@:field(n)`, in the order of n. A field that may be
	absent (`Null<T>`, `?name`, `@:optional`) has a byte before it
	saying whether it is there; one that may not has none.

	Its token is its shape written out (each field's pinned id, name and
	kind, in order), so a field renamed, retyped, added, removed or made
	optional changes the op of every method that carries the structure,
	and one moved does not. A class and an anonymous structure with the
	same fields have the same shape, and interoperate.

	Each structure's writer and reader are generated once, as static
	functions of a class of their own in `crossbyte.rpc._internal.codec`,
	and a structure inside another is read and written through the same
	frame by calling them: nothing is allocated for it but the value itself.
	A class is read by `new` with no arguments and then setting each field;
	an anonymous structure is read into locals and made as an object
	literal, which natively gives it its fields as fixed slots, where `{}`
	and a set for each would make a field table.

	The bytes a whole value takes, worked out without writing it, are a
	constant for a structure whose every value takes the same, and else the
	`size` of a class of its own, made the first time a size is asked for
	(see `valueSize`): what a patch's size adds up for a field sent whole.
**/
class RPCStructs {
	/** The kinds made so far, by the structure's key. **/
	static var codecs:Map<String, RPCKind> = new Map();

	static var names:Map<String, String> = new Map();

	/** The structures whose kinds are being worked out, outermost first: one met again inside itself is refused. **/
	static var shaping:Array<String> = [];

	/**
		Starts a fresh walk of structures, and hands back the one it puts
		aside, for `leave`. Typing a field's type can build another class
		there and then (a handler, whose macro asks for kinds of its own),
		and that walk is not this one: what it meets is not inside what this
		one is shaping.
	**/
	public static function enter():Array<String> {
		final outer:Array<String> = shaping;
		shaping = [];
		return outer;
	}

	public static function leave(outer:Array<String>):Void {
		shaping = outer;
	}

	/** Whether `cls`, or a class it extends, implements `crossbyte.rpc.RPCStruct`. **/
	public static function isStruct(cls:ClassType):Bool {
		var current:Null<ClassType> = cls;
		while (current != null) {
			for (iface in current.interfaces) {
				if (implementsStruct(iface.t.get())) {
					return true;
				}
			}
			current = current.superClass != null ? current.superClass.t.get() : null;
		}
		return false;
	}

	static function implementsStruct(iface:ClassType):Bool {
		if (iface.pack.join(".") == "crossbyte.rpc" && iface.name == "RPCStruct") {
			return true;
		}
		for (parent in iface.interfaces) {
			if (implementsStruct(parent.t.get())) {
				return true;
			}
		}
		return false;
	}

	/** The kind of a class that implements `RPCStruct`. **/
	public static function classKind(cls:ClassType, type:Type, pos:Position):RPCKind {
		final path:String = pathKey(cls.pack, cls.name);
		final key:String = "class " + path;
		final known:Null<RPCKind> = cached(key);
		if (known != null) {
			return known;
		}
		if (cls.isInterface) {
			Context.error('RPC cannot carry $path: it is an interface, and a structure has to be a class it can make.', pos);
		}
		if (cls.isPrivate) {
			Context.error('RPC cannot carry $path: it is private to its module, and its reader and writer are generated in another. Make it public.', pos);
		}
		if (cls.params.length > 0) {
			Context.error('RPC cannot carry $path: a structure cannot have type parameters.', pos);
		}
		requireConstructor(cls, path, pos);

		final chain:Array<ClassType> = [];
		var current:Null<ClassType> = cls;
		while (current != null) {
			chain.push(current);
			current = current.superClass != null ? current.superClass.t.get() : null;
		}
		final declared:Array<ClassField> = [];
		for (owner in chain) {
			for (field in owner.fields.get()) {
				switch (field.kind) {
					case FVar(read, write):
						if (field.meta.has(":rpcSkip")) {
							continue;
						}
						if (!plain(read) || !plain(write)) {
							Context.error('RPC cannot carry field ${field.name} of $path: it is a property or final, and a structure\'s fields are set as it is read. Make it a var, or mark it @:rpcSkip.', field.pos);
						}
						declared.push(field);
					case _:
				}
			}
		}
		final shaped:Array<StructField> = shape(path, key, declared, false, cls.module, pos);
		final bitLayout:Bool = RPCBits.isBitLayout(shaped, cls.meta.has(":rpcBits"));
		final fields:Array<StructField> = bitLayout ? RPCBits.withBoolBits(shaped) : shaped;
		return define(key, path, fields, RPCContractMacroTools.fullComplexType(type), [for (owner in chain) pathKey(owner.pack, owner.name)], true,
			cls.module, bitLayout, pos);
	}

	/**
		The kind of an anonymous structure. `named` is the typedef it was
		reached through, if any, for the error that says it holds itself.
	**/
	public static function anonKind(anon:AnonType, type:Type, named:Null<String>, pos:Position):RPCKind {
		final full:ComplexType = RPCContractMacroTools.fullComplexType(type);
		final key:String = "anon " + ComplexTypeTools.toString(full);
		final known:Null<RPCKind> = cached(key);
		if (known != null) {
			return known;
		}
		final name:String = named != null ? named : "the structure " + TypeTools.toString(type);
		final shaped:Array<StructField> = shape(name, named != null ? "typedef " + named : key, anon.fields, true, null, pos);
		final bitLayout:Bool = RPCBits.isBitLayout(shaped, false);
		final fields:Array<StructField> = bitLayout ? RPCBits.withBoolBits(shaped) : shaped;
		return define(key, name, fields, full, [], false, null, bitLayout, pos);
	}

	/**
		The kind of an enum: its constructor's index (one byte, or two for
		an enum of more than 256 constructors), then that constructor's
		arguments, each as its kind is written, positionally, as a
		structure's fields are. A simple enum is its index alone, of fixed
		size, and an array of one is one run. A tagged union, as Rust's enums
		and protobuf's `oneof` are, where a lane of ordinals only would leave
		an enum with arguments to be packed by hand.

		Its token names each constructor, in index order, with its
		arguments' kinds: `<Idle,Walk(f32,f32),Hit(i32)>`. Adding, removing,
		renaming or reordering a constructor, or retyping an argument, makes
		another method; a constructor's arguments renamed do not.
	**/
	public static function enumKind(en:EnumType, type:Type, pos:Position):RPCKind {
		final path:String = pathKey(en.pack, en.name);
		final key:String = "enum " + path;
		final known:Null<RPCKind> = cached(key);
		if (known != null) {
			return known;
		}
		if (en.isPrivate) {
			Context.error('RPC cannot carry $path: it is private to its module, and its reader and writer are generated in another. Make it public.', pos);
		}
		if (en.params.length > 0) {
			Context.error('RPC cannot carry $path: an enum with type parameters is not carried. Declare one for the types it holds.', pos);
		}
		if (shaping.indexOf(key) >= 0) {
			Context.error('RPC cannot carry $path: it contains itself, through ${shaping.slice(shaping.indexOf(key)).join(" -> ")}. A value on the wire is a tree of a fixed depth; send a list of nodes with indices instead.', pos);
		}
		shaping.push(key);
		final ctors:Array<EnumCtor> = [];
		try {
			for (ctorName in en.names) {
				final ctor:EnumField = en.constructs.get(ctorName);
				final args:Array<StructField> = [];
				switch (Context.follow(ctor.type)) {
					case TFun(fnArgs, _):
						for (arg in fnArgs) {
							final kind:Null<RPCKind> = RPCKinds.ofType(arg.t, ctor.pos);
							if (kind == null) {
								Context.error('RPC cannot carry $path: argument ${arg.name} of ${ctorName} is ' + TypeTools.toString(arg.t)
									+ ', not a kind RPC carries.', ctor.pos);
							}
							RPCKinds.requireNoPatch(kind, 'argument ${arg.name} of ${ctorName} of $path');
							args.push({
								name: arg.name,
								pinned: -1,
								type: arg.t,
								optional: arg.opt || RPCKinds.isNullType(arg.t),
								kind: kind
							});
						}
					case _:
				}
				ctors.push({name: ctorName, index: ctor.index, args: args});
			}
		} catch (error:Dynamic) {
			shaping.pop();
			throw error;
		}
		shaping.pop();
		ctors.sort((a, b) -> a.index - b.index);

		final wide:Bool = ctors.length > 256;
		final width:Int = wide ? 2 : 1;
		var simple:Bool = true;
		for (ctor in ctors) {
			if (ctor.args.length > 0) {
				simple = false;
			}
		}
		final token:String = "<" + [
			for (ctor in ctors)
				ctor.name + (ctor.args.length == 0 ? "" : "(" + [for (arg in ctor.args) RPCKinds.token(arg.kind, arg.optional)].join(",") + ")")
		].join(",") + ">";

		final codec:String = codecName(key, "E");
		final codecPath:Array<String> = ["crossbyte", "rpc", "_internal", "codec", codec];
		final enumType:ComplexType = RPCContractMacroTools.fullComplexType(type);
		// Its constructors named through its module, which a type of another
		// name in that module needs.
		final moduleParts:Array<String> = en.module.split(".");
		final enumPath:Array<String> = moduleParts[moduleParts.length - 1] == en.name ? moduleParts : moduleParts.concat([en.name]);
		final nullName:Expr = macro $v{path};
		final putOrdinal:Expr = wide ? macro frame.putShort(ordinal) : macro frame.putByte(ordinal);
		final getOrdinal:Expr = wide ? macro crossbyte.rpc._internal.RPCWire.readU16(input) : macro input.readByte();

		final argCases:Array<Case> = [];
		final readCases:Array<Case> = [];
		for (ctor in ctors) {
			final ctorRef:Expr = macro $p{enumPath.concat([ctor.name])};
			if (ctor.args.length == 0) {
				readCases.push({values: [macro $v{ctor.index}], expr: ctorRef});
				continue;
			}
			final names:Array<Expr> = [for (i in 0...ctor.args.length) macro $i{"__a" + i}];
			final writes:Array<Expr> = [
				for (i in 0...ctor.args.length)
					RPCKinds.write(ctor.args[i].kind, ctor.args[i].optional, macro frame, names[i])
			];
			argCases.push({values: [{expr: ECall(ctorRef, names), pos: pos}], expr: macro $b{writes}});
			final reads:Array<Expr> = [
				for (i in 0...ctor.args.length) {
					final local:String = "__a" + i;
					final get:Expr = RPCKinds.read(ctor.args[i].kind, ctor.args[i].optional, macro input, macro end);
					macro var $local = $get;
				}
			];
			reads.push({expr: ECall(ctorRef, names), pos: pos});
			readCases.push({values: [macro $v{ctor.index}], expr: macro $b{reads}});
		}
		final writeArgs:Expr = argCases.length == 0 ? macro {} : {expr: ESwitch(macro value, argCases, macro {}), pos: pos};
		final readSwitch:Expr = {expr: ESwitch(getOrdinal, readCases, macro throw "RPC enum constructor out of range"), pos: pos};

		final fields:Array<Field> = [
			{
				name: "write",
				doc: 'Writes $path into a frame: ' + token,
				access: [APublic, AStatic],
				kind: FFun({
					args: [{name: "frame", type: macro :crossbyte.rpc._internal.RPCFrame}, {name: "value", type: enumType}],
					ret: macro :Void,
					expr: macro {
						if (value == null) {
							throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
						}
						final ordinal:Int = Type.enumIndex(value);
						$putOrdinal;
						$writeArgs;
					}
				}),
				pos: pos
			},
			{
				name: "read",
				doc: 'Reads $path from a frame ending at `end`.',
				access: [APublic, AStatic],
				kind: FFun({
					args: [{name: "input", type: macro :crossbyte.io.ByteArrayInput}, {name: "end", type: macro :Int}],
					ret: enumType,
					expr: macro return $readSwitch
				}),
				pos: pos
			}
		];
		if (simple) {
			// One of fixed size: put and got at a place, for an array of them
			// as one run.
			final putIndex:Expr = wide ? macro crossbyte.rpc._internal.RPCBytes.set16(data, at, Type.enumIndex(value)) : macro crossbyte.rpc._internal.RPCBytes.set8(data,
				at, Type.enumIndex(value));
			final getIndex:Expr = wide ? macro crossbyte.rpc._internal.RPCBytes.getU16(data, at) : macro crossbyte.rpc._internal.RPCBytes.getU8(data, at);
			final getSwitch:Expr = {expr: ESwitch(getIndex, readCases, macro throw "RPC enum constructor out of range"), pos: pos};
			fields.push({
				name: "put",
				access: [APublic, AStatic, AInline],
				kind: FFun({
					args: [{name: "data", type: macro :haxe.io.Bytes}, {name: "at", type: macro :Int}, {name: "value", type: enumType}],
					ret: macro :Void,
					expr: macro {
						if (value == null) {
							throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
						}
						$putIndex;
					}
				}),
				pos: pos
			});
			fields.push({
				name: "get",
				access: [APublic, AStatic],
				kind: FFun({
					args: [{name: "data", type: macro :haxe.io.Bytes}, {name: "at", type: macro :Int}],
					ret: enumType,
					expr: macro return $getSwitch
				}),
				pos: pos
			});
		}
		if (!exists(codecPath.join("."))) {
			Context.defineType({
				pack: codecPath.slice(0, codecPath.length - 1),
				name: codec,
				pos: pos,
				meta: [{name: ":noCompletion", params: [], pos: pos}],
				kind: TDClass(),
				fields: fields
			}, en.module);
		}

		final ref:Expr = macro $p{codecPath};
		final kind:RPCKind = {
			name: path,
			token: token,
			size: simple ? width : -1,
			roomOf: simple ? null : value -> macro $v{width},
			zero: macro null,
			compound: true,
			write: (frame, value) -> macro $ref.write($frame, $value),
			read: (input, end) -> macro $ref.read($input, $end),
			put: simple ? (data, at, value) -> macro $ref.put($data, $at, $value) : null,
			get: simple ? (data, at) -> macro $ref.get($data, $at) : null,
			measure: simple ? null : value -> enumSize(key, path, ctors, enumType, enumPath, width, en.module, pos, value),
			isEnum: true,
			valueType: enumType
		};
		codecs.set(key, kind);
		return kind;
	}

	/**
		The bytes an enum's writer writes for `value`, as an expression of it:
		a call of the `size` of its size class (see `valueSize`), made the
		first time one is asked for. Its index, and its constructor's
		arguments as their kinds write them.
	**/
	static function enumSize(key:String, path:String, ctors:Array<EnumCtor>, enumType:ComplexType, enumPath:Array<String>, width:Int,
			module:String, pos:Position, value:Expr):Expr {
		var ref:Null<Expr> = sizers.get(key);
		if (ref == null) {
			final name:String = codecName(key, "Z");
			final sizePath:Array<String> = ["crossbyte", "rpc", "_internal", "codec", name];
			ref = macro $p{sizePath};
			sizers.set(key, ref);
			if (!exists(sizePath.join("."))) {
				final cases:Array<Case> = [];
				for (ctor in ctors) {
					if (ctor.args.length == 0) {
						continue;
					}
					var fixed:Int = width;
					var sum:Null<Expr> = null;
					final names:Array<Expr> = [];
					for (i in 0...ctor.args.length) {
						final arg = ctor.args[i];
						if (!arg.optional && RPCKinds.fixedSize(arg.kind)) {
							fixed += arg.kind.size;
							names.push(macro _);
							continue;
						}
						final local:String = "__a" + i;
						names.push(macro $i{local});
						final each:Expr = RPCKinds.sizeOf(arg.kind, arg.optional, macro $i{local});
						sum = sum == null ? each : macro $sum + $each;
					}
					final ctorRef:Expr = macro $p{enumPath.concat([ctor.name])};
					cases.push({values: [{expr: ECall(ctorRef, names), pos: pos}], expr: sum == null ? macro $v{fixed} : macro $v{fixed} + $sum});
				}
				final nullName:Expr = macro $v{path};
				final pick:Expr = {expr: ESwitch(macro value, cases, macro $v{width}), pos: pos};
				Context.defineType({
					pack: sizePath.slice(0, sizePath.length - 1),
					name: name,
					pos: pos,
					meta: [{name: ":noCompletion", params: [], pos: pos}],
					kind: TDClass(),
					fields: [
						{
							name: "size",
							doc: 'The bytes $path takes as its codec writes it.',
							access: [APublic, AStatic],
							kind: FFun({
								args: [{name: "value", type: enumType}],
								ret: macro :Int,
								expr: macro {
									if (value == null) {
										throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
									}
									return $pick;
								}
							}),
							pos: pos
						}
					]
				}, module);
			}
		}
		return macro $ref.size($value);
	}

	/** Every field's kind, in wire order, checked. **/
	static function shape(name:String, key:String, declared:Array<ClassField>, anonymous:Bool, module:Null<String>, pos:Position):Array<StructField> {
		if (shaping.indexOf(key) >= 0) {
			Context.error('RPC cannot carry $name: it contains itself, through ${shaping.slice(shaping.indexOf(key)).join(" -> ")}. A structure on the wire is a tree of a fixed depth; send a list of nodes with indices instead.', pos);
		}
		shaping.push(key);
		final fields:Array<StructField> = [];
		final pinnedIds:Map<Int, String> = new Map();
		try {
			for (field in declared) {
				final type:Type = field.type;
				final optional:Bool = RPCKinds.isNullType(type) || (anonymous && field.meta.has(":optional"));
				final typeKind:Null<RPCKind> = RPCKinds.ofType(type, field.pos);
				if (typeKind == null) {
					Context.error('RPC cannot carry field ${field.name} of $name: ' + TypeTools.toString(type) + ' is not a kind RPC carries.'
						+ (anonymous ? '' : ' Mark it @:rpcSkip to leave it off the wire.'), field.pos);
				}
				RPCKinds.requireNoPatch(typeKind, 'field ${field.name} of $name');
				// @:quantize or @:range make it a kind of the bit layout.
				final kind:RPCKind = RPCBits.fieldKind(field, typeKind, optional, name, module);
				final pinned:Int = pinnedId(field, name);
				if (pinned >= 0) {
					if (pinnedIds.exists(pinned)) {
						Context.error('RPC fields ${pinnedIds.get(pinned)} and ${field.name} of $name are both pinned at @:field($pinned).', field.pos);
					}
					pinnedIds.set(pinned, field.name);
				}
				fields.push({
					name: field.name,
					pinned: pinned,
					type: type,
					optional: optional,
					kind: kind,
					pos: field.pos
				});
			}
		} catch (error:Dynamic) {
			shaping.pop();
			throw error;
		}
		shaping.pop();
		if (fields.length == 0) {
			Context.error('RPC cannot carry $name: it has no fields to send.', pos);
		}
		fields.sort(byWireOrder);
		return fields;
	}

	/** Pinned fields first, by id; then the rest by name. **/
	static function byWireOrder(a:StructField, b:StructField):Int {
		if (a.pinned >= 0 || b.pinned >= 0) {
			if (a.pinned < 0) {
				return 1;
			}
			if (b.pinned < 0) {
				return -1;
			}
			return a.pinned - b.pinned;
		}
		return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
	}

	/** A field's `@:field(n)`, or -1. **/
	static function pinnedId(field:ClassField, owner:String):Int {
		final entries = field.meta.extract(":field");
		if (entries.length == 0) {
			return -1;
		}
		final params = entries[0].params;
		final id:Null<Int> = params != null && params.length == 1 ? switch (params[0].expr) {
			case EConst(CInt(text)): Std.parseInt(text);
			case _: null;
		} : null;
		if (id == null || id < 0 || id > 65535) {
			Context.error('RPC field ${field.name} of $owner: @:field takes one whole number from 0 to 65535.', field.pos);
		}
		return id;
	}

	/**
		The kind of a structure of `fields`, and its codec class, defined the
		first time it is asked for. `access` are the classes whose private
		fields the codec reads and sets.
	**/
	static function define(key:String, name:String, fields:Array<StructField>, type:ComplexType, access:Array<String>, isClass:Bool,
			module:Null<String>, bitLayout:Bool, pos:Position):RPCKind {
		var size:Int = 0;
		var least:Int = 0;
		if (!bitLayout) {
			for (field in fields) {
				final each:Int = RPCKinds.size(field.kind, field.optional);
				if (size >= 0) {
					size = each < 0 ? -1 : size + each;
				}
				least += field.optional ? 1 : RPCKinds.leastOf(field.kind);
			}
		} else {
			// Its bit section in whole bytes, a presence bit for each field
			// that may be absent (whose size then depends on the value), and
			// the byte fields after it.
			var bitsMost:Int = 0;
			var bitsLeast:Int = 0;
			for (field in fields) {
				if (field.optional) {
					size = -1;
					bitsMost++;
					bitsLeast++;
				}
				if (field.kind.bits != null) {
					bitsMost += field.kind.bits.width;
					if (!field.optional) {
						bitsLeast += field.kind.bits.width;
					}
					continue;
				}
				final each:Int = RPCKinds.size(field.kind, false);
				if (size >= 0) {
					size = each < 0 ? -1 : size + each;
				}
				if (!field.optional) {
					least += RPCKinds.leastOf(field.kind);
				}
			}
			if (size >= 0) {
				size += (bitsMost + 7) >> 3;
			}
			least += (bitsLeast + 7) >> 3;
			if (least == 0) {
				least = 1;
			}
		}
		final token:String = (bitLayout ? "b{" : "{") + [
			for (field in fields)
				(field.pinned >= 0 ? field.pinned + "=" : "") + field.name + ":" + RPCKinds.token(field.kind, field.optional)
		].join(",") + "}";

		final codec:String = codecName(key, isClass ? "C" : "A");
		final codecPath:Array<String> = ["crossbyte", "rpc", "_internal", "codec", codec];
		final write:Array<Expr> = [];
		final read:Array<Expr> = [];
		final made:Array<ObjectField> = [];
		// Each field is read in a scope of its own (see `scoped`). An
		// anonymous structure's field goes into a local declared before it.
		if (bitLayout) {
			// The bit section, then the byte fields: see RPCBits.writeValue.
			for (e in RPCBits.writeValue(fields, macro value)) {
				write.push(e);
			}
			if (!isClass) {
				for (i in 0...fields.length) {
					final local:String = "__f" + i;
					final localType:ComplexType = fieldLocalType(fields[i]);
					read.push(macro var $local:$localType);
				}
			}
			final assign = (field:StructField, i:Int, value:Expr) -> {
				final fieldName:String = field.name;
				return isClass ? scoped(macro made.$fieldName, value) : scoped(macro $i{"__f" + i}, value);
			};
			for (e in RPCBits.readValue(fields, macro input, macro end, assign)) {
				read.push(e);
			}
			if (!isClass) {
				for (i in 0...fields.length) {
					made.push({field: fields[i].name, expr: macro $i{"__f" + i}});
				}
			}
		}
		for (i in 0...fields.length) {
			if (bitLayout) {
				break;
			}
			final field = fields[i];
			final fieldName:String = field.name;
			write.push(RPCKinds.write(field.kind, field.optional, macro frame, macro value.$fieldName));
			final get:Expr = RPCKinds.read(field.kind, field.optional, macro input, macro end);
			if (isClass) {
				read.push(scoped(macro made.$fieldName, get));
			} else {
				final local:String = "__f" + i;
				final localType:ComplexType = fieldLocalType(field);
				read.push(macro var $local:$localType);
				read.push(scoped(macro $i{local}, get));
				made.push({field: fieldName, expr: macro $i{local}});
			}
		}
		final nullName:Expr = macro $v{name};
		final readBody:Expr = if (isClass) {
			final ctor:TypePath = switch (type) {
				case TPath(path): path;
				case _: throw "a class's type is a path";
			};
			macro {
				var made = new $ctor();
				$b{read};
				return made;
			};
		} else {
			read.push({expr: EReturn({expr: EObjectDecl(made), pos: pos}), pos: pos});
			macro $b{read};
		};

		final meta:Metadata = [{name: ":noCompletion", params: [], pos: pos}];
		for (path in access) {
			meta.push({name: ":access", params: [Context.parse(path, pos)], pos: pos});
		}
		final definition:TypeDefinition = {
			pack: codecPath.slice(0, codecPath.length - 1),
			name: codec,
			pos: pos,
			meta: meta,
			kind: TDClass(),
			fields: [
				{
					name: "write",
					doc: 'Writes $name into a frame: ' + token,
					access: [APublic, AStatic],
					kind: FFun({
						args: [{name: "frame", type: macro :crossbyte.rpc._internal.RPCFrame}, {name: "value", type: type}],
						ret: macro :Void,
						expr: macro {
							if (value == null) {
								throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
							}
							$b{write};
						}
					}),
					pos: pos
				},
				{
					name: "read",
					doc: 'Reads $name from a frame ending at `end`.',
					access: [APublic, AStatic],
					kind: FFun({
						args: [{name: "input", type: macro :crossbyte.io.ByteArrayInput}, {name: "end", type: macro :Int}],
						ret: type,
						expr: readBody
					}),
					pos: pos
				}
			]
		};
		// Every field a number or a Bool that cannot be absent: the structure
		// is a run of fixed size, put and got at a place with no check of
		// room a field, and an array of them is one run as an array of Ints
		// is (see RPCKinds.arrayKind).
		var packed:Bool = true;
		for (field in fields) {
			if (field.optional || field.kind.put == null || field.kind.get == null) {
				packed = false;
			}
		}
		if (packed) {
			final puts:Array<Expr> = [];
			final gets:Array<Expr> = [];
			final locals:Array<ObjectField> = [];
			var offset:Int = 0;
			for (i in 0...fields.length) {
				final field = fields[i];
				final fieldName:String = field.name;
				puts.push(field.kind.put(macro data, macro at + $v{offset}, macro value.$fieldName));
				final get:Expr = field.kind.get(macro data, macro at + $v{offset});
				if (isClass) {
					gets.push(macro made.$fieldName = $get);
				} else {
					final local:String = "__f" + i;
					gets.push(macro var $local = $get);
					locals.push({field: fieldName, expr: macro $i{local}});
				}
				offset += field.kind.size;
			}
			final getBody:Expr = if (isClass) {
				final ctor:TypePath = switch (type) {
					case TPath(path): path;
					case _: throw "a class's type is a path";
				};
				macro {
					var made = new $ctor();
					$b{gets};
					return made;
				};
			} else {
				gets.push({expr: EReturn({expr: EObjectDecl(locals), pos: pos}), pos: pos});
				macro $b{gets};
			};
			definition.fields.push({
				name: "put",
				doc: 'Puts $name at `at` in `data`, which has room for its $size bytes there.',
				access: [APublic, AStatic, AInline],
				kind: FFun({
					args: [{name: "data", type: macro :haxe.io.Bytes}, {name: "at", type: macro :Int}, {name: "value", type: type}],
					ret: macro :Void,
					expr: macro {
						if (value == null) {
							throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
						}
						$b{puts};
					}
				}),
				pos: pos
			});
			definition.fields.push({
				name: "get",
				doc: 'Gets $name from `at` in `data`, which holds its $size bytes there.',
				access: [APublic, AStatic, AInline],
				kind: FFun({
					args: [{name: "data", type: macro :haxe.io.Bytes}, {name: "at", type: macro :Int}],
					ret: type,
					expr: getBody
				}),
				pos: pos
			});
			// The writer and reader of one: room made for, or checked, once.
			definition.fields[0].kind = FFun({
				args: [{name: "frame", type: macro :crossbyte.rpc._internal.RPCFrame}, {name: "value", type: type}],
				ret: macro :Void,
				expr: macro {
					frame.fit($v{size});
					final at:Int = frame.position;
					put(frame, at, value);
					frame.position = at + $v{size};
				}
			});
			definition.fields[1].kind = FFun({
				args: [{name: "input", type: macro :crossbyte.io.ByteArrayInput}, {name: "end", type: macro :Int}],
				ret: type,
				expr: macro {
					final at:Int = input.position;
					final limit:Int = end < input.length ? end : input.length;
					if ($v{size} > limit - at) {
						throw "RPC frame names more than it holds";
					}
					input.position = at + $v{size};
					return get(cast input, at);
				}
			});
		}
		if (!exists(codecPath.join("."))) {
			Context.defineType(definition, module);
		}

		// Every value the same bytes: none of its fields may be absent, and each
		// takes the same bytes whatever it holds.
		var exact:Bool = size >= 0;
		for (field in fields) {
			if (field.optional || (field.kind.bits == null && !RPCKinds.fixedSize(field.kind))) {
				exact = false;
			}
		}
		final ref:Expr = macro $p{codecPath};
		final info:StructInfo = {
			key: key,
			name: name,
			fields: fields,
			type: type,
			access: access,
			isClass: isClass,
			module: module,
			codec: codec,
			token: token,
			size: size,
			exact: exact,
			least: least,
			bitLayout: bitLayout,
			bitsOnly: bitLayout && RPCBits.bitsOnly(fields) && RPCBits.leastBits(fields) > 0,
			pos: pos
		};
		final kind:RPCKind = {
			name: name,
			token: token,
			size: size,
			roomOf: size >= 0 ? null : value -> macro $v{least},
			zero: macro null,
			compound: true,
			write: (frame, value) -> macro $ref.write($frame, $value),
			read: (input, end) -> macro $ref.read($input, $end),
			put: packed ? (data, at, value) -> macro $ref.put($data, $at, $value) : null,
			get: packed ? (data, at) -> macro $ref.get($data, $at) : null,
			measure: exact ? null : value -> valueSize(info, value),
			valueType: type,
			struct: info
		};
		codecs.set(key, kind);
		return kind;
	}

	/**
		`target = value` in a block of its own, so the locals reading `value`
		makes end with it. Neko's loader refuses a function holding more
		locals at once than its stack allows, as a reader of forty fields
		did with every field's locals in one scope. The block keeps a local
		of its own, as one holding a lone assignment is merged into the one
		around it.
	**/
	public static function scoped(target:Expr, value:Expr):Expr {
		return macro {
			final __v = $value;
			$target = __v;
		};
	}

	/** The type of the local an anonymous structure's field is read into. **/
	static function fieldLocalType(field:StructField):ComplexType {
		final full:ComplexType = RPCContractMacroTools.fullComplexType(field.type);
		return field.optional && !RPCKinds.isNullType(field.type) ? TPath({pack: [], name: "Null", params: [TPType(full)]}) : full;
	}

	/** The size classes made so far, by the structure's or enum's key. **/
	static var sizers:Map<String, Expr> = new Map();

	/**
		The bytes the codec of `info` writes for `value`, a whole value of the
		structure, as an expression of it, worked out without writing: its
		size when every value takes the same, or else a call of the `size` of
		a class of its own, `Z<hash>` in `crossbyte.rpc._internal.codec`, made
		the first time a size is asked for, so a structure whose size nothing
		asks for has none.
	**/
	public static function valueSize(info:StructInfo, value:Expr):Expr {
		if (info.exact) {
			return macro $v{info.size};
		}
		var ref:Null<Expr> = sizers.get(info.key);
		if (ref == null) {
			final name:String = codecName(info.key, "Z");
			final path:Array<String> = ["crossbyte", "rpc", "_internal", "codec", name];
			ref = macro $p{path};
			sizers.set(info.key, ref);
			if (!exists(path.join("."))) {
				final meta:Metadata = [{name: ":noCompletion", params: [], pos: info.pos}];
				for (owner in info.access) {
					meta.push({name: ":access", params: [Context.parse(owner, info.pos)], pos: info.pos});
				}
				Context.defineType({
					pack: path.slice(0, path.length - 1),
					name: name,
					pos: info.pos,
					meta: meta,
					kind: TDClass(),
					fields: [
						{
							name: "size",
							doc: 'The bytes ${info.name} takes as its codec writes it.',
							access: [APublic, AStatic],
							kind: FFun({
								args: [{name: "value", type: info.type}],
								ret: macro :Int,
								expr: sizeBody(info)
							}),
							pos: info.pos
						}
					]
				}, info.module);
			}
		}
		return macro $ref.size($value);
	}

	/**
		The body of a structure's `size(value)`: what `define`'s writer writes,
		added up. In the bit layout, its bit section's bits (a presence bit for
		each field that may be absent, and each bit field's that is there) in
		whole bytes, and the byte fields that are there.
	**/
	static function sizeBody(info:StructInfo):Expr {
		final nullName:Expr = macro $v{info.name};
		final adds:Array<Expr> = [];
		var bytes:Int = 0;
		var bits:Int = 0;
		for (field in info.fields) {
			final fname:String = field.name;
			final get:Expr = macro value.$fname;
			if (!info.bitLayout) {
				if (!field.optional && RPCKinds.fixedSize(field.kind)) {
					bytes += field.kind.size;
				} else {
					adds.push(macro __size += ${RPCKinds.sizeOf(field.kind, field.optional, get)});
				}
				continue;
			}
			if (field.optional) {
				bits++;
			}
			if (field.kind.bits != null) {
				if (field.optional) {
					adds.push(macro if ($get != null) __bits += $v{field.kind.bits.width});
				} else {
					bits += field.kind.bits.width;
				}
			} else if (field.optional) {
				adds.push(macro if ($get != null) __size += ${RPCKinds.sizeOf(field.kind, false, get)});
			} else if (RPCKinds.fixedSize(field.kind)) {
				bytes += field.kind.size;
			} else {
				adds.push(macro __size += ${RPCKinds.sizeOf(field.kind, false, get)});
			}
		}
		return macro {
			if (value == null) {
				throw crossbyte.rpc._internal.RPCFrame.nullValue($nullName);
			}
			var __size:Int = $v{bytes};
			var __bits:Int = $v{bits};
			$b{adds};
			return ((__bits + 7) >> 3) + __size;
		};
	}

	/** A class name for the codec of `key`, the same each build, and no other key's. **/
	public static function codecName(key:String, prefix:String):String {
		var name:String = prefix + StringTools.hex(Hash.fnv1a32(Bytes.ofString(key)), 8);
		var other:Null<String> = names.get(name);
		var suffix:Int = 0;
		while (other != null && other != key) {
			suffix++;
			other = names.get(name + "_" + suffix);
		}
		if (suffix > 0) {
			name += "_" + suffix;
		}
		names.set(name, key);
		return name;
	}

	/** Macro statics start afresh each compilation (Haxe 4), so this knows only this build's structures. **/
	static function cached(key:String):Null<RPCKind> {
		return codecs.get(key);
	}

	public static function exists(path:String):Bool {
		return try Context.getType(path) != null catch (_:Dynamic) false;
	}

	/** A class whose fields RPC sets needs a constructor that takes nothing. **/
	static function requireConstructor(cls:ClassType, path:String, pos:Position):Void {
		var current:Null<ClassType> = cls;
		while (current != null) {
			if (current.constructor != null) {
				switch (Context.follow(current.constructor.get().type)) {
					case TFun(args, _):
						for (arg in args) {
							if (!arg.opt) {
								Context.error('RPC cannot carry $path: it is read by calling its constructor with no arguments, and that one takes ${arg.name}. Give the argument a default, or the class a constructor that takes none.',
									pos);
							}
						}
					case _:
				}
				return;
			}
			current = current.superClass != null ? current.superClass.t.get() : null;
		}
		Context.error('RPC cannot carry $path: it has no constructor, and it is read by calling one with no arguments. Give it `public function new() {}`.',
			pos);
	}

	static inline function plain(access:VarAccess):Bool {
		return switch (access) {
			case AccNormal | AccNo: true;
			case _: false;
		}
	}

	static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}
}

private typedef EnumCtor = {
	final name:String;
	final index:Int;
	final args:Array<StructField>;
}

/** A structure's field, as the generated code reads and writes it. **/
typedef StructField = {
	final name:String;
	final pinned:Int;
	final type:Type;
	final optional:Bool;
	final kind:RPCKind;
	@:optional final pos:Position;
}

/**
	A structure's shape, kept with its kind for the code generated from it
	later: its codec (`RPCPatches`), its patches.
**/
typedef StructInfo = {
	/** The key its kind is cached under. **/
	final key:String;
	/** What it is called in an error. **/
	final name:String;
	/** Its fields in wire order. **/
	final fields:Array<StructField>;
	/** Its type, written out in full. **/
	final type:ComplexType;
	/** The classes whose private fields generated code reads and sets. **/
	final access:Array<String>;
	final isClass:Bool;
	/** The module the generated classes are defined in. **/
	final module:Null<String>;
	/** Its codec class's name, in `crossbyte.rpc._internal.codec`. **/
	final codec:String;
	/** Its token in a signature. **/
	final token:String;
	/** Whether it is in the bit layout (`RPCBits`). **/
	final bitLayout:Bool;
	/** Whether every field is in its bit section, so an array of it is one run of bits. **/
	final bitsOnly:Bool;
	/** The bytes a whole value takes, or -1 when that depends on the value. **/
	final size:Int;
	/** Whether every value takes exactly `size` bytes: none of its fields may be absent, and each takes the same bytes whatever it holds. **/
	final exact:Bool;
	/** The fewest bytes a whole value takes, at least one, as `RPCKinds.leastOf` answers for its kind. **/
	final least:Int;
	final pos:Position;
}
#end
