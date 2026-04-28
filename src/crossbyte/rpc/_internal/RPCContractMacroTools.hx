package crossbyte.rpc._internal;

#if macro
import crossbyte.utils.Hash;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCContractMacroTools {
	public static inline function isReservedSystemMethod(name:String):Bool {
		return name == "ping";
	}

	public static inline function reservedSystemMethodMessage(name:String):String {
		return "RPC contract method name '" + name + "' is reserved for built-in RPC system traffic.";
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
		return readContractClass(interfaces[0].t.get(), pos, metaName);
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

	static function readContractClass(type:ClassType, pos:Position, metaName:String):Array<ContractMethod> {
		if (!type.isInterface) {
			Context.error(metaName + " expects an interface contract, got " + pathKey(type.pack, type.name) + ".", pos);
		}

		final methods = new Array<ContractMethod>();
		for (field in type.fields.get()) {
			switch (Context.follow(field.type)) {
				case TFun(args, ret):
					var retType = ret.toComplexType();
					if (retType == null) {
						retType = macro :Void;
					}
					methods.push({
						name: field.name,
						pos: field.pos,
						args: args.map(arg -> {
							name: arg.name,
							opt: arg.opt,
							type: arg.t.toComplexType(),
							value: null,
							meta: []
						}),
						ret: retType,
						responseType: responsePayloadType(retType, field.pos),
						op: Hash.fnv1a32(haxe.io.Bytes.ofString(field.name))
					});
				case _:
					Context.error("RPC contract field '" + field.name + "' must be a function.", field.pos);
			}
		}
		return methods;
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
				Context.error("Shared RPC contracts should use plain payload return types. Use T or Void in the contract, not RPCResponse<T>.", pos);
				null;
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
