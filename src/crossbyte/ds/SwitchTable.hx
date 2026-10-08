package crossbyte.ds;

import haxe.macro.Context;
import haxe.macro.Expr;

class SwitchTable {
	/**
	 * Build a compile-time switch dispatcher from a list of key-handler pairs.
	 * Returns a function of type `(key:Dynamic, ...args:Dynamic) -> Void`.
	 *
	 * A key is any expression: a literal, a constant such as `Opcode.PING`, or
	 * a variable read when the dispatcher runs. Two literal keys that are the
	 * same are refused at compile time.
	 *
	 * A key no case matches goes to `otherwise`, a `(key:Dynamic,
	 * args:Array<Dynamic>) -> Void`, or without one throws naming the key.
	 *
	 * Example:
	 * ```haxe
	 * final dispatch = SwitchTable.make([
	 *   { key: "PING", handler: () -> trace("pong") },
	 *   { key: Opcode.LOGIN, handler: (name:String) -> AuthService.login(name) }
	 * ], (key, args) -> trace('unknown command $key'));
	 *
	 * dispatch("PING");
	 * ```
	 */
	public static macro function make(cases:ExprOf<Array<SwitchCase>>, ?otherwise:Expr):Expr {
		final parsed = switch (cases.expr) {
			case EArrayDecl(values): values;
			default: Context.error("Expected an array of { key, handler }", cases.pos);
		}

		var keys:Array<Expr> = [];
		var handlers:Array<Expr> = [];
		var literals:Map<String, Bool> = new Map();
		for (e in parsed) {
			switch (e.expr) {
				case EObjectDecl(fields):
					var key:Expr = null;
					var handler:Expr = null;

					for (f in fields) {
						switch f.field {
							case "key":
								key = f.expr;
								var literal:Null<String> = switch (f.expr.expr) {
									case EConst(CString(s)): "s:" + s;
									case EConst(CInt(v)): "i:" + Std.parseInt(v);
									default: null;
								}
								if (literal != null) {
									if (literals.exists(literal)) {
										Context.error("Duplicate key in SwitchTable", f.expr.pos);
									}
									literals.set(literal, true);
								}
							case "handler":
								handler = f.expr;
							case _:
						}
					}

					if (key == null || handler == null) {
						Context.error("Missing key or handler in case object", e.pos);
					}

					keys.push(key);
					handlers.push(handler);

				case _:
					Context.error("Expected object literal for SwitchCase", e.pos);
			}
		}

		var hasOtherwise:Bool = otherwise != null && switch (otherwise.expr) {
			case EConst(CIdent("null")): false;
			default: true;
		};

		// A Dynamic-subject switch with mixed String/Int case values is
		// miscompiled by the JVM backend (the subject is eagerly coerced with
		// Jvm.toInt when any Int case exists), so emit an if-chain instead.
		// Comparison and dispatch go through runtime helpers whose Dynamic
		// parameters keep the backend on the general equality/call paths.
		// A handler written as a function literal is made once, with the
		// dispatcher, rather than each time its case is chosen.
		var hoisted:Array<Expr> = [];
		for (i in 0...handlers.length) {
			switch (handlers[i].expr) {
				case EFunction(_, _):
					var name:String = "__switchHandler" + i;
					hoisted.push(macro var $name = ${handlers[i]});
					handlers[i] = macro $i{name};
				default:
			}
		}
		if (hasOtherwise) {
			switch (otherwise.expr) {
				case EFunction(_, _):
					hoisted.push(macro var __switchOtherwise = ${otherwise});
					otherwise = macro __switchOtherwise;
				default:
			}
		}

		var chain:Expr = hasOtherwise ? macro crossbyte.ds.SwitchTable.__callWithKey(${otherwise}, key, $i{"args"}) : macro crossbyte.ds.SwitchTable.__notFound(key);
		var caseIndex:Int = keys.length - 1;
		while (caseIndex >= 0) {
			var caseValue:Expr = keys[caseIndex];
			var caseBody:Expr = macro crossbyte.ds.SwitchTable.__call(${handlers[caseIndex]}, $i{"args"});
			chain = macro if (crossbyte.ds.SwitchTable.__matches(key, ${caseValue})) ${caseBody} else ${chain};
			caseIndex--;
		}

		// Keys all of one type (every one an Int, or every one a String) are
		// looked up typed first: a switch for literals, comparisons of that
		// type for named constants. The chain above, a dynamic equality per
		// case, costs 148 ns a dispatch of sixteen Int keys where a switch
		// costs 8. A key of another type, or one no case names, still goes
		// through the chain, so what matches and what reaches `otherwise` is
		// the same either way; the jvm's mixed-key miscompile needs keys of
		// both types, which never come here.
		var typed:Null<Expr> = __typedLookup(keys, handlers);
		var body:Expr = typed == null ? chain : macro {
			var __switchDone:Bool = false;
			${typed};
			if (!__switchDone) {
				${chain};
			}
		};

		var funcArgs:Array<FunctionArg> = [
			{name: "key", type: macro :Dynamic},
			{name: "args", type: macro :haxe.Rest<Dynamic>, opt: false}
		];
		var dispatcher:Expr = {
			expr: EFunction(FAnonymous, {
				args: funcArgs,
				ret: macro :Void,
				expr: body
			}),
			pos: Context.currentPos()
		};
		if (hoisted.length == 0) {
			return dispatcher;
		}
		hoisted.push(dispatcher);
		return macro $b{hoisted};
	}

