package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
#if macro
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCCommandMacro {
	private static function initWriters():Map<String, (Expr, Expr) -> Expr> {
		var m = new Map<String, (Expr, Expr) -> Expr>();

		m.set("Int", function(out, v) return macro {
			$out.reserve(4);
			$out.writeInt($v);
		});
		m.set("Bool", function(out, v) return macro {
			$out.reserve(1);
			$out.writeByte($v ? 1 : 0);
		});
		m.set("Float", function(out, v) return macro {
			$out.reserve(8);
			$out.writeDouble($v);
		});
		m.set("String", function(out, v) return macro {
			$out.writeVarUTF($v);
		});
		m.set("haxe.io.Bytes", function(out, v) return macro {
			$out.writeVarUInt($v.length);
			$out.reserve($v.length);
			$out.writeBytes($v, 0, $v.length);
		});

		return m;
	}

	private static function initReaders():Map<String, Expr->Expr> {
		var m = new Map<String, Expr->Expr>();
		m.set("Int", inp -> macro $inp.readInt());
		m.set("Bool", inp -> macro($inp.readByte() != 0));
		m.set("Float", inp -> macro $inp.readDouble());
		m.set("String", inp -> macro $inp.readVarUTF());
		m.set("haxe.io.Bytes", inp -> macro {
			var __len = $inp.readVarUInt();
			var __bytes = haxe.io.Bytes.alloc(__len);
			$inp.readBytes(__bytes, 0, __len);
			__bytes;
		});
		return m;
	}

	private static final TYPE_WRITERS:Map<String, (Expr, Expr) -> Expr> = initWriters();
	private static final TYPE_READERS:Map<String, Expr->Expr> = initReaders();

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var newFields:Array<Field> = [];
		var responseMethods:Array<ResponseMethod> = [];

		for (field in fields) {
			if (field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0) {
				switch (field.kind) {
					case FFun(method):
						var metaName = "meta_" + field.name;
						var retType = method.ret != null ? method.ret : macro :Void;
						var responseType = responsePayloadType(retType, field.pos);
						var opCode:Int = Hash.fnv1a32(haxe.io.Bytes.ofString(field.name));

						field.kind = createWrapperFunction(field, metaName, method.args, retType, responseType, opCode).kind;
						newFields.push(createMetaFunction(metaName, field.name, method.args, field.pos, opCode));

						if (responseType != null) {
							responseMethods.push({
								name: field.name,
								op: opCode,
								responseType: responseType,
								pos: field.pos
							});
						}
					default:
						Context.error("Field " + field.name + " is marked as :rpc but is not a function.", field.pos);
				}
			}
		}

		injectPing(newFields, Context.currentPos());
		injectResponseHandler(newFields, responseMethods);

		return fields.concat(newFields);
	}

	private static function createMetaFunction(metaName:String, commandName:String, args:Array<FunctionArg>, errPos:Position, opCode:Int):Field {
		var statements:Array<Expr> = [];
		statements.push(macro var payload:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(crossbyte.rpc._internal.RPCWire.MIN_PAYLOAD_LEN));
		statements.push(macro {
			payload.writeByte(requestId != 0 ? crossbyte.rpc._internal.RPCWire.FLAG_REQUEST : 0);
			payload.writeInt($v{opCode});
			if (requestId != 0) {
				payload.writeVarUInt(requestId);
			}
		});

		for (i in 0...args.length) {
			statements.push(writerForArg(args[i], errPos));
		}

		statements.push(macro payload.flush());
		statements.push(macro var framed:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(payload.length + 4));
		statements.push(macro framed.writeInt(payload.length));
		statements.push(macro framed.writeBytes(payload));
		statements.push(macro connection.send(framed));

		return {
			name: metaName,
			doc: "Auto-generated RPC meta for " + commandName,
			access: [APrivate, AInline],
			kind: FFun({
				args: [
					{name: "connection", type: macro :crossbyte.net.INetConnection},
					{name: "requestId", type: macro :Int}
				].concat(args),
				expr: macro {$b{statements};},
				ret: macro :Void
			}),
			pos: Context.currentPos()
		};
	}

	private static function createWrapperFunction(field:Field, metaName:String, args:Array<FunctionArg>, retType:ComplexType,
			responseType:Null<ComplexType>, opCode:Int):Field {
		var argExprs = args.map(a -> macro $i{a.name});
		var expr:Expr = if (responseType == null) {
			macro $i{metaName}($a{[macro this.__nc, macro 0].concat(argExprs)});
		} else {
			macro {
				var response:$retType = this.__createResponse($v{opCode});
				$i{metaName}($a{[macro this.__nc, macro response.requestId].concat(argExprs)});
				return response;
			};
		}

		return {
			name: field.name,
			doc: "Replaced existing method with auto-generated RPC wrapper for: " + field.name,
			access: field.access.concat([AInline]),
			kind: FFun({
				args: args,
				expr: expr,
				ret: retType
			}),
			pos: field.pos
		};
	}

	private static function writerForArg(a:FunctionArg, errPos:Position):Expr {
		var ct:ComplexType = a.type;
		if (ct == null) {
			Context.error("RPC arg '" + a.name + "' must have an explicit type.", errPos);
		}

		var isOpt = a.opt || isNullWrapped(ct);
		var base = unwrapNull(ct);
		var key = typeKey(base, errPos);

		var fn = TYPE_WRITERS.get(key);
		if (fn == null) {
			Context.error("Unsupported RPC arg type for '" + a.name + "': " + key, errPos);
		}

		var valueExpr:Expr = macro $i{a.name};
		var writeValue:Expr = fn(macro payload, valueExpr);

		return isOpt ? macro {
			payload.reserve(1);
			if ($valueExpr == null) {
				payload.writeByte(0);
			} else {
				payload.writeByte(1);
				$writeValue;
			}
		} : writeValue;
	}

	private static function readerForType(ct:ComplexType, errPos:Position):Expr {
		var isOpt = isNullWrapped(ct);
		var base = unwrapNull(ct);
		var key = typeKey(base, errPos);
		var fn = TYPE_READERS.get(key);
		if (fn == null) {
			Context.error("Unsupported RPC response type: " + key, errPos);
		}

		var read = fn(macro input);
		return isOpt ? macro(input.readByte() != 0 ? $read : null) : read;
	}

	private static function injectResponseHandler(newFields:Array<Field>, methods:Array<ResponseMethod>):Void {
		var cases:Array<Case> = [];
		for (method in methods) {
			var read = readerForType(method.responseType, method.pos);
			cases.push({
				values: [macro $v{method.op}],
				expr: macro {
					if (failed) {
						this.__rejectResponse(requestId, input.readVarUTF());
					} else {
						var value = $read;
						this.__resolveResponse(requestId, value);
					}
					return;
				}
			});
		}

		var defaultExpr:Expr = macro {
			if (failed) {
				this.__rejectResponse(requestId, input.readVarUTF());
			} else {
				this.__rejectUnknownResponse(requestId, op);
			}
		};

		newFields.push({
			name: "__rpc_handle_response",
			access: [APublic, AInline],
			kind: FFun({
				args: [
					{name: "op", type: macro :Int},
					{name: "requestId", type: macro :Int},
					{name: "input", type: macro :crossbyte.io.ByteArrayInput},
					{name: "failed", type: macro :Bool}
				],
				expr: {
					expr: ESwitch(macro op, cases, defaultExpr),
					pos: Context.currentPos()
				},
				ret: macro :Void
			}),
			pos: Context.currentPos()
		});
	}

	private static function responsePayloadType(ret:ComplexType, pos:Position):Null<ComplexType> {
		if (isVoid(ret)) {
			return null;
		}

		return switch (ret) {
			case TPath(tp) if ((tp.name == "RPCResponse" || tp.name == "RPCResonse") && (tp.pack.length == 0 || tp.pack.join(".") == "crossbyte.rpc")):
				switch (tp.params) {
					case [TPType(inner)]: inner;
					case _: Context.error("RPCResponse must declare a payload type.", pos);
				}
			case _:
				Context.error("RPC command return type must be Void or RPCResponse<T>.", pos);
				null;
		}
	}

	private static inline function isVoid(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath({pack: [], name: "Void"}): true;
			case _: false;
		}
	}

	private static inline function isNullWrapped(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath({name: "Null", params: _}): true;
			case _: false;
		}
	}

	private static inline function unwrapNull(ct:ComplexType):ComplexType {
		return switch (ct) {
			case TPath({name: "Null", params: [TPType(inner)]}): inner;
			case _: ct;
		}
	}

	private static function typeKey(ct:ComplexType, pos:Position):String {
		try {
			return resolvedTypeKey(Context.resolveType(ct, pos));
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

	private static function resolvedTypeKey(type:Type):String {
		return switch (Context.follow(type)) {
			case TAbstract(t, _):
				pathKey(t.get().pack, t.get().name);
			case TInst(t, _):
				pathKey(t.get().pack, t.get().name);
			case TType(t, _):
				pathKey(t.get().pack, t.get().name);
			case _:
				Std.string(type);
		}
	}

	private static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}

	private static function injectPing(newFields:Array<Field>, pos:Position):Void {
		var pingName = "ping";
		var metaName = "meta_ping";
		var args:Array<FunctionArg> = [];
		var opCode:Int = Hash.fnv1a32(haxe.io.Bytes.ofString(pingName));

		var wrapper = createWrapperFunction({
			name: pingName,
			access: [APublic],
			kind: FFun({
				args: null,
				ret: macro :Void,
				expr: null
			}),
			pos: pos,
			meta: null,
			doc: "System reserved RPC ping()."
		}, metaName, args, macro :Void, null, opCode);

		var meta = createMetaFunction(metaName, pingName, args, pos, opCode);

		newFields.push(wrapper);
		newFields.push(meta);
	}
}

private typedef ResponseMethod = {
	name:String,
	op:Int,
	responseType:ComplexType,
	pos:Position
}
#end
