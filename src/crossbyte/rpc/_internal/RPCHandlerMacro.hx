package crossbyte.rpc._internal;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ComplexTypeTools;

using haxe.macro.Tools;

class RPCHandlerMacro {
	static function initReaders():Map<String, (Expr) -> Expr> {
		var m = new Map<String, (Expr) -> Expr>();
		m.set("Int", inp -> macro $inp.readInt());
		m.set("Bool", inp -> macro($inp.readByte() != 0));
		m.set("Float", inp -> macro $inp.readDouble());
		m.set("String", inp -> macro $inp.readVarUTF());
		m.set("haxe.io.Bytes", inp -> macro {
			var __len = $inp.readVarUInt();
			var __b = haxe.io.Bytes.alloc(__len);
			$inp.readBytes(__b, 0, __len);
			__b;
		});
		return m;
	}

	static final TYPE_READERS = initReaders();

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();

		injectPing(fields);

		var methods = new Array<{
			idx:Int,
			name:String,
			pos:Position,
			args:Array<FunctionArg>,
			op:Int
		}>();

		for (f in fields) {
			if (f.name != "new" && f.meta != null && f.meta.filter(m -> m.name == ":rpc").length > 0 || f.name == "ping") {
				switch f.kind {
					case FFun(fn):
						if (fn.args.length > 8)
							Context.error("RPC limited to 8 params", f.pos);
						var op = crossbyte.utils.Hash.fnv1a32(haxe.io.Bytes.ofString(f.name));
						methods.push({
							idx: -1,
							name: f.name,
							pos: f.pos,
							args: fn.args,
							op: op
						});
					default:
						Context.error("Field " + f.name + " is @:rpc but not a function", f.pos);
				}
			}
		}

		var n = methods.length;
		if (n == 0) {
			return fields;
		}

		var mVal = n;

		function h1(op:Int):Int {
			var x = op;
			x ^= (x >>> 16);
			x *= 0x7feb352d;
			x ^= (x >>> 15);
			x *= 0x846ca68b;
			x ^= (x >>> 16);
			return (x < 0 ? -x : x) % mVal;
		}

