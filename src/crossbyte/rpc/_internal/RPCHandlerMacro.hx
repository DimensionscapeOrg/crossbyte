package crossbyte.rpc._internal;

#if macro
import crossbyte.rpc._internal.RPCContractMacroTools;
import crossbyte.rpc._internal.RPCKinds;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.Tools;

class RPCHandlerMacro {
	static inline final DIRECT_SWITCH_MAX_METHODS:Int = 8;

	// On a generated dispatch(): the signature of every method it dispatches,
	// for a handler that extends this one to dispatch as well. Read from here,
	// untyped, and never from the parent's fields: following a parent method's
	// type during the child's build types that method there and then (body
	// and all, when it declares no return type) before the classes it uses
	// have finished building, and the error that comes of it names a field
	// that is really there.
	static inline final DISPATCHED_META:String = ":rpcDispatched";

	/** A frame's length, flags and op (`RPCWire.MIN_PAYLOAD_LEN`), and a varint request id at its longest. **/
	static inline final FRAME_HEAD:Int = 4 + 5 + 5;

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
		// line of them that has none, since one made again in a subclass
		// would be a field redefined without `override`.
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
							// Its answer is encoded as its return type, which is not
							// known until the method is typed, after this build. Left
							// undeclared it would be taken for Void, and the answer
							// never sent.
							if (fn.ret == null && returnsValue(fn.expr)) {
								Context.error("RPC method '" + f.name + "' returns a value, so it must declare its return type.", f.pos);
							}
							methods.push({
								idx: -1,
								name: f.name,
								pos: f.pos,
								args: fn.args,
								ret: fn.ret != null ? fn.ret : macro :Void,
								op: RPCContractMacroTools.opOfMethod(f.name, fn.args, answerOf(fn.ret, f.pos), f.pos)
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

		if (methods.length == 0) {
			return fields;
		}
		// The ops dispatch answers, each a method's: its own, and for a method
		// with an answer also the op of a one-way call to it, which has none
		// in its signature: run as usual, its answer sent nowhere.
		final entries = new Array<DispatchEntry>();
		for (method in methods) {
			entries.push({op: method.op, method: method});
			final oneWay:Int = method.name == "ping" ? method.op : RPCContractMacroTools.opOfMethod(method.name, method.args, null, method.pos);
			if (oneWay != method.op) {
				entries.push({op: oneWay, method: method});
			}
		}
		final n:Int = entries.length;
		RPCContractMacroTools.requireDistinctOps([for (entry in entries) {name: entry.method.name, op: entry.op, pos: entry.method.pos}], true);

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
		// By how many methods, not how many ops.
		final usePerfectHash = (methods.length > DIRECT_SWITCH_MAX_METHODS);

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
				buckets[h1(entries[i].op)].push(i);
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

				var b = h1(entries[bucket[0]].op);
				var d = 0;
				while (true) {
					var ok = true;
					var slots = new Array<Int>();

					for (id in bucket) {
						var slot = h2(entries[id].op, d);
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
			newFields.push(makeIntArray("RPC_OPS", entries.map(entry -> entry.op)));

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

		for (method in methods) {
			newFields.push(makeDecoder(method, tag, callsBefore, callsAfter));
		}

		newFields.push(makeDispatcher(methods, entries, usePerfectHash, tag, inheritedDispatch != null));
		// What a hello says this handler answers: each method by its own op,
		// as a commands class calls it, `ping` aside.
		newFields.push(RPCCommandMacro.fingerprintField([for (method in methods) if (method.name != "ping") method.op]));

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
		final reads:Array<Expr> = [];

		// Each argument a local, read into below.
		for (i in 0...m.args.length) {
			var a = m.args[i];
			if (a.type == null) {
				Context.error("RPC arg '" + a.name + "' must be typed", m.pos);
			}

			var local = "__a" + i;
			stmts.push({
				expr: EVars([
					{
						name: local,
						type: localTypeForArg(a),
						expr: zeroForArg(a, m.pos)
					}
				]),
				pos: m.pos
			});
			reads.push(macro $i{local} = $e{readerForArg(a, m.pos)});
			paramExprs.push({expr: EConst(CIdent(local)), pos: m.pos});
		}
		// Read whole and within the frame, or the frame is not sound: what an
		// argument read past its end came from the frame after it.
		reads.push(macro crossbyte.rpc._internal.RPCWire.requireWithin(input, this.this_frameEnd));

		// Through `this`: a method named as one of the decoder's own
		// parameters (`input`, `requestId`) would otherwise be that parameter.
		var callTarget:Expr = {expr: EField({expr: EConst(CIdent("this")), pos: m.pos}, m.name), pos: m.pos};
		var callExpr:Expr = {expr: ECall(callTarget, paramExprs), pos: m.pos};
		var callStmts:Array<Expr> = [];
		final op:Expr = macro $v{m.op};
		final name:Expr = macro $v{m.name};

		// Arguments that do not read are a call this side cannot take, not a
		// connection that has to end: the frame carries its length, so the next
		// begins where it says. A request is answered so.
		stmts.push(macro var __read:Bool = false);
		stmts.push(macro try {
			$b{reads};
			__read = true;
		} catch (__error:Dynamic) {
			this.__rpc_unreadable($op, requestId, __error);
		});
		final run:Array<Expr> = [];

		final later:Null<ComplexType> = futurePayload(m.ret, m.pos);
		if (later != null) {
			run.push(laterCall(m, later, callExpr, callsAfter));
		} else if (isVoid(m.ret)) {
			callStmts.push(callExpr);
		} else {
			requireAnswerKind(m.ret, m);
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

		if (later == null) {
			// The arguments are read above, outside this: a frame that does not
			// decode is the peer's, and is answered so. What the method throws
			// once they have (or its answer failing to encode) is this side's,
			// and becomes an error answer instead; see `__rpc_fail`.
			var guarded:Expr = {expr: EBlock(callStmts), pos: m.pos};
			if (callsAfter) {
				run.push(macro var __failure:Null<haxe.Exception> = null);
				run.push(macro try $e{guarded} catch (__error:haxe.Exception) {
					__failure = __error;
					this.__rpc_fail($op, $name, requestId, __error);
				});
				run.push(macro try {
					this.afterCall($name, requestId, __failure);
				} catch (__error:haxe.Exception) {
					this.__rpc_report($op, $name, __error);
				});
			} else {
				run.push(macro try $e{guarded} catch (__error:haxe.Exception) {
					this.__rpc_fail($op, $name, requestId, __error);
				});
			}
		}
		stmts.push(macro if (__read) $b{run});

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
				} catch (__error:haxe.Exception) {
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
			// Inlined into dispatch, the call it would cost saved, when it is
			// small: numbers, strings and bytes. One that reads or answers an
			// array or a structure is a call of its own, where its code would
			// make dispatch larger for every method: natively a one-Int
			// call to a contract with arrays in it takes 54 ns with them inlined, 40 without.
			// On the jvm never: there each inlined decoder is about 1.4 KB of
			// bytecode, and Haxe's jvm backend writes a method's branches with
			// 16-bit offsets, so a dispatch past 32 KB (a handler of some 23
			// methods) fails to load with a VerifyError.
			access: carriesCompound(m) || Context.defined("jvm") ? [APrivate] : [APrivate, AInline],
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

	/** Whether a method's arguments or answer include a kind made of others: an array, a structure. **/
	static function carriesCompound(m:MethodInfo):Bool {
		for (arg in m.args) {
			final kind = arg.type == null ? null : RPCKinds.of(unwrapNull(arg.type), m.pos);
			if (kind != null && kind.compound) {
				return true;
			}
		}
		final answer:Null<ComplexType> = answerOf(m.ret, m.pos);
		if (answer != null) {
			final kind = RPCKinds.of(unwrapNull(answer), m.pos);
			return kind != null && kind.compound;
		}
		return false;
	}

	/**
		The call to a method that answers with a `Future<T>`: sent at once if
		the future is complete when the method returns, as a plain call's
		answer is (nothing registered, nothing allocated), and otherwise
		settled by `__rpc_later` once it completes. What the method throws is
		answered as any throw is. Refused first, as `beforeCall` refuses, when
		the session already has `maxCallsWaiting` calls waiting.

		`__answered` rather than a second look at the future: one that
		completes on another thread between the two would be answered by
		neither. And the look is `__stateNow`, under the future's lock: read
		plainly, a future completing on another thread can show `succeeded`
		before its `result`, and the answer sent would be the stale one.
	**/
	static function laterCall(m:MethodInfo, payload:ComplexType, callExpr:Expr, callsAfter:Bool):Expr {
		requireAnswerKind(payload, m);
		final op:Expr = macro $v{m.op};
		final name:Expr = macro $v{m.name};
		final futureType:ComplexType = TPath({pack: ["crossbyte"], name: "Future", params: [TPType(payload)]});
		final sendNow = sendResponseExpr(m.op, macro requestId, macro __result, payload, m.pos);
		// On the session the call came from, which `__rpc_later` kept and
		// hands back: by then this handler may be running another's call.
		final sendLater = sendResponseExpr(m.op, macro requestId, macro __value, payload, m.pos, macro __session);
		final noFuture:Expr = macro $v{"RPC handler method '" + m.name + "' answered with no future"};
		final after:Expr = callsAfter ? macro try {
			this.afterCall($name, requestId, __failure);
		} catch (__error:haxe.Exception) {
			this.__rpc_report($op, $name, __error);
		} : macro {};

		return macro if (this.__rpc_mayWait($op, requestId)) {
			var __future:$futureType = null;
			var __failure:Null<haxe.Exception> = null;
			var __answered:Bool = false;
			try {
				__future = $callExpr;
				if (__future == null) {
					throw $noFuture;
				}
				if (__future.__stateNow() == 1) {
					__answered = true;
					if (requestId != 0) {
						var __result:$payload = __future.result;
						$sendNow;
					}
				}
			} catch (__error:haxe.Exception) {
				__failure = __error;
				__answered = true;
				this.__rpc_fail($op, $name, requestId, __error);
			}
			if (__answered) {
				$after;
			} else {
				this.__rpc_later($op, $name, requestId, __future, function(__session:crossbyte.rpc.RPCSession<Dynamic, Dynamic>, __value:$payload):Void {
					$sendLater;
				}, $v{callsAfter});
			}
		};
	}

	/**
		What a method returning `ret` is answered with, for its signature:
		`null` for `Void`, which is one-way, and `T` for a future of `T`.
	**/
	static function answerOf(ret:Null<ComplexType>, pos:Position):Null<ComplexType> {
		if (ret == null || isVoid(ret)) {
			return null;
		}
		final later:Null<ComplexType> = futurePayload(ret, pos);
		return later != null ? later : ret;
	}

	/**
		`T` when `ct` is `crossbyte.Future<T>`, or a future of its own such as
		`RPCResponse<T>`: a method returning one answers later, with a `T`.
		Resolving the type path types no method.
	**/
	static function futurePayload(ct:Null<ComplexType>, pos:Position):Null<ComplexType> {
		if (ct == null) {
			return null;
		}
		final resolved:Null<Type> = try Context.resolveType(ct, pos) catch (_:Dynamic) null;
		if (resolved == null) {
			return null;
		}
		return switch (Context.follow(resolved)) {
			case TInst(ref, [payload]) if (isFuture(ref.get())):
				RPCContractMacroTools.fullComplexType(payload);
			case _:
				null;
		}
	}

	static function isFuture(type:ClassType):Bool {
		var current:Null<ClassType> = type;
		while (current != null) {
			if (current.name == "Future" && current.pack.join(".") == "crossbyte") {
				return true;
			}
			current = current.superClass != null ? current.superClass.t.get() : null;
		}
		return false;
	}

	static function makeDispatcher(methods:Array<MethodInfo>, entries:Array<DispatchEntry>, usePerfectHash:Bool, tag:String, overridesInherited:Bool):Field {
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
					values: [for (entry in entries) if (entry.method == method) macro $v{entry.op}],
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
						// A method this handler has not got: answered so, not thrown.
						expr: ESwitch(macro op, cases, macro this.__rpc_unknown(op, requestId)),
						pos: Context.currentPos()
					}
				}),
				pos: Context.currentPos()
			};
		}

		var cases = new Array<Case>();
		for (i in 0...entries.length) {
			var fname = decoderName(tag, entries[i].method.name);
			cases.push({
				values: [macro $v{i}],
				expr: macro {
					this.$fname(input, requestId);
					return;
				}
			});
		}
		var defaultExpr:Expr = macro this.__rpc_unknown(op, requestId);

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
				this.__rpc_unknown(op, requestId);
				return;
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
							op: RPCContractMacroTools.opOfMethod(name, fn.args, answerOf(fn.ret, param.pos), param.pos)
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
		full: they are read in the child's module, which need not import, nor
		see the typedefs of, this one's. Resolving a type path types no method.
	**/
	static function signatureOf(method:MethodInfo):Expr {
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
				ret: RPCContractMacroTools.fullType(method.ret, method.pos),
				expr: null
			}),
			pos: method.pos
		};
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
		// Through a typedef too, as the commands side decides it.
		var isOpt = a.opt || RPCContractMacroTools.isNullable(ct, pos);
		var base = unwrapNull(ct);
		var kind = RPCKinds.of(base, pos);
		if (kind == null) {
			Context.error("Unsupported RPC arg type " + RPCKinds.nameOf(base, pos) + " for '" + a.name + "'", pos);
		}
		return RPCKinds.read(kind, isOpt, macro input, macro this.this_frameEnd);
	}

	/** What an argument's local holds until it has been read. **/
	static function zeroForArg(a:FunctionArg, pos:Position):Expr {
		final kind = RPCKinds.of(unwrapNull(a.type), pos);
		if (kind == null) {
			// Refused, naming the method, where its reader is made.
			return macro null;
		}
		return RPCKinds.zero(kind, a.opt || RPCContractMacroTools.isNullable(a.type, pos));
	}

	/** Fails the build unless an answer of type `ret` can be sent. **/
	static function requireAnswerKind(ret:ComplexType, m:MethodInfo):Void {
		final base = unwrapNull(ret);
		if (RPCKinds.of(base, m.pos) == null) {
			Context.error("Unsupported RPC response return type " + RPCKinds.nameOf(base, m.pos) + " for '" + m.name + "'", m.pos);
		}
	}

	static function localTypeForArg(a:FunctionArg):ComplexType {
		return a.opt ? makeNullType(unwrapNull(a.type)) : a.type;
	}

	/**
		Frames `value` as the answer to `requestId` and sends it: on the
		session whose call is running, or on `session` for a call answered
		later.
	**/
	static function sendResponseExpr(op:Int, requestId:Expr, value:Expr, ret:ComplexType, pos:Position, ?session:Expr):Expr {
		// A `Null<T>` answer says first whether it is there, as its caller
		// reads it; written bare, the caller would read the answer's first
		// byte as the presence byte and misread the rest, and a null String
		// could not be written at all.
		final optional:Bool = RPCContractMacroTools.isNullable(ret, pos);
		final kind = RPCKinds.of(unwrapNull(ret), pos);
		// Begun with room for the most the answer can hold, as a call's frame
		// is (see RPCCommandMacro): the length, flags and op, a varint id, and
		// the value, sized first, which is where one that cannot be sent is
		// refused, as the method failing.
		final size:Int = RPCKinds.size(kind, optional);
		final room:Expr = size >= 0 ? macro $v{FRAME_HEAD + size} : macro $v{FRAME_HEAD} + $e{RPCKinds.room(kind, optional, value)};
		var writeValue:Expr = RPCKinds.write(kind, optional, macro framed, value);
		if (kind.compound) {
			// A null inside an array or a structure is found as it is written:
			// the frame goes back to the session, and the method fails as if
			// it had thrown.
			writeValue = macro try $writeValue catch (__error:Dynamic) {
				this.__rpc_dropFrame(__on, framed);
				throw __error;
			};
		}
		// On the session whose call is running, or on the one a call answered
		// later came from.
		final on:Expr = session == null ? macro this.this_session : session;
		return macro {
			var __on:crossbyte.rpc.RPCSession<Dynamic, Dynamic> = $on;
			var framed:crossbyte.rpc._internal.RPCFrame = this.__rpc_frame(__on, $room, $v{op}, $requestId);
			$writeValue;
			this.__rpc_answerOn(__on, framed.finish());
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
			case TInst(typeRef, params):
				pathKey(typeRef.get().pack, typeRef.get().name) + paramsKey(params);
			case TType(typeRef, params):
				pathKey(typeRef.get().pack, typeRef.get().name) + paramsKey(params);
			case _:
				Std.string(type);
		}
	}

	/** A type's parameters, compared too: `Future<Int>` is not `Future<String>`. **/
	static function paramsKey(params:Array<Type>):String {
		if (params.length == 0) {
			return "";
		}
		return "<" + [for (param in params) normalizedResolvedTypeKey(Context.follow(param))].join(",") + ">";
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

/** An op a generated dispatch answers, and the method it calls. **/
private typedef DispatchEntry = {
	op:Int,
	method:MethodInfo
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
