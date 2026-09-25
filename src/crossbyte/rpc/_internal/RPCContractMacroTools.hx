package crossbyte.rpc._internal;

#if macro
import crossbyte.utils.Hash;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

using haxe.macro.Tools;

class RPCContractMacroTools {
	public static inline function isReservedSystemMethod(name:String):Bool {
		return name == "ping" || name == "beforeCall" || name == "afterCall" || name == "dispatch";
	}

	public static inline function reservedSystemMethodMessage(name:String):String {
		return name == "ping" ? "RPC contract method name '" + name + "' is reserved for built-in RPC system traffic." : "RPC contract method name '"
			+ name + "' is reserved: RPCHandler declares it.";
	}

	public static function getContractMethods(metaName:String):Null<Array<ContractMethod>> {
		final meta = getClassMetadata(metaName);
		if (meta == null) {
			return null;
		}
		if (meta.params == null || meta.params.length != 1) {
			Context.error(metaName + " requires exactly one contract interface argument.", meta.pos);
		}
		return readContractMethods(meta.params[0], meta.pos, metaName);
	}

	public static function getImplementedContractMethods(metaName:String):Null<Array<ContractMethod>> {
		final meta = getClassMetadata(metaName);
		if (meta != null && meta.params != null && meta.params.length > 0) {
			Context.error(metaName + " does not take arguments. Implement the shared contract interface directly on the handler class.", meta.pos);
		}
		final localClass = Context.getLocalClass();
		if (localClass == null) {
			return null;
		}
		final interfaces = localClass.get().interfaces;
		if (interfaces.length == 0) {
			return null;
		}
		if (interfaces.length > 1) {
			final errorPos = meta != null ? meta.pos : localClass.get().pos;
			Context.error(metaName + " only supports one directly-implemented shared RPC contract interface.", errorPos);
		}
		final pos = meta != null ? meta.pos : localClass.get().pos;
		final contract = interfaces[0];
		final contractType = contract.t.get();
		return readContractClass(contractType, pos, metaName, contractType.params, contract.params);
	}

	public static function requireExtends(metaName:String, expectedPath:String):Void {
		final localClass = Context.getLocalClass();
		if (localClass == null) {
			return;
		}
		var superClass = localClass.get().superClass;
		while (superClass != null) {
			final current = superClass.t.get();
			if (pathKey(current.pack, current.name) == expectedPath) {
				return;
			}
			superClass = current.superClass;
		}
		Context.error(metaName + " can only be used on classes extending " + expectedPath + ".", localClass.get().pos);
	}

	public static function classImplements(path:String):Bool {
		final localClass = Context.getLocalClass();
		if (localClass == null) {
			return false;
		}
		for (iface in localClass.get().interfaces) {
			if (pathKey(iface.t.get().pack, iface.t.get().name) == path) {
				return true;
			}
		}
		return false;
	}

	public static function contractPath(metaName:String):Null<String> {
		final meta = getClassMetadata(metaName);
		if (meta == null) {
			return null;
		}
		if (meta.params == null || meta.params.length != 1) {
			Context.error(metaName + " requires exactly one contract interface argument.", meta.pos);
		}
		return exprToTypePath(meta.params[0]);
	}

	static function getClassMetadata(name:String):Null<MetadataEntry> {
		final localClass = Context.getLocalClass();
		if (localClass == null) {
			return null;
		}

		for (entry in localClass.get().meta.get()) {
			if (entry.name == name) {
				return entry;
			}
		}

		return null;
	}

	static function readContractMethods(expr:Expr, pos:Position, metaName:String):Array<ContractMethod> {
		final path = exprToTypePath(expr);
		final resolved = Context.getType(path);

		return switch (Context.follow(resolved)) {
			case TInst(typeRef, _):
				readContractClass(typeRef.get(), pos, metaName);
			case _:
				Context.error(metaName + " expects an interface contract, got " + path + ".", pos);
				null;
		};
	}

	/**
		Every method of the contract `type`, its own and those of every
		interface it extends, however far up.

		Only its own were read, so a contract built from reusable ones had
		stubs for part of itself, and its handler -- which Haxe made implement
		the rest -- dispatched none of the rest: a call to one arrived as an
		unknown op and closed the connection.

		A parent reached twice, as two contracts extending one base are, gives
		its methods once. A name declared twice with different signatures is
		an error, since on the wire the two would be one method. The type
		parameters of a generic contract are bound to what the extending one
		passes it -- `Repository<String>` reads as methods of `String`.
	**/
	static function readContractClass(type:ClassType, pos:Position, metaName:String, ?typeParams:Array<TypeParameter>,
			?concrete:Array<Type>):Array<ContractMethod> {
		if (!type.isInterface) {
			Context.error(metaName + " expects an interface contract, got " + pathKey(type.pack, type.name) + ".", pos);
		}

		final methods = new Array<ContractMethod>();
		final declaredIn = new Map<String, String>();
		final signatures = new Map<String, String>();
		collectContractMethods(type, typeParams != null ? typeParams : [], concrete != null ? concrete : [], methods, declaredIn, signatures);
		requireDistinctOps([for (method in methods) {name: method.name, pos: method.pos}], true);
		return methods;
	}

