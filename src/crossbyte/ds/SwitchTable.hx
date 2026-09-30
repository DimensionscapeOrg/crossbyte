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
	 * same are refused at compile time. Only literals were accepted, so a table
	 * keyed on named opcodes had to repeat their numbers.
	 *
	 * A key no case matches goes to `otherwise`, a `(key:Dynamic,
	 * args:Array<Dynamic>) -> Void`, or without one throws naming the key.
	 * There was no way to handle it but a `try` around every dispatch.
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
		var chain:Expr = hasOtherwise ? macro crossbyte.ds.SwitchTable.__callWithKey(${otherwise}, key, $i{"args"}) : macro crossbyte.ds.SwitchTable.__notFound(key);
		var caseIndex:Int = keys.length - 1;
		while (caseIndex >= 0) {
			var caseValue:Expr = keys[caseIndex];
			var caseBody:Expr = macro crossbyte.ds.SwitchTable.__call(${handlers[caseIndex]}, $i{"args"});
			chain = macro if (crossbyte.ds.SwitchTable.__matches(key, ${caseValue})) ${caseBody} else ${chain};
			caseIndex--;
		}

		var funcArgs:Array<FunctionArg> = [
			{name: "key", type: macro :Dynamic},
			{name: "args", type: macro :haxe.Rest<Dynamic>, opt: false}
		];
		return {
			expr: EFunction(FAnonymous, {
				args: funcArgs,
				ret: macro :Void,
				expr: chain
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * Runtime key comparison for generated dispatchers. The Dynamic
	 * parameters are load-bearing: comparing a Dynamic key directly against
	 * a typed Int constant makes the JVM backend emit a numeric fast path
	 * (`Jvm.toInt`) that throws on non-numeric keys; routing both operands
	 * through Dynamic keeps it on the general equality path.
	 */
	@:noCompletion public static function __matches(key:Dynamic, caseValue:Dynamic):Bool {
		return key == caseValue;
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
