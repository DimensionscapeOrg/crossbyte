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
	 * A handler whose type says how many arguments it takes is given that
	 * many or refused: a dispatch passing another number throws an
	 * `ArgumentError` naming the case, on every target. Unchecked, it threw
	 * on the interpreter, ran with the extra arguments dropped on JavaScript,
	 * and on the jvm did not run at all and said nothing.
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
		// How many arguments each handler takes, read from its type before it
		// is hoisted: null for one whose type does not say (a Dynamic).
		var arities:Array<Null<Array<Int>>> = [for (handler in handlers) __arity(handler)];
		var labels:Array<String> = [for (key in keys) haxe.macro.ExprTools.toString(key)];
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

		// The dispatcher's own parameters are named so a case's key cannot
		// mean them: named `key` and `args`, a key held in a variable of
		// either name read the dispatcher's argument, and every dispatch went
		// to the first case.
		var chain:Expr = hasOtherwise ? macro crossbyte.ds.SwitchTable.__callWithKey(${otherwise}, __switchTableKey, __switchTableArgs) : macro crossbyte.ds.SwitchTable.__notFound(__switchTableKey);
		var calls:Array<Expr> = [for (i in 0...handlers.length) __callOf(handlers[i], arities[i], labels[i])];
		var caseIndex:Int = keys.length - 1;
		while (caseIndex >= 0) {
			var caseValue:Expr = keys[caseIndex];
			var caseBody:Expr = calls[caseIndex];
			chain = macro if (crossbyte.ds.SwitchTable.__matches(__switchTableKey, ${caseValue})) ${caseBody} else ${chain};
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
		var typed:Null<Expr> = __typedLookup(keys, calls);
		var body:Expr = typed == null ? chain : macro {
			var __switchDone:Bool = false;
			${typed};
			if (!__switchDone) {
				${chain};
			}
		};

		var funcArgs:Array<FunctionArg> = [
			{name: "__switchTableKey", type: macro :Dynamic},
			{name: "__switchTableArgs", type: macro :haxe.Rest<Dynamic>, opt: false}
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
		The fewest and the most arguments `handler` takes, from its type, the
		most -1 for a rest argument; null when its type does not say.
	**/
	private static function __arity(handler:Expr):Null<Array<Int>> {
		var type = try Context.follow(Context.typeof(handler)) catch (_:Dynamic) null;
		return switch (type) {
			case TFun(args, _):
				var fewest:Int = 0;
				var most:Int = args.length;
				for (arg in args) {
					var rest:Bool = switch (Context.follow(arg.t)) {
						case TAbstract(_.get() => {pack: ["haxe"], name: "Rest"}, _): true;
						default: false;
					}
					if (rest) {
						most = -1;
					} else if (!arg.opt) {
						fewest++;
					}
				}
				[fewest, most];
			default: null;
		}
	}

	/** The call of one case's handler, its arguments counted when its type counts them. **/
	private static function __callOf(handler:Expr, arity:Null<Array<Int>>, label:String):Expr {
		if (arity == null) {
			return macro crossbyte.ds.SwitchTable.__call(${handler}, __switchTableArgs);
		}
		var fewest:Int = arity[0];
		var most:Int = arity[1];
		return macro crossbyte.ds.SwitchTable.__callCounted(${handler}, __switchTableArgs, $v{fewest}, $v{most}, $v{label});
	}

	/**
		The typed lookup, when every key has one type: Int or String. Null
		when they do not, or when a key cannot be typed here.
	**/
	private static function __typedLookup(keys:Array<Expr>, calls:Array<Expr>):Null<Expr> {
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
					${calls[i]};
				}
		];
		var subjectType:ComplexType = kind == "Int" ? macro :Int : macro :String;
		var test:Expr = kind == "Int" ? macro Std.isOfType(__switchTableKey, Int) : macro Std.isOfType(__switchTableKey, String);

		if (literals) {
			var cases:Array<Case> = [for (i in 0...keys.length) {values: [keys[i]], expr: bodies[i]}];
			var lookup:Expr = {expr: ESwitch(macro __switchKey, cases, macro {}), pos: Context.currentPos()};
			return macro if (${test}) {
				var __switchKey:$subjectType = __switchTableKey;
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
			var __switchKey:$subjectType = __switchTableKey;
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
	 * `__call` for a handler whose type says how many arguments it takes:
	 * another number is refused, the same way on every target.
	 */
	@:noCompletion public static function __callCounted(handler:Dynamic, args:Array<Dynamic>, fewest:Int, most:Int, label:String):Void {
		if (args.length < fewest || (most >= 0 && args.length > most)) {
			var takes:String = most < 0 ? '$fewest or more' : (fewest == most ? '$fewest' : '$fewest to $most');
			throw new crossbyte.errors.ArgumentError('SwitchTable: the case for $label takes $takes arguments, and was given ${args.length}.');
		}
		__call(handler, args);
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
