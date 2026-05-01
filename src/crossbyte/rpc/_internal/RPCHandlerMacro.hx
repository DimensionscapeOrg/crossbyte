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

	static function initReaders():Map<String, Expr->Expr> {
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
		final contractMethods = RPCContractMacroTools.getImplementedContractMethods(":rpcContract");
		final manualRpcFields = fields.filter(field -> field.name != "new" && field.meta != null && field.meta.filter(m -> m.name == ":rpc").length > 0);
		final dispatchField = findField(fields, "dispatch");
		final pingField = findField(fields, "ping");
		final usesManualDispatch = dispatchField != null;

		if (usesManualDispatch) {
			if (contractMethods != null) {
				Context.error("Do not mix @:rpcContract with a hand-written dispatch() implementation in the same RPC handler.", dispatchField.pos);
			}
			if (manualRpcFields.length > 0) {
				Context.error("Do not mix field-level @:rpc methods with a hand-written dispatch() implementation in the same RPC handler.",
					manualRpcFields[0].pos);
			}
			if (pingField == null) {
				injectPing(fields);
			}
			return fields;
		}

		injectPing(fields);

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
					Context.error("RPC handler is missing implementation for contract method '" + method.name + "'. Built-in system methods such as ping() stay on RPCHandler and should not appear in the shared contract.", method.pos);
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

			final pingField = findField(fields, "ping");
			if (pingField != null) {
				switch (pingField.kind) {
					case FFun(fn):
						methods.push({
							idx: -1,
							name: "ping",
							pos: pingField.pos,
							args: fn.args,
							ret: fn.ret != null ? fn.ret : macro :Void,
							op: crossbyte.utils.Hash.fnv1a32(haxe.io.Bytes.ofString("ping"))
						});
					default:
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
							var op = crossbyte.utils.Hash.fnv1a32(haxe.io.Bytes.ofString(f.name));
							methods.push({
								idx: -1,
								name: f.name,
								pos: f.pos,
								args: fn.args,
								ret: fn.ret != null ? fn.ret : macro :Void,
								op: op
							});
						default:
							Context.error("Field " + f.name + " is @:rpc but not a function", f.pos);
					}
				}
			}
		}

		var n = methods.length;
		if (n == 0) {
			return fields;
		}

		var newFields:Array<Field> = [];
		final usePerfectHash = (n > DIRECT_SWITCH_MAX_METHODS);

		if (usePerfectHash) {
			var mVal = n;

			function h1(op:Int):Int {
				var x = op;
				x ^= (x >>> 16);
				x *= 0x7feb352d;
				x ^= (x >>> 15);
				x *= 0x846ca68b;
				x ^= (x >>> 16);
				x &= 0x7fffffff;
				return x % mVal;
			}

			function h2(op:Int, d:Int):Int {
				var x = op + d * 0x9e3779b9;
				x ^= (x >>> 17);
				x *= 0xed5ad4bb;
				x ^= (x >>> 11);
				x *= 0xac4c1b51;
				x ^= (x >>> 15);
				x *= 0x31848bab;
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
			newFields.push(makeDecoder(methods[i]));
		}

		newFields.push(makeDispatcher(methods, usePerfectHash));

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

	static function makeDecoder(m:MethodInfo):Field {
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

		if (isVoid(m.ret)) {
			stmts.push(callExpr);
		} else {
			var key = typeKey(m.ret, m.pos);
			if (!TYPE_WRITERS.exists(key)) {
				Context.error("Unsupported RPC response return type " + key + " for '" + m.name + "'", m.pos);
			}
			stmts.push({
				expr: EVars([{name: "__result", type: m.ret, expr: callExpr}]),
				pos: m.pos
			});
			var sendResponse = sendResponseExpr(m.op, macro requestId, macro __result, m.ret, m.pos);
			stmts.push(macro {
				if (requestId != 0) {
					$e{sendResponse};
				}
			});
		}

		var body:Expr = {
			expr: EBlock(stmts),
			pos: m.pos
		};

		return {
			name: "__rpc_decode_call_" + m.name,
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

	static function makeDispatcher(methods:Array<MethodInfo>, usePerfectHash:Bool):Field {
		if (!usePerfectHash) {
			final cases = new Array<Case>();
			for (method in methods) {
				final fname = "__rpc_decode_call_" + method.name;
				cases.push({
					values: [macro $v{method.op}],
					expr: macro {
						this.$fname(input, requestId);
					}
				});
			}

			return {
				name: "dispatch",
				access: [APublic],
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
			var fname = "__rpc_decode_call_" + methods[i].name;
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
				x *= 0x7feb352d;
				x ^= (x >>> 15);
				x *= 0x846ca68b;
				x ^= (x >>> 16);
				x &= 0x7fffffff;
				return x % RPC_M;
			})(op);

			var d = RPC_G[b];
			var idx = (function(op:Int, d:Int) {
				var y = op + d * 0x9e3779b9;
				y ^= (y >>> 17);
				y *= 0xed5ad4bb;
				y ^= (y >>> 11);
				y *= 0xac4c1b51;
				y ^= (y >>> 15);
				y *= 0x31848bab;
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
			access: [APublic, AInline],
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

	static function readerForArg(a:FunctionArg, pos:Position):Expr {
		var ct = a.type;
		var isOpt = a.opt || isNullWrapped(ct);
		var base = unwrapNull(ct);
		var key = typeKey(base, pos);
		var reader = TYPE_READERS.get(key);
		if (reader == null) {
			Context.error("Unsupported RPC arg type " + key + " for '" + a.name + "'", pos);
		}

		var read = reader(macro input);
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
