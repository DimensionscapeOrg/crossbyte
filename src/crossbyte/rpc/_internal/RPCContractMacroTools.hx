package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCKinds;
import crossbyte.utils.Hash;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

using haxe.macro.Tools;

class RPCContractMacroTools {
	public static inline function isReservedSystemMethod(name:String):Bool {
		return name == "ping" || name == "beforeCall" || name == "afterCall" || name == "dispatch" || name == "session"
			|| name == "currentCall" || name == "withTimeout";
	}

	/**
		The class being built, as a type, for a static method of its own to
		take an instance of it; `null` for a class with type parameters,
		whose statics cannot name them.
	**/
	public static function selfType():Null<ComplexType> {
		final local = Context.getLocalClass().get();
		if (local.params.length > 0) {
			return null;
		}
		return TPath({pack: [], name: local.name});
	}

	/**
		`body`, written for a method of the class, made the body of a static
		one taking the instance as `__self`: on the jvm, where Haxe's backend
		reaches every instance method of a class through one generated method
		(`_hx_getField`) whose code grows with each and fails to load past
		32 KB, a static one is not among them.
	**/
	public static function asStatic(body:Expr):Expr {
		function swap(e:Expr):Expr {
			return switch (e.expr) {
				case EConst(CIdent("this")): {expr: EConst(CIdent("__self")), pos: e.pos};
				case _: haxe.macro.ExprTools.map(e, swap);
			}
		}
		return swap(body);
	}

	/**
		The most instance methods and variables a class can hold on the jvm,
		with room to spare: Haxe's jvm backend reaches every one of a class's
		own through one generated method, about 45 bytes of code each, and a
		method past 32 KB fails to load. Inherited ones are their class's.
	**/
	public static inline final JVM_MAX_FIELDS:Int = 640;

	/**
		Fails a jvm build whose class would not load: `what` (an RPC commands
		class, an RPC handler) holding more than `JVM_MAX_FIELDS` methods and
		variables of its own in `fields`.
	**/
	public static function requireJvmSize(fields:Array<Field>, what:String):Void {
		if (!Context.defined("jvm")) {
			return;
		}
		var count:Int = 0;
		for (field in fields) {
			final access = field.access != null ? field.access : [];
			if (access.indexOf(AStatic) < 0 && access.indexOf(AExtern) < 0) {
				count++;
			}
		}
		if (count > JVM_MAX_FIELDS) {
			Context.error("This " + what + " has " + count + " methods and variables of its own; on the jvm a class can hold about " + JVM_MAX_FIELDS
				+ " (Haxe's jvm backend reaches them through one method, which fails to load past 32 KB). Split its contract: a contract can extend others, and an RPC commands class or handler can extend another, each holding its own part.",
				Context.currentPos());
		}
	}

