package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
#if macro
import crossbyte.rpc._internal.RPCContractMacroTools;
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

	// Each reads from `inp`, in a frame that ends at `end`.
	private static function initReaders():Map<String, (Expr, Expr) -> Expr> {
		var m = new Map<String, (Expr, Expr) -> Expr>();
		m.set("Int", (inp, end) -> macro $inp.readInt());
		m.set("Bool", (inp, end) -> macro($inp.readByte() != 0));
		m.set("Float", (inp, end) -> macro $inp.readDouble());
		m.set("String", (inp, end) -> macro $inp.readVarUTF());
		m.set("haxe.io.Bytes", (inp, end) -> macro {
			var __len:Int = $inp.readVarUInt();
			crossbyte.rpc._internal.RPCWire.requireRoom($inp, $end, __len);
			var __bytes = haxe.io.Bytes.alloc(__len);
			$inp.readBytes(__bytes, 0, __len);
			__bytes;
		});
		return m;
	}

	private static final TYPE_WRITERS:Map<String, (Expr, Expr) -> Expr> = initWriters();
	private static final TYPE_READERS:Map<String, (Expr, Expr) -> Expr> = initReaders();

	// On a generated __rpc_handle_response(), for a commands class that
	// extends this one: the name of every method this class sends, and the
	// name and type of every response it reads.
	static inline final COMMANDS_META:String = ":rpcCommands";
	static inline final RESPONDS_META:String = ":rpcResponds";

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var newFields:Array<Field> = [];
		var responseMethods:Array<ResponseMethod> = [];
		// The commands classes between this one and RPCCommands, nearest first.
		final ancestors = commandsAncestors();
		final sentNames = new Array<String>();
		final contractMethods = RPCContractMacroTools.getContractMethods(":rpcContract");
		final manualRpcFields = fields.filter(field -> field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0);

		if (contractMethods != null) {
			RPCContractMacroTools.requireExtends(":rpcContract", "crossbyte.rpc.RPCCommands");
			final contractPath = RPCContractMacroTools.contractPath(":rpcContract");
			if (contractPath != null && RPCContractMacroTools.classImplements(contractPath)) {
				Context.error("RPC commands classes should not implement the shared contract directly. Use @:rpcContract(...) to generate command stubs, and let the handler implement the contract interface.", Context.currentPos());
			}
			if (manualRpcFields.length > 0) {
				Context.error("Do not mix @:rpcContract(...) with field-level @:rpc methods in the same class.", manualRpcFields[0].pos);
			}

			for (method in contractMethods) {
				if (RPCContractMacroTools.isReservedSystemMethod(method.name)) {
					Context.error(RPCContractMacroTools.reservedSystemMethodMessage(method.name), method.pos);
				}
				// A commands class this one extends already sends it, from
				// the contract this one's extends; its response is read below.
				if (ancestorField(ancestors, method.name) != null) {
					continue;
				}
				sentNames.push(method.name);
				if (hasFieldNamed(fields, method.name) || hasFieldNamed(fields, "meta_" + method.name)) {
					Context.error("RPC commands class already declares '" + method.name + "'; remove the manual declaration when using @:rpcContract(...).", method.pos);
				}

				final metaName = "meta_" + method.name;
				final wrapperReturnType = commandReturnType(method.ret);
				final wrapper = createWrapperFunction({
					name: method.name,
					doc: "Generated RPC wrapper for contract method " + method.name,
					access: [APublic],
					kind: FFun({
						args: method.args,
						ret: wrapperReturnType,
						expr: null
					}),
					pos: method.pos,
					meta: null
				}, metaName, method.args, wrapperReturnType, method.responseType, method.op);
				newFields.push(wrapper);
				newFields.push(createMetaFunction(metaName, method.name, method.args, method.pos, method.op));

				if (method.responseType != null) {
					responseMethods.push({
						name: method.name,
						op: method.op,
						responseType: method.responseType,
						pos: method.pos
					});
				}
			}

			return finish(fields, newFields, responseMethods, sentNames, ancestors);
		}


		for (field in fields) {
			if (field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0) {
				switch (field.kind) {
					case FFun(method):
						sentNames.push(field.name);
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

		return finish(fields, newFields, responseMethods, sentNames, ancestors);
	}

	/**
		What every commands class ends with: `ping`, unless a class it extends
		made one, and the reader of responses -- for this class's methods and
		for every one it inherits, which it overrides. Each class made both
		again, which Haxe refused in a subclass, so no commands class could
		extend another.
	**/
	private static function finish(fields:Array<Field>, newFields:Array<Field>, responseMethods:Array<ResponseMethod>, sentNames:Array<String>,
			ancestors:Array<ClassType>):Array<Field> {
		final inheritedSent = inheritedNames(ancestors, COMMANDS_META);
		final allSent = sentNames.concat([for (name in inheritedSent) if (sentNames.indexOf(name) < 0) name]);
		RPCContractMacroTools.requireDistinctOps([for (name in allSent) {name: name, pos: Context.currentPos()}], true);

		for (inherited in inheritedResponses(ancestors)) {
			if (!Lambda.exists(responseMethods, method -> method.name == inherited.name)) {
				responseMethods.push(inherited);
			}
		}

		if (ancestorField(ancestors, "ping") == null) {
			injectPing(newFields, Context.currentPos());
		}
		injectResponseHandler(newFields, responseMethods, allSent, ancestorField(ancestors, "__rpc_handle_response") != null);
		return fields.concat(newFields);
	}

	/** The commands classes this one extends, nearest first, up to RPCCommands. **/
	private static function commandsAncestors():Array<ClassType> {
		final ancestors = new Array<ClassType>();
		var parent = Context.getLocalClass().get().superClass;
		while (parent != null) {
			final type = parent.t.get();
			if (type.pack.join(".") == "crossbyte.rpc" && type.name == "RPCCommands") {
				break;
			}
			ancestors.push(type);
			parent = type.superClass;
		}
		return ancestors;
	}

	private static function ancestorField(ancestors:Array<ClassType>, name:String):Null<ClassField> {
		for (type in ancestors) {
			for (field in type.fields.get()) {
				if (field.name == name) {
					return field;
				}
			}
		}
		return null;
	}

	/** The names the nearest ancestor's response reader recorded under `meta`. **/
	private static function inheritedNames(ancestors:Array<ClassType>, meta:String):Array<String> {
		final reader = ancestorField(ancestors, "__rpc_handle_response");
		final names = new Array<String>();
		if (reader == null) {
			return names;
		}
		for (entry in reader.meta.extract(meta)) {
			for (param in entry.params) {
				switch (param.expr) {
					case EConst(CString(name)):
						names.push(name);
					default:
				}
			}
		}
		return names;
	}

	/**
		The responses the nearest ancestor's reader reads, as it recorded them.
		Read from there, untyped, never from the ancestor's stubs: following a
		stub's type during this class's build types it there and then, before
		the classes it names have finished building.
	**/
	private static function inheritedResponses(ancestors:Array<ClassType>):Array<ResponseMethod> {
		final reader = ancestorField(ancestors, "__rpc_handle_response");
		final responses = new Array<ResponseMethod>();
		if (reader == null) {
			return responses;
		}
		for (entry in reader.meta.extract(RESPONDS_META)) {
			for (param in entry.params) {
				switch (param.expr) {
					case EFunction(FNamed(name, _), fn) if (fn.ret != null):
						responses.push({
							name: name,
							op: RPCOps.opOf(name),
							responseType: fn.ret,
							pos: param.pos
						});
					default:
				}
			}
		}
		return responses;
	}

	/**
		A response as a commands class extending this one reads it: a function
		expression, never typed, returning the response's type written out in
		full. That class reads it in its own module, which need not import, nor
		see the typedefs of, this one's.
	**/
	private static function responseSignature(method:ResponseMethod):Expr {
		return {
			expr: EFunction(FNamed(method.name, false), {args: [], ret: RPCContractMacroTools.fullType(method.responseType, method.pos), expr: null}),
			pos: method.pos
		};
	}

	private static function createMetaFunction(metaName:String, commandName:String, args:Array<FunctionArg>, errPos:Position, opCode:Int):Field {
		var statements:Array<Expr> = [];
		statements.push(macro var framed:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(crossbyte.rpc._internal.RPCWire.MIN_PAYLOAD_LEN + 4));
		statements.push(macro framed.writeInt(0));
		statements.push(macro {
			framed.writeByte(requestId != 0 ? crossbyte.rpc._internal.RPCWire.FLAG_REQUEST : 0);
			framed.writeInt($v{opCode});
			if (requestId != 0) {
				framed.writeVarUInt(requestId);
			}
		});

		for (i in 0...args.length) {
			statements.push(writerForArg(args[i], errPos));
		}

		statements.push(macro framed.writeIntAt(0, framed.bytesWritten - 4));
		statements.push(macro framed.flush());
		statements.push(macro connection.send(framed));

		return {
			name: metaName,
			doc: "Auto-generated RPC meta for " + commandName,
			access: [APrivate, AInline],
			kind: FFun({
				args: [
					{name: "connection", type: macro :crossbyte.net.NetConnection},
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
		var writeValue:Expr = fn(macro framed, valueExpr);

		return isOpt ? macro {
			framed.reserve(1);
			if ($valueExpr == null) {
				framed.writeByte(0);
			} else {
				framed.writeByte(1);
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

		var read = fn(macro input, macro this.__frameEnd);
		return isOpt ? macro(input.readByte() != 0 ? $read : null) : read;
	}

	private static function injectResponseHandler(newFields:Array<Field>, methods:Array<ResponseMethod>, sent:Array<String>, overridesInherited:Bool):Void {
		var cases:Array<Case> = [];
		for (method in methods) {
			var read = readerForType(method.responseType, method.pos);
			cases.push({
				values: [macro $v{method.op}],
				expr: macro {
					// Read whole and within the frame before the caller is
					// answered with it.
					if (failed) {
						var message = input.readVarUTF();
						crossbyte.rpc._internal.RPCWire.requireWithin(input, this.__frameEnd);
						this.__rejectResponse(requestId, message);
					} else {
						var value = $read;
						crossbyte.rpc._internal.RPCWire.requireWithin(input, this.__frameEnd);
						this.__resolveResponse(requestId, value);
					}
					return;
				}
			});
		}

		var defaultExpr:Expr = macro {
			if (failed) {
				var message = input.readVarUTF();
				crossbyte.rpc._internal.RPCWire.requireWithin(input, this.__frameEnd);
				this.__rejectResponse(requestId, message);
			} else {
				this.__rejectUnknownResponse(requestId, op);
			}
		};

		// Never inline: it is reached through RPCCommands' abstract method in
		// any case, and a subclass must be able to override it.
		newFields.push({
			name: "__rpc_handle_response",
			access: overridesInherited ? [APublic, AOverride] : [APublic],
			meta: [
				{name: COMMANDS_META, params: [for (name in sent) macro $v{name}], pos: Context.currentPos()},
				{name: RESPONDS_META, params: [for (method in methods) responseSignature(method)], pos: Context.currentPos()}
			],
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
				Context.error("RPC command return type must be Void or RPCResponse<T>.", pos);
				null;
		}
	}

	private static function commandReturnType(ret:ComplexType):ComplexType {
		return if (isVoid(ret)) {
			macro :Void;
		} else {
			TPath({
				pack: ["crossbyte", "rpc"],
				name: "RPCResponse",
				params: [TPType(ret)]
			});
		}
	}

	private static inline function isVoid(ct:ComplexType):Bool {
		return switch (Context.follow(Context.resolveType(ct, Context.currentPos()))) {
			case TAbstract(typeRef, _) if (typeRef.get().name == "Void"): true;
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

	private static function hasFieldNamed(fields:Array<Field>, name:String):Bool {
		for (field in fields) {
			if (field.name == name) {
				return true;
			}
		}
		return false;
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
			doc: "Built-in RPC heartbeat ping(). Do not include this in shared RPC contracts."
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