	#if macro
	/**
		The typed lookup, when every key has one type: Int or String. Null
		when they do not, or when a key cannot be typed here.
	**/
	private static function __typedLookup(keys:Array<Expr>, handlers:Array<Expr>):Null<Expr> {
		var literals:Bool = true;
		var kind:Null<String> = null;
		for (key in keys) {
			var keyKind:Null<String> = switch (key.expr) {
				case EConst(CInt(_)): "Int";
				case EConst(CString(_)): "String";
				default:
					literals = false;
					try {
						switch (haxe.macro.TypeTools.followWithAbstracts(Context.typeof(key))) {
							case TAbstract(_.get() => {pack: [], name: "Int"}, _): "Int";
							case TInst(_.get() => {pack: [], name: "String"}, _): "String";
							default: null;
						}
					} catch (_:Dynamic) {
						null;
					}
			}
			if (keyKind == null || (kind != null && keyKind != kind)) {
				return null;
			}
			kind = keyKind;
		}
		if (kind == null) {
			return null;
		}

		var bodies:Array<Expr> = [
			for (i in 0...keys.length)
				macro {
					__switchDone = true;
					crossbyte.ds.SwitchTable.__call(${handlers[i]}, $i{"args"});
				}
		];
		var subjectType:ComplexType = kind == "Int" ? macro :Int : macro :String;
		var test:Expr = kind == "Int" ? macro Std.isOfType(key, Int) : macro Std.isOfType(key, String);

		if (literals) {
			var cases:Array<Case> = [for (i in 0...keys.length) {values: [keys[i]], expr: bodies[i]}];
			var lookup:Expr = {expr: ESwitch(macro __switchKey, cases, macro {}), pos: Context.currentPos()};
			return macro if (${test}) {
				var __switchKey:$subjectType = key;
				${lookup};
			};
		}

		// Named constants: compared typed, in order, as the chain compares; as
		// the underlying type, which an enum abstract's value may not convert
		// to on its own.
		var compared:Expr = macro {};
		var i:Int = keys.length - 1;
		while (i >= 0) {
			var value:Expr = macro (cast ${keys[i]} : $subjectType);
			compared = macro if (__switchKey == ${value}) ${bodies[i]} else ${compared};
			i--;
		}
		return macro if (${test}) {
			var __switchKey:$subjectType = key;
			${compared};
		};
	}
	#end

	/**
	 * Runtime key comparison for generated dispatchers. The Dynamic
	 * parameters are load-bearing: comparing a Dynamic key directly against
	 * a typed Int constant makes the JVM backend emit a numeric fast path
	 * (`Jvm.toInt`) that throws on non-numeric keys; routing both operands
	 * through Dynamic keeps it on the general equality path.
	 *
	 * On JavaScript strictly: Haxe writes `==` between two Dynamics as
	 * JavaScript's loose equality, so the String "1" matched the case `1`
	 * there and nowhere else.
	 */
	@:noCompletion public static function __matches(key:Dynamic, caseValue:Dynamic):Bool {
		#if js
		return js.Syntax.strictEq(key, caseValue) || (key == null && caseValue == null);
		#else
		return key == caseValue;
		#end
	}

	/**
	 * Runtime handler dispatch for generated dispatchers. Direct dynamic
	 * calls at explicit arities are used because the JVM backend's
	 * `Reflect.callMethod` does not reliably signal arity mismatches.
	 */
	@:noCompletion public static function __call(handler:Dynamic, args:Array<Dynamic>):Void {
		switch (args.length) {
			case 0: handler();
			case 1: handler(args[0]);
			case 2: handler(args[0], args[1]);
			case 3: handler(args[0], args[1], args[2]);
			default: Reflect.callMethod(handler, handler, args);
		}
	}

	/**
	 * The fallback, with the key and the arguments as an array: two
	 * arguments always, since how many a dispatch passes is not known.
	 */
	@:noCompletion public static function __callWithKey(handler:Dynamic, key:Dynamic, args:Array<Dynamic>):Void {
		handler(key, args);
	}

	@:noCompletion public static function __notFound(key:Dynamic):Void {
		throw "SwitchTable: no case for " + Std.string(key);
	}
}