		function h2(op:Int):Int {
			var x = op;
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
		for (i in 0...n)
			buckets[h1(methods[i].op)].push(i);
		buckets.sort((a, b) -> b.length - a.length);

		var G = new Array<Int>();
		G.resize(mVal);
		for (i in 0...mVal)
			G[i] = -1;

		var T = new Array<Int>();
		T.resize(n);
		for (i in 0...n)
			T[i] = -1;

		var used = new Array<Bool>();
		used.resize(n);
		for (i in 0...n)
			used[i] = false;

		for (bucket in buckets) {
			if (bucket.length == 0)
				continue;

			var b = h1(methods[bucket[0]].op);
			var d = 0;
			while (true) {
				var ok = true;
				var slots = new Array<Int>();

				for (id in bucket) {
					var slot = (h2(methods[id].op) + d) % n;
					if (used[slot]) {
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
				if (d > 1 << 22)
					Context.error("Failed to build perfect hash (unexpected).", Context.currentPos());
			}
		}

		var newFields:Array<Field> = [];
		newFields.push(makeIntArray("RPC_G", G));
		newFields.push(makeIntArray("RPC_T", T));

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

		for (i in 0...n)
			newFields.push(makeDecoder(methods[i]));

		newFields.push(makeDispatcher(methods));

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

	static function makeDecoder(m:{
		idx:Int,
		name:String,
		pos:Position,
		args:Array<FunctionArg>,
		op:Int
	}):Field {
		var stmts:Array<Expr> = [];
		var paramExprs:Array<Expr> = [];

		for (i in 0...m.args.length) {
			var a = m.args[i];
			if (a.type == null)
				Context.error("RPC arg '" + a.name + "' must be typed", m.pos);

			var isOpt = a.opt || isNullWrapped(a.type);
			var base = unwrapNull(a.type);
			var key = typeKey(base);
			var reader = TYPE_READERS.get(key);
			if (reader == null)
				Context.error("Unsupported RPC arg type " + key + " for '" + a.name + "'", m.pos);

			var local = "__a" + i;
			var read = reader(macro input);

			var varDecl:Expr = {
				expr: EVars([
					{
						name: local,
						type: base,
						expr: isOpt ? {
							expr: EIf(macro(input.readByte() != 0), {
								expr: EBlock([
									{
										expr: EBinop(OpAssign, {expr: EConst(CIdent(local)), pos: m.pos}, read),
										pos: m.pos
									}
								]),
								pos: m.pos
							}, null),
							pos: m.pos
						} : read
					}
				]),
				pos: m.pos
			};

			stmts.push(varDecl);

			paramExprs.push({expr: EConst(CIdent(local)), pos: m.pos});
		}

		var callExpr:Expr = {
			expr: ECall({expr: EConst(CIdent(m.name)), pos: m.pos}, paramExprs),
			pos: m.pos
		};

		var body:Expr = {
			expr: EBlock(stmts.concat([callExpr])),
			pos: m.pos
		};

		return {
			name: "__rpc_decode_call_" + m.name,
			access: [APrivate, AInline],
			kind: FFun({
				ret: macro :Void,
				args: [{name: "input", type: macro :crossbyte.io.ByteArrayInput}],
				expr: body
			}),
			pos: m.pos
		};
	}

	static function makeDispatcher(methods:Array<{
		idx:Int,
		name:String,
		pos:Position,
		args:Array<FunctionArg>,
		op:Int
	}>):Field {
		var cases = new Array<Case>();
		for (i in 0...methods.length) {
			var fname = "__rpc_decode_call_" + methods[i].name;
			cases.push({
				values: [macro $v{i}],
				expr: macro return this.$fname(input)
			});
		}
		var defaultExpr:Expr = macro throw "Unknown RPC index";

		var switchExpr:Expr = {
			expr: ESwitch(macro id, cases, defaultExpr),
			pos: Context.currentPos()
		};

		var body = macro {
			// O(1) perfect hash index for optimal time complexity
			var b = (function(op:Int) {
				var x = op;
				x ^= (x >>> 16);
				x *= 0x7feb352d;
				x ^= (x >>> 15);
				x *= 0x846ca68b;
				x ^= (x >>> 16);
				if (x < 0)
					x = -x;
				return x % RPC_M;
			})(op);

			var x = (function(op:Int) {
				var y = op;
				y ^= (y >>> 17);
				y *= 0xed5ad4bb;
				y ^= (y >>> 11);
				y *= 0xac4c1b51;
				y ^= (y >>> 15);
				y *= 0x31848bab;
				y ^= (y >>> 14);
				y &= 0x7fffffff;
				return y % RPC_N;
			})(op);

			var idx = (x + RPC_G[b]) % RPC_N;
			var id = RPC_T[idx];

			$e{switchExpr};
		};

		return {
			name: "dispatch",
			access: [APublic, AInline],
			kind: FFun({
				ret: macro :Void,
				args: [
					{name: "op", type: macro :Int},
					{name: "input", type: macro :crossbyte.io.ByteArrayInput}
				],
				expr: body
			}),
			pos: Context.currentPos()
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

	static function typeKey(ct:ComplexType):String {
		return switch ct {
			case TPath(tp):
				(tp.pack.length > 0 ? tp.pack.join(".") + "." : "") + tp.name;
			case _:
				ComplexTypeTools.toString(ct);
		}
	}

	private static function injectPing(fields:Array<Field>):Void {
		// we provided an abstract function in the base class so we dont need this anymore
		//	if (fields.exists(f -> f.name == "ping"))
		//		return;

		var pos = Context.currentPos();
		fields.push({
			name: "ping",
			access: [APublic, AInline],
			kind: FFun({
				args: [],
				ret: macro :Void,
				expr: macro {
					// instead of noop, maybe we shouldnt call it at all
					#if debug
					crossbyte.utils.Logger.info("PACKET SENT: PING");
					#else
					- 1;
					#end
				}
			}),
			pos: pos
		});
	}
}
#end