	static function collectContractMethods(type:ClassType, typeParams:Array<TypeParameter>, concrete:Array<Type>, methods:Array<ContractMethod>,
			declaredIn:Map<String, String>, signatures:Map<String, String>):Void {
		final owner = pathKey(type.pack, type.name);
		final bind = (t:Type) -> concrete.length > 0 && typeParams.length > 0 ? t.applyTypeParameters(typeParams, concrete) : t;

		for (field in type.fields.get()) {
			switch (Context.follow(bind(field.type))) {
				case TFun(args, ret):
					final signature = args.map(arg -> (arg.opt ? "?" : "") + TypeTools.toString(Context.follow(arg.t))).join(",") + ":"
						+ TypeTools.toString(Context.follow(ret));
					final previous = declaredIn.get(field.name);
					if (previous != null) {
						if (signatures.get(field.name) != signature) {
							Context.error("RPC contract method '" + field.name + "' is declared by both " + previous + " and " + owner
								+ " with different signatures. On the wire they would be one method; rename one.", field.pos);
						}
						continue;
					}
					declaredIn.set(field.name, owner);
					signatures.set(field.name, signature);

					var retType = fullComplexType(ret);
					if (retType == null) {
						retType = macro :Void;
					}
					methods.push({
						name: field.name,
						pos: field.pos,
						args: args.map(arg -> {
							name: arg.name,
							opt: arg.opt,
							type: fullComplexType(arg.t),
							value: null,
							meta: []
						}),
						ret: retType,
						responseType: responsePayloadType(retType, field.pos),
						op: RPCOps.opOf(field.name)
					});
				case _:
					Context.error("RPC contract field '" + field.name + "' must be a function.", field.pos);
			}
		}

		for (parent in type.interfaces) {
			final parentType = parent.t.get();
			collectContractMethods(parentType, parentType.params, parent.params.map(bind), methods, declaredIn, signatures);
		}
	}

	/**
		Fails the build if two of `methods` would share an op on the wire --
		their names hashing alike -- or one would share the built-in `ping`'s,
		which every handler answers whether it declares it or not.
	**/
	/**
		`t` written so that any module can resolve it: typedefs and import
		aliases followed to what they name, since their own names may be
		private to, or only an alias in, the module that used them; `Null<T>`
		kept, since it marks an optional argument on the wire, and a full
		follow drops it. `toComplexType()` alone keeps a typedef's name, so a
		handler or commands class in another module than its contract or its
		parent could not read a type declared through one.
	**/
	public static function fullComplexType(t:Type):ComplexType {
		return switch (t) {
			case TAbstract(ref, [inner]) if (ref.get().name == "Null" && ref.get().pack.length == 0):
				TPath({pack: [], name: "Null", params: [TPType(fullComplexType(inner))]});
			case TType(_, _):
				fullComplexType(Context.follow(t, true));
			case _:
				t.toComplexType();
		}
	}

	/** `ct`, resolved where it was written, as `fullComplexType` writes it; as it was if it does not resolve. **/
	public static function fullType(ct:ComplexType, pos:Position):ComplexType {
		if (ct == null) {
			return null;
		}
		try {
			final full = fullComplexType(Context.resolveType(ct, pos));
			return full != null ? full : ct;
		} catch (_:Dynamic) {
			// Left for the check that reports an unsupported type to report.
			return ct;
		}
	}

	public static function requireDistinctOps(methods:Array<{name:String, pos:Position}>, includePing:Bool):Void {
		final names = [for (method in methods) method.name];
		if (includePing) {
			names.push("ping");
		}
		final clash = RPCOps.firstClash(names);
		if (clash == null) {
			return;
		}
		var at = Context.currentPos();
		for (method in methods) {
			if (method.name == clash[1] || method.name == clash[0]) {
				at = method.pos;
			}
		}
		Context.error("RPC methods '" + clash[0] + "' and '" + clash[1]
			+ "' would share an op on the wire: an op is the hash of a method's name, and theirs hash alike. Rename one.", at);
	}

	static function exprToTypePath(expr:Expr):String {
		return switch (expr.expr) {
			case EConst(CIdent(name)):
				name;
			case EField(owner, field):
				exprToTypePath(owner) + "." + field;
			default:
				Context.error("RPC contract reference must be a type path.", expr.pos);
				"";
		};
	}

	static function responsePayloadType(ret:ComplexType, pos:Position):Null<ComplexType> {
		final resolved = Context.follow(Context.resolveType(ret, pos));
		return switch (resolved) {
			case TAbstract(typeRef, _) if (typeRef.get().name == "Void"):
				null;
			case TInst(typeRef, params) if (typeRef.get().name == "RPCResponse" && typeRef.get().pack.join(".") == "crossbyte.rpc"):
				Context.error("Shared RPC contracts should use plain payload return types. Use T, Future<T> or Void in the contract, not RPCResponse<T>.", pos);
				null;
			case TInst(typeRef, [payload]) if (typeRef.get().name == "Future" && typeRef.get().pack.join(".") == "crossbyte"):
				// Answered later by the handler, and a `T` all the same on the
				// wire and to the caller, whose stub returns RPCResponse<T>.
				fullComplexType(payload);
			case _:
				ret;
		}
	}

	static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}

}

typedef ContractMethod = {
	final name:String;
	final pos:Position;
	final args:Array<FunctionArg>;
	final ret:ComplexType;
	final responseType:Null<ComplexType>;
	final op:Int;
}
#end
