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
	absent, `Null<T>`, `?name`, `@:optional`, has a byte before it
	saying whether it is there; one that may not has none.

	Its token is its shape written out, each field's pinned id, name and
	kind, in order, so a field renamed, retyped, added, removed or made
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
		there and then, a handler, whose macro asks for kinds of its own,
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
		final fields:Array<StructField> = shape(path, key, declared, false, pos);
		return define(key, path, fields, RPCContractMacroTools.fullComplexType(type), [for (owner in chain) pathKey(owner.pack, owner.name)], true,
			cls.module, pos);
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
		final fields:Array<StructField> = shape(name, named != null ? "typedef " + named : key, anon.fields, true, pos);
		return define(key, name, fields, full, [], false, null, pos);
	}

	/**
		The kind of an enum: its constructor's index, one byte, or two for
		an enum of more than 256 constructors, then that constructor's
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
			get: simple ? (data, at) -> macro $ref.get($data, $at) : null
		};
		codecs.set(key, kind);
		return kind;
	}

	/** Every field's kind, in wire order, checked. **/
	static function shape(name:String, key:String, declared:Array<ClassField>, anonymous:Bool, pos:Position):Array<StructField> {
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
				final kind:Null<RPCKind> = RPCKinds.ofType(type, field.pos);
				if (kind == null) {
					Context.error('RPC cannot carry field ${field.name} of $name: ' + TypeTools.toString(type) + ' is not a kind RPC carries.'
						+ (anonymous ? '' : ' Mark it @:rpcSkip to leave it off the wire.'), field.pos);
				}
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
					kind: kind
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
			module:Null<String>, pos:Position):RPCKind {
		var size:Int = 0;
		var least:Int = 0;
		for (field in fields) {
			final each:Int = RPCKinds.size(field.kind, field.optional);
			if (size >= 0) {
				size = each < 0 ? -1 : size + each;
			}
			least += field.optional ? 1 : (field.kind.size > 0 ? field.kind.size : 1);
		}
		final token:String = "{" + [
			for (field in fields)
				(field.pinned >= 0 ? field.pinned + "=" : "") + field.name + ":" + RPCKinds.token(field.kind, field.optional)
		].join(",") + "}";

		final codec:String = codecName(key, isClass ? "C" : "A");
		final codecPath:Array<String> = ["crossbyte", "rpc", "_internal", "codec", codec];
		final write:Array<Expr> = [];
		final read:Array<Expr> = [];
		final made:Array<ObjectField> = [];
		for (i in 0...fields.length) {
			final field = fields[i];
			final fieldName:String = field.name;
			write.push(RPCKinds.write(field.kind, field.optional, macro frame, macro value.$fieldName));
			final get:Expr = RPCKinds.read(field.kind, field.optional, macro input, macro end);
			if (isClass) {
				read.push(macro made.$fieldName = $get);
			} else {
				final local:String = "__f" + i;
				read.push(macro var $local = $get);
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

		final ref:Expr = macro $p{codecPath};
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
			get: packed ? (data, at) -> macro $ref.get($data, $at) : null
		};
		codecs.set(key, kind);
		return kind;
	}

	/** A class name for the codec of `key`, the same each build, and no other key's. **/
	static function codecName(key:String, prefix:String):String {
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

	static function exists(path:String):Bool {
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

private typedef StructField = {
	final name:String;
	final pinned:Int;
	final type:Type;
	final optional:Bool;
	final kind:RPCKind;
}
#end
