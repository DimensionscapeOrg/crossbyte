package crossbyte.ds;

import haxe.macro.Context;
import haxe.macro.Expr;

class SwitchTable {
	/**
	 * Build a compile-time switch dispatcher from a list of key-handler pairs.
	 * Returns a function of type `(key:Dynamic, ...args:Dynamic) -> Void`.
	 *
	 * Example:
	 * ```haxe
	 * final dispatch = SwitchTable.make([
	 *   { key: "PING", handler: () -> trace("pong") },
	 *   { key: "LOGIN", handler: () -> AuthService.login() }
	 * ]);
	 *
	 * dispatch("PING");
	 * ```
	 */
	public static macro function make(cases:ExprOf<Array<SwitchCase>>):Expr {
		final parsed = switch (cases.expr) {
			case EArrayDecl(values): values;
			default: Context.error("Expected an array of { key, handler }", cases.pos);
		}

		var switchCases:Array<Case> = [];
		for (e in parsed) {
			switch (e.expr) {
				case EObjectDecl(fields):
					var key = null;
					var handler = null;

					for (f in fields) {
						switch f.field {
							case "key":
								switch f.expr.expr {
									case EConst(CString(s)): key = cast s;
									case EConst(CInt(v)): key = cast Std.parseInt(v);
									default: Context.error("Expected string literal or integer for key", f.expr.pos);
								}
							case "handler":
								handler = f.expr;
							case _:
						}
					}

					if (key == null || handler == null) {
						Context.error("Missing key or handler in case object", e.pos);
					}

					switchCases.push({
						values: [macro $v{key}],
						expr: macro crossbyte.ds.SwitchTable.__call(${handler}, $i{"args"})
					});

				case _:
					Context.error("Expected object literal for SwitchCase", e.pos);
			}
		}

		// A Dynamic-subject switch with mixed String/Int case values is
		// miscompiled by the JVM backend (the subject is eagerly coerced with
		// Jvm.toInt when any Int case exists), so emit an if-chain instead.
		// Comparison and dispatch go through runtime helpers whose Dynamic
		// parameters keep the backend on the general equality/call paths.
		var chain:Expr = macro throw "Case not found";
		var caseIndex:Int = switchCases.length - 1;
		while (caseIndex >= 0) {
			var caseValue:Expr = switchCases[caseIndex].values[0];
			var caseBody:Expr = switchCases[caseIndex].expr;
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
}