	public static inline function reservedSystemMethodMessage(name:String):String {
		return name == "ping" ? "RPC contract method name '" + name + "' is reserved for built-in RPC system traffic." : "RPC contract method name '"
			+ name + "' is reserved: " + (name == "withTimeout" ? "RPCCommands" : "RPCHandler") + " declares it.";
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

		So a contract built from reusable ones has stubs for all of itself,
		and its handler (which Haxe makes implement the rest) dispatches all
		of it, rather than a call to an inherited method arriving as an
		unknown op.

		A parent reached twice, as two contracts extending one base are, gives
		its methods once. A name declared twice with different signatures is
		an error, since on the wire the two would be one method. The type
		parameters of a generic contract are bound to what the extending one
		passes it: `Repository<String>` reads as methods of `String`.
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
		requireDistinctOps([for (method in methods) {name: method.name, op: method.op, pos: method.pos}], true);
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
					final methodArgs:Array<FunctionArg> = args.map(arg -> ({
						name: arg.name,
						opt: arg.opt,
						type: fullComplexType(arg.t),
						value: null,
						meta: []
					} : FunctionArg));
					final responseType = responsePayloadType(retType, field.pos);
					methods.push({
						name: field.name,
						pos: field.pos,
						args: methodArgs,
						ret: retType,
						responseType: responseType,
						op: opOfMethod(field.name, methodArgs, responseType, field.pos)
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
		Fails the build if two of `methods` would share an op on the wire
		(their names hashing alike), or one would share the built-in `ping`'s,
		which every handler answers whether it declares it or not.
	**/
	/**
		`t` written so that any module can resolve it: typedefs and import
		aliases followed to what they name, since their own names may be
		private to, or only an alias in, the module that used them; `Null<T>`
		kept, since it marks an optional argument on the wire, and a full
		follow drops it. `toComplexType()` alone keeps a typedef's name, so with it alone a
		handler or commands class in another module than its contract or its
		parent could not read a type declared through one.
	**/
	public static function fullComplexType(t:Type):ComplexType {
		return fullComplexTypeWithin(t, []);
	}

	/**
		`fullComplexType`, all the way down: the parameters of a type (an
		`Array`'s element) and the fields of an anonymous structure written
		the same way, since they are read in the same other module. A
		typedef met again inside itself (a structure that holds itself,
		which the lane refuses) keeps its name, rather than going on for
		ever.
	**/
	static function fullComplexTypeWithin(t:Type, within:Array<String>):ComplexType {
		return switch (t) {
			case TAbstract(ref, [inner]) if (ref.get().name == "Null" && ref.get().pack.length == 0):
				TPath({pack: [], name: "Null", params: [TPType(fullComplexTypeWithin(inner, within))]});
			case TType(ref, _):
				final key:String = TypeTools.toString(t);
				if (within.indexOf(key) >= 0) {
					t.toComplexType();
				} else {
					fullComplexTypeWithin(Context.follow(t, true), within.concat([key]));
				}
			case TLazy(lazy):
				fullComplexTypeWithin(lazy(), within);
			case TMono(ref) if (ref.get() != null):
				fullComplexTypeWithin(ref.get(), within);
			case TInst(ref, params) if (params.length > 0):
				withParams(t.toComplexType(), params, within);
			case TAbstract(ref, params) if (params.length > 0):
				withParams(t.toComplexType(), params, within);
			case TAnonymous(anon):
				TAnonymous([
					for (field in anon.get().fields)
						({
							name: field.name,
							meta: field.meta.get(),
							kind: FVar(fullComplexTypeWithin(field.type, within), null),
							pos: field.pos,
							access: []
						} : Field)
				]);
			case _:
				t.toComplexType();
		}
	}

	/** `ct`, a path, with `params` written as `fullComplexType` writes them. **/
	static function withParams(ct:ComplexType, params:Array<Type>, within:Array<String>):ComplexType {
		return switch (ct) {
			case TPath(path):
				TPath({
					pack: path.pack,
					name: path.name,
					sub: path.sub,
					params: [for (param in params) TPType(fullComplexTypeWithin(param, within))]
				});
			case _:
				ct;
		}
	}

	/**
		Whether a value of `ct` may be absent (`Null<T>`, however it is
		named), so that on the wire it is a byte saying whether it is there
		and then, if it is, the value.

		Decided on the type and not on how it is written: the side that
		answers and the side that reads the answer must agree, and one may
		name through a typedef what the other writes out.
	**/
	public static function isNullable(ct:ComplexType, pos:Position):Bool {
		if (ct == null) {
			return false;
		}
		switch (ct) {
			case TPath({name: "Null", pack: [], params: [_]}):
				return true;
			case _:
		}
		var type:Null<Type> = try Context.resolveType(ct, pos) catch (_:Dynamic) null;
		while (type != null) {
			switch (type) {
				case TAbstract(ref, [_]) if (ref.get().name == "Null" && ref.get().pack.length == 0):
					return true;
				case TType(_, _):
					// One typedef at a time: a full follow drops the Null.
					type = Context.follow(type, true);
				case TMono(ref):
					type = ref.get();
				case TLazy(lazy):
					type = lazy();
				case _:
					return false;
			}
		}
		return false;
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

	public static function requireDistinctOps(methods:Array<{name:String, op:Int, pos:Position}>, includePing:Bool):Void {
		final byOp:Map<Int, String> = new Map();
		if (includePing) {
			byOp.set(RPCOps.opOf("ping"), "ping");
		}
		for (method in methods) {
			final other:Null<String> = byOp.get(method.op);
			if (other == null) {
				byOp.set(method.op, method.name);
			} else if (other != method.name) {
				Context.error("RPC methods '" + other + "' and '" + method.name
					+ "' would share an op on the wire: an op is the hash of a method's signature, and theirs hash alike. Rename one.", method.pos);
			}
		}
	}

	/**
		The op of a compiled method: the hash of its signature (see `RPCOps`),
		or of `ping`'s name alone. `answer` is the type it is answered with:
		`T`, for a method answering with `Future<T>`, or `null` for a
		one-way method.
	**/
	public static function opOfMethod(name:String, args:Array<FunctionArg>, answer:Null<ComplexType>, pos:Position):Int {
		if (name == "ping") {
			return RPCOps.opOf("ping");
		}
		return RPCOps.opOf(signatureOf(name, args, answer, pos));
	}

	/** A compiled method's signature, as `RPCOps` describes it. **/
	public static function signatureOf(name:String, args:Array<FunctionArg>, answer:Null<ComplexType>, pos:Position):String {
		final kinds = new Array<String>();
		if (args != null) {
			for (arg in args) {
				kinds.push(tokenOf(arg.type, arg.opt || isNullable(arg.type, pos), pos));
			}
		}
		final answerToken:Null<String> = answer == null ? null : tokenOf(answer, isNullable(answer, pos), pos);
		return RPCOps.signature(name, kinds, answerToken);
	}

	/**
		The token of a value of type `ct` in a signature. A type the lane does
		not carry is named for itself, and refused, naming the method, where
		its reader or writer is made.
	**/
	static function tokenOf(ct:ComplexType, optional:Bool, pos:Position):String {
		if (ct == null) {
			return "?";
		}
		final base = RPCKinds.unwrapNull(ct);
		final kind = RPCKinds.of(base, pos);
		return kind != null ? RPCKinds.token(kind, optional) : (optional ? "?" : "") + RPCKinds.nameOf(base, pos);
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
