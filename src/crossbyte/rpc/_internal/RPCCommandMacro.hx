package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
#if macro
import crossbyte.rpc._internal.RPCContractMacroTools;
import crossbyte.rpc._internal.RPCKinds;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCCommandMacro {
	// On a generated __rpc_handle_response(), for a commands class that
	// extends this one: the signature of every method this class sends (see
	// RPCOps), and the name, arguments and answer of every response it reads.
	static inline final COMMANDS_META:String = ":rpcCommands";
	static inline final RESPONDS_META:String = ":rpcResponds";

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var newFields:Array<Field> = [];
		var responseMethods:Array<ResponseMethod> = [];
		// The commands classes between this one and RPCCommands, nearest first.
		final ancestors = commandsAncestors();
		// The signature of each method this class sends.
		final sent = new Array<String>();
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
				sent.push(RPCContractMacroTools.signatureOf(method.name, method.args, method.responseType, method.pos));
				if (hasFieldNamed(fields, method.name) || hasFieldNamed(fields, "meta_" + method.name)) {
					Context.error("RPC commands class already declares '" + method.name + "'; remove the manual declaration when using @:rpcContract(...).", method.pos);
				}

				final metaName = "meta_" + method.name;
				// From the answer's type, which a contract method returning
				// Future<T> (answered later by its handler) has as T.
				final wrapperReturnType = commandReturnType(method.responseType != null ? method.responseType : macro :Void);
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
				if (method.responseType != null && !isVoid(method.responseType)) {
					requireReceiverNameFree(fields, contractMethods.map(m -> m.name), ancestors, method.name, method.pos);
					newFields.push(createReceiverFunction(method.name, metaName, method.args, method.responseType, method.op, method.pos));
				}

				if (method.responseType != null) {
					responseMethods.push({
						name: method.name,
						op: method.op,
						args: method.args,
						responseType: method.responseType,
						pos: method.pos
					});
				}
			}

			return finish(fields, newFields, responseMethods, sent, ancestors);
		}


		for (field in fields) {
			if (field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0) {
				switch (field.kind) {
					case FFun(method):
						var metaName = "meta_" + field.name;
						var retType = method.ret != null ? method.ret : macro :Void;
						var responseType = responsePayloadType(retType, field.pos);
						// Its signature's hash: its name, and the kinds of its
						// arguments and its answer.
						final signature:String = RPCContractMacroTools.signatureOf(field.name, method.args, responseType, field.pos);
						sent.push(signature);
						var opCode:Int = RPCOps.opOf(signature);

						field.kind = createWrapperFunction(field, metaName, method.args, retType, responseType, opCode).kind;
						newFields.push(createMetaFunction(metaName, field.name, method.args, field.pos, opCode));
						if (responseType != null) {
							requireReceiverNameFree(fields, [for (other in manualRpcFields) other.name], ancestors, field.name, field.pos);
							newFields.push(createReceiverFunction(field.name, metaName, method.args, responseType, opCode, field.pos));
						}

						if (responseType != null) {
							responseMethods.push({
								name: field.name,
								op: opCode,
								args: method.args,
								responseType: responseType,
								pos: field.pos
							});
						}
					default:
						Context.error("Field " + field.name + " is marked as :rpc but is not a function.", field.pos);
				}
			}
		}

		return finish(fields, newFields, responseMethods, sent, ancestors);
	}

	/**
		What every commands class ends with: `ping`, unless a class it extends
		made one, and the reader of responses, for this class's methods and
		for every one it inherits, which it overrides. Made in each class
		again, both would be refused by Haxe in a subclass, and no commands
		class could extend another.
	**/
	private static function finish(fields:Array<Field>, newFields:Array<Field>, responseMethods:Array<ResponseMethod>, sent:Array<String>,
			ancestors:Array<ClassType>):Array<Field> {
		final sentNames = sent.map(nameIn);
		final allSent = sent.concat([for (signature in inheritedNames(ancestors, COMMANDS_META)) if (sentNames.indexOf(nameIn(signature)) < 0) signature]);
		RPCContractMacroTools.requireDistinctOps([
			for (signature in allSent)
				{name: nameIn(signature), op: RPCOps.opOf(signature), pos: Context.currentPos()}
		], true);

		for (inherited in inheritedResponses(ancestors)) {
			if (!Lambda.exists(responseMethods, method -> method.name == inherited.name)) {
				responseMethods.push(inherited);
			}
		}

		if (ancestorField(ancestors, "ping") == null) {
			injectPing(newFields, Context.currentPos());
		}
		injectResponseHandler(newFields, responseMethods, allSent, ancestorField(ancestors, "__rpc_handle_response") != null);
		newFields.push(fingerprintField(allSent.map(RPCOps.opOf)));
		return fields.concat(newFields);
	}

	/** `__rpc_fingerprint`, answering the fingerprint of `ops`, worked out here. **/
	public static function fingerprintField(ops:Array<Int>):Field {
		return {
			name: "__rpc_fingerprint",
			access: [APublic, AOverride],
			meta: [{name: ":noCompletion", params: [], pos: Context.currentPos()}],
			kind: FFun({
				args: [],
				ret: macro :Int,
				expr: macro return $v{RPCOps.fingerprint(ops)}
			}),
			pos: Context.currentPos()
		};
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

	/** The method a signature names: what comes before its arguments. **/
	private static function nameIn(signature:String):String {
		final at:Int = signature.indexOf("(");
		return at < 0 ? signature : signature.substr(0, at);
	}

	/** The strings the nearest ancestor's response reader recorded under `meta`. **/
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
							op: RPCContractMacroTools.opOfMethod(name, fn.args, fn.ret, param.pos),
							args: fn.args,
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
		expression, never typed, taking the call's arguments and returning the
		response's type, every type written out in full (the arguments are
		in its op). That class reads it in its own module, which need not
		import, nor see the typedefs of, this one's.
	**/
	private static function responseSignature(method:ResponseMethod):Expr {
		return {
			expr: EFunction(FNamed(method.name, false), {
				args: [
					for (arg in method.args)
						({
							name: arg.name,
							opt: arg.opt,
							type: RPCContractMacroTools.fullType(arg.type, method.pos),
							value: null,
							meta: []
						} : FunctionArg)
				],
				ret: RPCContractMacroTools.fullType(method.responseType, method.pos),
				expr: null
			}),
			pos: method.pos
		};
	}

	private static function createMetaFunction(metaName:String, commandName:String, args:Array<FunctionArg>, errPos:Position, opCode:Int):Field {
		// Begun with room for the most the frame can hold: its length, flags
		// and op, the request id at its longest, each fixed-size argument's
		// bytes, and for a string or bytes what its length allows. Sized from
		// the arguments before anything is framed, which is where a value that
		// cannot be sent (a null String) is refused.
		var fixed:Int = FRAME_HEAD;
		var sized:Null<Expr> = null;
		final writes:Array<Expr> = [];
		var compound:Bool = false;
		for (a in args) {
			if (a.type == null) {
				Context.error("RPC arg '" + a.name + "' must have an explicit type.", errPos);
			}
			final kind = argKind(a, errPos);
			final optional:Bool = argOptional(a, errPos);
			final name:Expr = macro $i{a.name};
			final size:Int = RPCKinds.size(kind, optional);
			if (size >= 0) {
				fixed += size;
			} else {
				final room:Expr = RPCKinds.room(kind, optional, name);
				sized = sized == null ? room : macro $sized + $room;
			}
			writes.push(RPCKinds.write(kind, optional, macro framed, name));
			compound = compound || kind.compound;
		}
		final room:Expr = sized == null ? macro $v{fixed} : macro $v{fixed} + $sized;

		// The frame, which the stub hands to RPCCommands to send: one place
		// decides what becomes of a call that cannot go. It is its session's,
		// written over by its next frame once this one is sent.
		final statements:Array<Expr> = [macro var framed:crossbyte.rpc._internal.RPCFrame = this.__startFrame($room, $v{opCode}, requestId)];
		if (compound) {
			// An array or a structure can hold a null where a value has to be,
			// found only as it is written: the frame goes back to its session
			// before the error goes on, or every later frame would be a fresh
			// one.
			statements.push(macro try $b{writes} catch (__error:Dynamic) {
				this.__dropFrame(framed);
				throw __error;
			});
		} else {
			for (write in writes) {
				statements.push(write);
			}
		}
		statements.push(macro return framed.finish());

		return {
			name: metaName,
			doc: "Auto-generated RPC meta for " + commandName,
			access: [APrivate, AInline],
			kind: FFun({
				args: [
					{name: "requestId", type: macro :Int}
				].concat(args),
				expr: macro $b{statements},
				ret: macro :crossbyte.rpc._internal.RPCFrame
			}),
			pos: Context.currentPos()
		};
	}

	/** A frame's length, flags and op (`RPCWire.MIN_PAYLOAD_LEN`), and a varint request id at its longest. **/
	static inline final FRAME_HEAD:Int = 4 + 5 + 5;

	/** The kind of an argument's value, or an error naming it. **/
	private static function argKind(a:FunctionArg, errPos:Position):RPCKind {
		final base = RPCKinds.unwrapNull(a.type);
		final kind = RPCKinds.of(base, errPos);
		if (kind == null) {
			Context.error("Unsupported RPC arg type for '" + a.name + "': " + RPCKinds.nameOf(base, errPos), errPos);
		}
		return kind;
	}

	/**
		Whether an argument may be absent, and so goes after a byte saying
		whether it is there: one that is optional, or whose type is `Null<T>`
		however it is named, as the handler's side decides it. Named through a
		typedef, a `Null<T>` went with no such byte, and a null could not be
		sent.
	**/
	private static inline function argOptional(a:FunctionArg, pos:Position):Bool {
		return a.opt || RPCContractMacroTools.isNullable(a.type, pos);
	}

	private static function createWrapperFunction(field:Field, metaName:String, args:Array<FunctionArg>, retType:ComplexType,
			responseType:Null<ComplexType>, opCode:Int):Field {
		var argExprs = args.map(a -> macro $i{a.name});
		var expr:Expr = if (responseType == null) {
			macro this.__sendCall($i{metaName}($a{[macro 0].concat(argExprs)}));
		} else {
			// Framed before it waits, so an argument that cannot be framed
			// throws with nothing left waiting for good.
			macro {
				var __requestId:Int = this.__nextRequestId();
				var __framed:crossbyte.rpc._internal.RPCFrame = $i{metaName}($a{[macro __requestId].concat(argExprs)});
				var response:$retType = this.__createResponse($v{opCode}, __requestId);
				this.__sendRequest(response, __framed);
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

	/**
		Which receiver takes an answer of type `ct`: one for its number,
		`Bool` or `String`, which takes it unboxed (an abstract over one of
		them as what it abstracts), or `RPCValueReceiver<T>` for anything
		else, and for a `Null<T>` of anything, which is an object already.
	**/
	private static function receiverOf(ct:ComplexType, pos:Position):ReceiverKind {
		if (RPCContractMacroTools.isNullable(ct, pos)) {
			return RValue;
		}
		final kind = RPCKinds.of(RPCKinds.unwrapNull(ct), pos);
		if (kind == null) {
			return RValue;
		}
		return switch (kind.token) {
			case "i32" | "i8" | "u8" | "i16" | "u16": RInt;
			case "f64" | "f32": RFloat;
			case "bool": RBool;
			case "utf8": RString;
			case _: RValue;
		}
	}

	/** The receiver interface for `ct`, written out in full. **/
	private static function receiverType(ct:ComplexType, pos:Position):ComplexType {
		return switch (receiverOf(ct, pos)) {
			case RInt: macro :crossbyte.rpc.RPCIntReceiver;
			case RFloat: macro :crossbyte.rpc.RPCFloatReceiver;
			case RBool: macro :crossbyte.rpc.RPCBoolReceiver;
			case RString: macro :crossbyte.rpc.RPCStringReceiver;
			case RValue: TPath({pack: ["crossbyte", "rpc"], name: "RPCValueReceiver", params: [TPType(ct)]});
		}
	}

	/** The suffix of the method that makes a request with a receiver: `join` and `joinThen`. **/
	static inline final RECEIVER_SUFFIX:String = "Then";

	/**
		Refuses a build in which `method`'s receiver stub would take a name
		something else has: a method of this class, of the contract or
		methods it is built from, or of a commands class it extends.
	**/
	private static function requireReceiverNameFree(fields:Array<Field>, methods:Array<String>, ancestors:Array<ClassType>, method:String,
			pos:Position):Void {
		final name:String = method + RECEIVER_SUFFIX;
		if (hasFieldNamed(fields, name) || methods.indexOf(name) >= 0 || ancestorField(ancestors, name) != null) {
			Context.error("RPC method '" + method + "' makes a method '" + name
				+ "', which calls it with a receiver, but something else is named that; rename one of them.", pos);
		}
	}

	/**
		The stub that makes the request `name` and has its answer handed to
		a receiver: `joinThen(room, receiver)` beside `join(room)`. It frames
		the call as `name` does, and waits in one of the calls the commands
		keep, so nothing is allocated for it; it returns the call's id, which
		the receiver is told with the answer.
	**/
	private static function createReceiverFunction(name:String, metaName:String, args:Array<FunctionArg>, responseType:ComplexType, opCode:Int,
			pos:Position):Field {
		final receiverName:String = Lambda.exists(args, a -> a.name == "receiver") ? "answerReceiver" : "receiver";
		final receiver:Expr = macro $i{receiverName};
		final argExprs:Array<Expr> = [macro __requestId].concat(args.map(a -> macro $i{a.name}));
		final receiverDoc:String = switch (receiverOf(responseType, pos)) {
			case RInt: "`onInt`";
			case RFloat: "`onFloat`";
			case RBool: "`onBool`";
			case RString: "`onString`";
			case RValue: "`onValue`";
		};
		return {
			name: name + RECEIVER_SUFFIX,
			doc: "Calls `" + name + "` and has its answer handed to `" + receiverName + "`, through " + receiverDoc
				+ " or `onFailure`, rather than returning an `RPCResponse`: nothing is allocated for the call. Returns the call's id, which the receiver is told with the answer. See `crossbyte.rpc.RPCReceiver`.",
			access: [APublic, AInline],
			kind: FFun({
				args: args.concat([{name: receiverName, type: receiverType(responseType, pos)}]),
				ret: macro :Int,
				expr: macro {
					if ($receiver == null) {
						throw crossbyte.rpc.RPCCommands.__noReceiver($v{name});
					}
					var __requestId:Int = this.__nextRequestId();
					var __framed:crossbyte.rpc._internal.RPCFrame = $i{metaName}($a{argExprs});
					this.__sendRequest(this.__createReceiverCall($v{opCode}, __requestId, $receiver), __framed);
					return __requestId;
				}
			}),
			pos: pos
		};
	}

	private static function readerForType(ct:ComplexType, errPos:Position):Expr {
		// On the type, as the handler's side decides it, and not on how
		// `ct` is written: through a typedef, `Null<T>` read no presence byte.
		var isOpt = RPCContractMacroTools.isNullable(ct, errPos);
		var base = RPCKinds.unwrapNull(ct);
		var kind = RPCKinds.of(base, errPos);
		if (kind == null) {
			Context.error("Unsupported RPC response type: " + RPCKinds.nameOf(base, errPos), errPos);
		}
		return RPCKinds.read(kind, isOpt, macro input, macro this.__frameEnd);
	}

	/** What a response's local holds before its value has been read. **/
	private static function zeroForType(ct:ComplexType, pos:Position):Expr {
		final kind = RPCKinds.of(RPCKinds.unwrapNull(ct), pos);
		return kind == null ? macro null : RPCKinds.zero(kind, RPCContractMacroTools.isNullable(ct, pos));
	}

	/**
		Whether each response is read in a method of its own, called from the
		reader's switch, rather than in the switch. On the jvm: there a case
		is about half a kilobyte of bytecode, and Haxe's jvm backend writes a
		method's branches with 16-bit offsets, so a reader past 32 KB (some 60
		request methods) would fail to load with a VerifyError.
	**/
	static var SPLIT_READER(get, never):Bool;

	static inline function get_SPLIT_READER():Bool {
		return Context.defined("jvm");
	}

	/** A name for this class, unique among the classes it extends, for the methods it makes. **/
	static function classTag():String {
		final type = Context.getLocalClass().get();
		return type.pack.concat([type.name]).join("_");
	}

	private static function injectResponseHandler(newFields:Array<Field>, methods:Array<ResponseMethod>, sent:Array<String>, overridesInherited:Bool):Void {
		// An error answer's message, read whole and within its frame; one that
		// does not read fails its call, and the connection carries on.
		final readMessage:Expr = macro {
			var message:String = null;
			try {
				message = input.readVarUTF();
				crossbyte.rpc._internal.RPCWire.requireWithin(input, this.__frameEnd);
			} catch (__error:Dynamic) {
				this.__rejectUnreadableResponse(op, requestId, __error);
				return;
			}
			this.__rejectResponse(op, requestId, message);
		};
		var cases:Array<Case> = [];
		for (method in methods) {
			var read = readerForType(method.responseType, method.pos);
			final type:ComplexType = method.responseType;
			final zero:Expr = zeroForType(type, method.pos);
			final answer:Expr = switch (receiverOf(type, method.pos)) {
				case RInt: macro this.__answerInt(op, requestId, (cast value : Int));
				case RFloat: macro this.__answerFloat(op, requestId, (cast value : Float));
				case RBool: macro this.__answerBool(op, requestId, (cast value : Bool));
				case RString: macro this.__answerString(op, requestId, (cast value : String));
				case RValue: macro this.__answerValue(op, requestId, value);
			};
			// Read whole and within the frame before the caller is answered
			// with it: an answer that does not read fails its call, and the
			// connection carries on.
			final body:Expr = macro {
				if (failed) {
					$readMessage;
				} else {
					var value:$type = $zero;
					try {
						value = $read;
						crossbyte.rpc._internal.RPCWire.requireWithin(input, this.__frameEnd);
					} catch (__error:Dynamic) {
						this.__rejectUnreadableResponse(op, requestId, __error);
						return;
					}
					$answer;
				}
				return;
			};
			if (SPLIT_READER) {
				final name:String = "__rpc_read_" + classTag() + "_" + method.name;
				newFields.push({
					name: name,
					access: [APrivate],
					meta: [{name: ":noCompletion", params: [], pos: Context.currentPos()}],
					kind: FFun({
						args: [
							{name: "op", type: macro :Int},
							{name: "requestId", type: macro :Int},
							{name: "input", type: macro :crossbyte.io.ByteArrayInput},
							{name: "failed", type: macro :Bool}
						],
						ret: macro :Void,
						expr: body
					}),
					pos: method.pos
				});
				cases.push({values: [macro $v{method.op}], expr: macro this.$name(op, requestId, input, failed)});
			} else {
				cases.push({values: [macro $v{method.op}], expr: body});
			}
		}

		var defaultExpr:Expr = macro {
			if (failed) {
				$readMessage;
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

private enum ReceiverKind {
	RInt;
	RFloat;
	RBool;
	RString;
	RValue;
}

private typedef ResponseMethod = {
	name:String,
	op:Int,
	args:Array<FunctionArg>,
	responseType:ComplexType,
	pos:Position
}
#end
