package crossbyte.rpc._internal;

#if macro
import crossbyte.utils.Hash;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCContractMacroTools {
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
				final type = typeRef.get();
				if (!type.isInterface) {
					Context.error(metaName + " expects an interface contract, got " + path + ".", pos);
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
				methods;
			case _:
				Context.error(metaName + " expects an interface contract, got " + path + ".", pos);
				null;
		};
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
				switch (params) {
					case [inner]:
						final payload = inner.toComplexType();
						if (payload == null) {
							Context.error("RPCResponse must declare a payload type.", pos);
						}
						payload;
					case _:
						Context.error("RPCResponse must declare a payload type.", pos);
						null;
				}
			case _:
				Context.error("RPC contract return type must be Void or RPCResponse<T>, got " + ComplexTypeTools.toString(ret) + ".", pos);
				null;
		}
	}

	static inline function isVoid(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath(tp) if (tp.name == "Void"): true;
			case _: false;
		}
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
