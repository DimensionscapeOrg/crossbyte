package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCContractMacroTools;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCHandlerMacro {
	static inline final DIRECT_SWITCH_MAX_METHODS:Int = 8;

	// On a generated dispatch(): the signature of every method it dispatches,
	// for a handler that extends this one to dispatch as well. Read from here,
	// untyped, and never from the parent's fields: following a parent method's
	// type during the child's build types that method there and then -- body
	// and all, when it declares no return type -- before the classes it uses
	// have finished building, and the error that comes of it names a field
	// that is really there.
	static inline final DISPATCHED_META:String = ":rpcDispatched";

	// Each reads from `inp`, in a frame that ends at `end`.
	static function initReaders():Map<String, (Expr, Expr) -> Expr> {
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

	static function initWriters():Map<String, (Expr, Expr) -> Expr> {
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

	static final TYPE_READERS = initReaders();
	static final TYPE_WRITERS = initWriters();

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var methods = new Array<MethodInfo>();
		// The handler classes between this one and RPCHandler, nearest first.
		final ancestors = handlerAncestors();
		// What the nearest one's generated dispatch answers, as it recorded it.
		final dispatchedByAncestors = inheritedMethods(ancestors);
		final contractMethods = RPCContractMacroTools.getImplementedContractMethods(":rpcContract");
		final manualRpcFields = fields.filter(field -> field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0);
		final dispatchField = findField(fields, "dispatch");
		final usesManualDispatch = dispatchField != null;
		// Every handler answers `ping`; one is made for the first class in a
		// line of them that has none. Made again in a subclass, it was a
		// field redefined without `override`, and no handler could extend
		// another.
		final needsPing = findField(fields, "ping") == null && ancestorField(ancestors, "ping") == null;

		if (usesManualDispatch) {
			if (contractMethods != null) {
				Context.error("Do not mix @:rpcContract with a hand-written dispatch() implementation in the same RPC handler.", dispatchField.pos);
			}
			if (manualRpcFields.length > 0) {
				Context.error("Do not mix field-level @:rpc methods with a hand-written dispatch() implementation in the same RPC handler.",
					manualRpcFields[0].pos);
			}
			if (needsPing) {
				injectPing(fields);
			}
			return fields;
		}

		if (needsPing) {
			injectPing(fields);
		}

		if (contractMethods != null) {
			RPCContractMacroTools.requireExtends(":rpcContract", "crossbyte.rpc.RPCHandler");
			if (manualRpcFields.length > 0) {
				Context.error("Do not mix @:rpcContract with field-level @:rpc methods in the same class.", manualRpcFields[0].pos);
			}

			for (method in contractMethods) {
				if (RPCContractMacroTools.isReservedSystemMethod(method.name)) {
					Context.error(RPCContractMacroTools.reservedSystemMethodMessage(method.name), method.pos);
				}

				final implementation = findField(fields, method.name);
				if (implementation == null) {
					// Implemented by a handler this one extends, as a reusable
					// contract's reusable handler does.
					final inherited = ancestorField(ancestors, method.name);
					if (inherited == null) {
						Context.error("RPC handler is missing implementation for contract method '" + method.name + "'. Built-in system methods such as ping() stay on RPCHandler and should not appear in the shared contract.", method.pos);
					}
					// Checked against what the ancestor recorded when it answers
					// it too. When it does not, the call made to it below is
					// typed as any call is, after the build.
					final recorded = findMethod(dispatchedByAncestors, method.name);
					if (recorded != null) {
						requireSameSignature(recorded, method.name, method.args, method.ret);
					}
					methods.push({
						idx: -1,
						name: method.name,
						pos: inherited.pos,
						args: method.args,
						ret: method.ret,
						op: method.op
					});
					continue;
				}

				switch (implementation.kind) {
					case FFun(fn):
						if (fn.args.length != method.args.length) {
							Context.error("RPC handler method '" + method.name + "' must declare " + method.args.length + " arguments.", implementation.pos);
						}

						for (i in 0...method.args.length) {
							final expected = method.args[i];
							final actual = fn.args[i];
							actual.opt = expected.opt;
							if (actual.type == null) {
								actual.type = expected.type;
							} else if (!sameType(actual.type, expected.type, implementation.pos)) {
							Context.error("RPC handler argument type mismatch for '" + method.name + "." + actual.name + "'. Handler argument types must match the shared contract.", implementation.pos);
						}
					}

					final expectedRet = method.ret;
					if (fn.ret == null) {
						fn.ret = expectedRet;
					} else if (!sameType(fn.ret, expectedRet, implementation.pos)) {
						Context.error("RPC handler return type mismatch for '" + method.name + "'. Handler method signatures must match the shared contract directly.", implementation.pos);
					}

						methods.push({
							idx: -1,
							name: method.name,
							pos: implementation.pos,
							args: method.args,
							ret: expectedRet,
							op: method.op
						});
					default:
						Context.error("RPC handler contract method '" + method.name + "' must be implemented as a function.", implementation.pos);
				}
			}
		} else {
			for (f in fields) {
				if (f.name != "new" && ((f.meta != null && f.meta.filter(m -> m.name == ":rpc").length > 0) || f.name == "ping")) {
					switch f.kind {
						case FFun(fn):
							if (fn.args.length > 8) {
								Context.error("RPC limited to 8 params", f.pos);
							}
							// Its answer is encoded as its return type, which is not
							// known until the method is typed -- after this build.
							// Left undeclared it was taken for Void, and the answer
							// was never sent.
							if (fn.ret == null && returnsValue(fn.expr)) {
								Context.error("RPC method '" + f.name + "' returns a value, so it must declare its return type.", f.pos);
							}
							methods.push({
								idx: -1,
								name: f.name,
								pos: f.pos,
								args: fn.args,
								ret: fn.ret != null ? fn.ret : macro :Void,
								op: RPCOps.opOf(f.name)
							});
						default:
							Context.error("Field " + f.name + " is @:rpc but not a function", f.pos);
					}
				}
			}
		}

		// What the handlers this one extends answered, it answers too: the
		// nearest one's dispatch records every method it took over from its own.
		for (inherited in dispatchedByAncestors) {
			if (!hasMethod(methods, inherited.name)) {
				methods.push(inherited);
			}
		}

		// A contract does not declare `ping`, so this class's own is added
		// here. An ancestor's came in above: every generated dispatch answers
		// `ping`, and names it with the rest.
		if (!hasMethod(methods, "ping")) {
			final own = findField(fields, "ping");
			if (own != null) {
				switch (own.kind) {
					case FFun(fn):
						methods.push({
							idx: -1,
							name: "ping",
							pos: own.pos,
							args: fn.args,
							ret: fn.ret != null ? fn.ret : macro :Void,
							op: RPCOps.opOf("ping")
						});
					default:
				}
			}
		}

		var n = methods.length;
		if (n == 0) {
			return fields;
		}
		RPCContractMacroTools.requireDistinctOps([for (method in methods) {name: method.name, pos: method.pos}], true);

		final tag = classTag();
		// Hooks cost a handler nothing unless it, or a handler it extends,
		// overrides them: only then are the calls generated at all.
		final callsBefore = findField(fields, "beforeCall") != null || ancestorField(ancestors, "beforeCall") != null;
		final callsAfter = findField(fields, "afterCall") != null || ancestorField(ancestors, "afterCall") != null;
		final inheritedDispatch = ancestorField(ancestors, "dispatch");
		if (inheritedDispatch != null && !inheritedDispatch.meta.has(DISPATCHED_META)) {
			Context.error("This RPC handler extends one whose dispatch() is written by hand, which this one's generated dispatch would replace. Write this one's dispatch() too.", Context.currentPos());
		}

		var newFields:Array<Field> = [];
		final usePerfectHash = (n > DIRECT_SWITCH_MAX_METHODS);

		if (usePerfectHash) {
			var mVal = n;

			function h1(op:Int):Int {
				var x = op;
				x ^= (x >>> 16);
				x = crossbyte.utils.Hash.mul32(x, 0x7feb352d);
				x ^= (x >>> 15);
				x = crossbyte.utils.Hash.mul32(x, 0x846ca68b);
				x ^= (x >>> 16);
				x &= 0x7fffffff;
				return x % mVal;
			}

			function h2(op:Int, d:Int):Int {
				var x = op + crossbyte.utils.Hash.mul32(d, 0x9e3779b9);
				x ^= (x >>> 17);
				x = crossbyte.utils.Hash.mul32(x, 0xed5ad4bb);
				x ^= (x >>> 11);
				x = crossbyte.utils.Hash.mul32(x, 0xac4c1b51);
				x ^= (x >>> 15);
				x = crossbyte.utils.Hash.mul32(x, 0x31848bab);
				x ^= (x >>> 14);
				x &= 0x7fffffff;
				return x % n;
			}

			var buckets = [for (_ in 0...mVal) new Array<Int>()];
			for (i in 0...n) {
				buckets[h1(methods[i].op)].push(i);
			}
			buckets.sort((a, b) -> b.length - a.length);

			var G = new Array<Int>();
			G.resize(mVal);
			for (i in 0...mVal) {
				G[i] = -1;
			}

			var T = new Array<Int>();
			T.resize(n);
			for (i in 0...n) {
				T[i] = -1;
			}

			var used = new Array<Bool>();
			used.resize(n);
			for (i in 0...n) {
				used[i] = false;
			}

			for (bucket in buckets) {
				if (bucket.length == 0) {
					continue;
				}

				var b = h1(methods[bucket[0]].op);
				var d = 0;
				while (true) {
					var ok = true;
					var slots = new Array<Int>();

					for (id in bucket) {
						var slot = h2(methods[id].op, d);
						if (used[slot] || slots.indexOf(slot) != -1) {
							ok = false;
							break;
						}
						slots.push(slot);
					}

					if (ok) {
						G[b] = d;
						for (i in 0...bucket.length) {
							var id = bucket[i];
							var slot = slots[i];
							used[slot] = true;
							T[slot] = id;
							methods[id].idx = id;
						}
						break;
					}

					d++;
					if (d > 1 << 22) {
						Context.error("Failed to build perfect hash (unexpected).", Context.currentPos());
					}
				}
			}

			newFields.push(makeIntArray("RPC_G", G));
			newFields.push(makeIntArray("RPC_T", T));
			newFields.push(makeIntArray("RPC_OPS", methods.map(method -> method.op)));

			newFields.push({
				name: "RPC_M",
				access: [APrivate, AStatic, AInline],
				kind: FVar(macro :Int, macro $v{mVal}),
				pos: Context.currentPos()
			});

			newFields.push({
				name: "RPC_N",
				access: [APrivate, AStatic, AInline],
				kind: FVar(macro :Int, macro $v{n}),
				pos: Context.currentPos()
			});
		}

		for (i in 0...n) {
			newFields.push(makeDecoder(methods[i], tag, callsBefore, callsAfter));
		}

		newFields.push(makeDispatcher(methods, usePerfectHash, tag, inheritedDispatch != null));

		return fields.concat(newFields);
	}

	static function makeIntArray(name:String, data:Array<Int>):Field {
		var arr:Expr = macro [$a{data.map(v -> macro $v{v})}];
		return {
			name: name,
			access: [APrivate, AStatic],
			kind: FVar(macro :Array<Int>, arr),
			pos: Context.currentPos()
		};
	}

	static inline function decoderName(tag:String, method:String):String {
		return "__rpc_decode_call_" + tag + "_" + method;
	}

	static function makeDecoder(m:MethodInfo, tag:String, callsBefore:Bool, callsAfter:Bool):Field {
		var stmts:Array<Expr> = [];
		var paramExprs:Array<Expr> = [];

		for (i in 0...m.args.length) {
			var a = m.args[i];
			if (a.type == null) {
				Context.error("RPC arg '" + a.name + "' must be typed", m.pos);
			}

			var local = "__a" + i;
			var read = readerForArg(a, m.pos);
			stmts.push({
				expr: EVars([
					{
						name: local,
						type: localTypeForArg(a),
						expr: read
					}
				]),
				pos: m.pos
			});
			paramExprs.push({expr: EConst(CIdent(local)), pos: m.pos});
		}

		var callTarget:Expr = {expr: EConst(CIdent(m.name)), pos: m.pos};
		var callExpr:Expr = {expr: ECall(callTarget, paramExprs), pos: m.pos};
		var callStmts:Array<Expr> = [];

		if (isVoid(m.ret)) {
			callStmts.push(callExpr);
		} else {
			var key = typeKey(m.ret, m.pos);
			if (!TYPE_WRITERS.exists(key)) {
				Context.error("Unsupported RPC response return type " + key + " for '" + m.name + "'", m.pos);
			}
			callStmts.push({
				expr: EVars([{name: "__result", type: m.ret, expr: callExpr}]),
				pos: m.pos
			});
			var sendResponse = sendResponseExpr(m.op, macro requestId, macro __result, m.ret, m.pos);
			callStmts.push(macro {
				if (requestId != 0) {
					$e{sendResponse};
				}
			});
		}

		// Read whole and within the frame, or the frame is not sound: what an
		// argument read past its end came from the frame after it.
		stmts.push(macro crossbyte.rpc._internal.RPCWire.requireWithin(input, this.this_frameEnd));

		// The arguments are read above, outside this: a frame that does not
		// decode is the peer's fault, and ends the connection. What the method
		// throws once they have -- or its answer failing to encode -- is this
		// side's, and becomes an error answer instead; see `__rpc_fail`.
		final op:Expr = macro $v{m.op};
		final name:Expr = macro $v{m.name};
		var guarded:Expr = {expr: EBlock(callStmts), pos: m.pos};
		if (callsAfter) {
			stmts.push(macro var __failure:Dynamic = null);
			stmts.push(macro try $e{guarded} catch (__error:Dynamic) {
				__failure = __error;
				this.__rpc_fail($op, $name, requestId, __error);
			});
			stmts.push(macro try {
				this.afterCall($name, requestId, __failure);
			} catch (__error:Dynamic) {
				this.__rpc_report($op, $name, __error);
			});
		} else {
			stmts.push(macro try $e{guarded} catch (__error:Dynamic) {
				this.__rpc_fail($op, $name, requestId, __error);
			});
		}

		var body:Expr = {expr: EBlock(stmts), pos: m.pos};

		// Asked before a byte of the arguments is read, so a call refused
		// for its size costs nothing to refuse. Refused, the frame is simply
		// passed over; the loop reading it moves to the next either way. No
		// early return: these are inlined into dispatch.
		if (callsBefore) {
			final run:Expr = body;
			body = macro {
				var __refusal:Null<crossbyte.rpc.RPCError> = null;
				var __runs:Bool = true;
				try {
					__refusal = this.beforeCall($name, requestId, this.this_frameEnd - input.position);
				} catch (__error:Dynamic) {
					__runs = false;
					this.__rpc_fail($op, $name, requestId, __error);
				}
				if (__runs && __refusal != null) {
					__runs = false;
					this.__rpc_refuse($op, requestId, __refusal);
				}
				if (__runs) {
					$run;
				}
			};
		}

		return {
			name: decoderName(tag, m.name),
			access: [APrivate, AInline],
			kind: FFun({
				ret: macro :Void,
				args: [
					{name: "input", type: macro :crossbyte.io.ByteArrayInput},
					{name: "requestId", type: macro :Int}
				],
				expr: body
			}),
			pos: m.pos
		};
	}

	static function makeDispatcher(methods:Array<MethodInfo>, usePerfectHash:Bool, tag:String, overridesInherited:Bool):Field {
		// Never inline: it is reached through RPCHandler's abstract dispatch()
		// in any case, and a subclass must be able to override it.
		final access:Array<Access> = overridesInherited ? [APublic, AOverride] : [APublic];
		final meta:Metadata = [
			{
				name: DISPATCHED_META,
				params: [for (method in methods) signatureOf(method)],
				pos: Context.currentPos()
			}
		];

		if (!usePerfectHash) {
			final cases = new Array<Case>();
			for (method in methods) {
				final fname = decoderName(tag, method.name);
				cases.push({
					values: [macro $v{method.op}],
					expr: macro {
						this.$fname(input, requestId);
					}
				});
			}

			return {
				name: "dispatch",
				access: access,
				meta: meta,
				kind: FFun({
					ret: macro :Void,
					args: [
						{name: "op", type: macro :Int},
						{name: "input", type: macro :crossbyte.io.ByteArrayInput},
						{name: "requestId", type: macro :Int}
					],
					expr: {
						expr: ESwitch(macro op, cases, macro throw "Unknown RPC op"),
						pos: Context.currentPos()
					}
				}),
				pos: Context.currentPos()
			};
		}

		var cases = new Array<Case>();
		for (i in 0...methods.length) {
			var fname = decoderName(tag, methods[i].name);
			cases.push({
				values: [macro $v{i}],
				expr: macro {
					this.$fname(input, requestId);
					return;
				}
			});
		}
		var defaultExpr:Expr = macro throw "Unknown RPC index";

		var switchExpr:Expr = {
			expr: ESwitch(macro id, cases, defaultExpr),
			pos: Context.currentPos()
		};

		var body = macro {
			var b = (function(op:Int) {
				var x = op;
				x ^= (x >>> 16);
				x = crossbyte.utils.Hash.mul32(x, 0x7feb352d);
				x ^= (x >>> 15);
				x = crossbyte.utils.Hash.mul32(x, 0x846ca68b);
				x ^= (x >>> 16);
				x &= 0x7fffffff;
				return x % RPC_M;
			})(op);

			var d = RPC_G[b];
			var idx = (function(op:Int, d:Int) {
				var y = op + crossbyte.utils.Hash.mul32(d, 0x9e3779b9);
				y ^= (y >>> 17);
				y = crossbyte.utils.Hash.mul32(y, 0xed5ad4bb);
				y ^= (y >>> 11);
				y = crossbyte.utils.Hash.mul32(y, 0xac4c1b51);
				y ^= (y >>> 15);
				y = crossbyte.utils.Hash.mul32(y, 0x31848bab);
				y ^= (y >>> 14);
				y &= 0x7fffffff;
				return y % RPC_N;
			})(op, d);
			var id = RPC_T[idx];
			if (id < 0 || RPC_OPS[id] != op) {
				throw "Unknown RPC op";
			}

			$e{switchExpr};
		};

		return {
			name: "dispatch",
			access: access,
			meta: meta,
			kind: FFun({
				ret: macro :Void,
				args: [
					{name: "op", type: macro :Int},
					{name: "input", type: macro :crossbyte.io.ByteArrayInput},
					{name: "requestId", type: macro :Int}
				],
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	// ---------------------------------------------------------- hierarchies

	/** The handler classes this one extends, nearest first, up to RPCHandler. **/
	static function handlerAncestors():Array<ClassType> {
		final ancestors = new Array<ClassType>();
		var parent = Context.getLocalClass().get().superClass;
		while (parent != null) {
			final type = parent.t.get();
			if (type.pack.join(".") == "crossbyte.rpc" && type.name == "RPCHandler") {
				break;
			}
			ancestors.push(type);
			parent = type.superClass;
		}
		return ancestors;
	}

	/** `name` as the nearest of `ancestors` to declare it has it, or `null`. **/
	static function ancestorField(ancestors:Array<ClassType>, name:String):Null<ClassField> {
		for (type in ancestors) {
			for (field in type.fields.get()) {
				if (field.name == name) {
					return field;
				}
			}
		}
		return null;
	}

	/** What the nearest ancestor's generated dispatch() answers, as it recorded it. **/
	static function inheritedMethods(ancestors:Array<ClassType>):Array<MethodInfo> {
		final methods = new Array<MethodInfo>();
		final dispatch = ancestorField(ancestors, "dispatch");
		if (dispatch == null || !dispatch.meta.has(DISPATCHED_META)) {
			return methods;
		}
		for (entry in dispatch.meta.extract(DISPATCHED_META)) {
			for (param in entry.params) {
				switch (param.expr) {
					case EFunction(FNamed(name, _), fn):
						methods.push({
							idx: -1,
							name: name,
							pos: param.pos,
							args: [
								for (arg in fn.args)
									({
										name: arg.name,
										opt: arg.opt,
										type: arg.type,
										value: null,
										meta: []
									} : FunctionArg)
							],
							ret: fn.ret != null ? fn.ret : macro :Void,
							op: RPCOps.opOf(name)
						});
					default:
				}
			}
		}
		return methods;
	}

	/**
		A dispatched method's signature, as a handler extending this one reads
		it: a function expression, never typed, whose types are written out in
		full -- they are read in the child's module, which need not import what
		this one's does.
	**/
	static function signatureOf(method:MethodInfo):Expr {
		return {
			expr: EFunction(FNamed(method.name, false), {
				args: [
					for (arg in method.args)
						({
							name: arg.name,
							opt: arg.opt,
							type: fullType(arg.type, method.pos),
							value: null,
							meta: []
						} : FunctionArg)
				],
				ret: fullType(method.ret, method.pos),
				expr: null
			}),
			pos: method.pos
		};
	}

	/** `ct` with every path in full. Resolving a type path types no method. **/
	static function fullType(ct:ComplexType, pos:Position):ComplexType {
		if (ct == null) {
			return null;
		}
		try {
			final full = Context.resolveType(ct, pos).toComplexType();
			return full != null ? full : ct;
		} catch (_:Dynamic) {
			// Left for the check that reports an unsupported type to report.
			return ct;
		}
	}

	static function requireSameSignature(inherited:MethodInfo, name:String, args:Array<FunctionArg>, ret:ComplexType):Void {
		var same = inherited.args.length == args.length && sameType(inherited.ret, ret, inherited.pos);
		for (i in 0...args.length) {
			if (!same) {
				break;
			}
			same = sameType(unwrapNull(inherited.args[i].type), unwrapNull(args[i].type), inherited.pos);
		}
		if (!same) {
			Context.error("RPC handler method '" + name + "', inherited, does not match the shared contract's signature.", inherited.pos);
		}
	}

	/** Whether `body` returns a value; a function nested in it returns its own. **/
	static function returnsValue(body:Null<Expr>):Bool {
		var found = false;
		function walk(e:Expr):Void {
			if (found || e == null) {
				return;
			}
			switch (e.expr) {
				case EReturn(value) if (value != null):
					found = true;
				case EFunction(_, _):
				default:
					e.iter(walk);
			}
		}
		walk(body);
		return found;
	}

	static function findMethod(methods:Array<MethodInfo>, name:String):Null<MethodInfo> {
		for (method in methods) {
			if (method.name == name) {
				return method;
			}
		}
		return null;
	}

	static function hasMethod(methods:Array<MethodInfo>, name:String):Bool {
		for (method in methods) {
			if (method.name == name) {
				return true;
			}
		}
		return false;
	}

	/** This class's path as part of an identifier, so each class's decoders are its own. **/
	static function classTag():String {
		final type = Context.getLocalClass().get();
		return type.pack.concat([type.name]).join("_");
	}

	static function readerForArg(a:FunctionArg, pos:Position):Expr {
		var ct = a.type;
		var isOpt = a.opt || isNullWrapped(ct);
		var base = unwrapNull(ct);
		var key = typeKey(base, pos);
		var reader = TYPE_READERS.get(key);
		if (reader == null) {
			Context.error("Unsupported RPC arg type " + key + " for '" + a.name + "'", pos);
		}

		var read = reader(macro input, macro this.this_frameEnd);
		return isOpt ? macro(input.readByte() != 0 ? $read : null) : read;
	}

	static function localTypeForArg(a:FunctionArg):ComplexType {
		return a.opt ? makeNullType(unwrapNull(a.type)) : a.type;
	}

	static function sendResponseExpr(op:Int, requestId:Expr, value:Expr, ret:ComplexType, pos:Position):Expr {
		var key = typeKey(ret, pos);
		var writer = TYPE_WRITERS.get(key);
		var writeValue = writer(macro framed, value);
		return macro {
			var framed:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(crossbyte.rpc._internal.RPCWire.MIN_PAYLOAD_LEN + 4);
			framed.writeInt(0);
			framed.writeByte(crossbyte.rpc._internal.RPCWire.FLAG_RESPONSE);
			framed.writeInt($v{op});
			framed.writeVarUInt($requestId);
			$writeValue;
			framed.writeIntAt(0, framed.bytesWritten - 4);
			framed.flush();
			this.this_connection.send(framed);
		};
	}

	static function isNullWrapped(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath({name: "Null", params: _}): true;
			case _: false;
		}
	}

	static function unwrapNull(ct:ComplexType):ComplexType {
		return switch (ct) {
			case TPath({name: "Null", params: [TPType(inner)]}): inner;
			case _: ct;
		}
	}

	static function makeNullType(ct:ComplexType):ComplexType {
		return TPath({pack: [], name: "Null", params: [TPType(ct)]});
	}

	static function isVoid(ct:ComplexType):Bool {
		return switch (Context.follow(Context.resolveType(ct, Context.currentPos()))) {
			case TAbstract(typeRef, _) if (typeRef.get().name == "Void"): true;
			case _: false;
		}
	}

	static function typeKey(ct:ComplexType, pos:Position):String {
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

	static function resolvedTypeKey(type:Type):String {
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

	static inline function pathKey(pack:Array<String>, name:String):String {
		return (pack.length > 0 ? pack.join(".") + "." : "") + name;
	}

	static function findField(fields:Array<Field>, name:String):Null<Field> {
		for (field in fields) {
			if (field.name == name) {
				return field;
			}
		}
		return null;
	}

	static function sameType(actual:ComplexType, expected:ComplexType, pos:Position):Bool {
		return normalizedTypeKey(actual, pos) == normalizedTypeKey(expected, pos);
	}

	static function normalizedTypeKey(ct:ComplexType, pos:Position):String {
		return normalizedResolvedTypeKey(Context.follow(Context.resolveType(ct, pos)));
	}

	static function normalizedResolvedTypeKey(type:Type):String {
		return switch (type) {
			case TAbstract(typeRef, params):
				final typeDef = typeRef.get();
				if (typeDef.name == "Void") {
					"Void";
				} else if (typeDef.name == "Null" && params.length == 1) {
					"Null<" + normalizedResolvedTypeKey(Context.follow(params[0])) + ">";
				} else {
					pathKey(typeDef.pack, typeDef.name);
				}
			case TInst(typeRef, _):
				pathKey(typeRef.get().pack, typeRef.get().name);
			case TType(typeRef, _):
				pathKey(typeRef.get().pack, typeRef.get().name);
			case _:
				Std.string(type);
		}
	}

	private static function injectPing(fields:Array<Field>):Void {
		var pos = Context.currentPos();
		fields.push({
			name: "ping",
			access: [APublic, AInline],
			kind: FFun({
				args: [],
				ret: macro :Void,
				expr: macro {
					#if debug
					crossbyte.utils.Logger.info("PACKET SENT: PING");
					#end
				}
			}),
			pos: pos
		});
	}
}

private typedef MethodInfo = {
	idx:Int,
	name:String,
	pos:Position,
	args:Array<FunctionArg>,
	ret:ComplexType,
	op:Int
}
#end
