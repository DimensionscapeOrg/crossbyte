package crossbyte.ds;

import haxe.macro.Context;
import haxe.macro.Expr;

class SwitchTable {
	/**
	 * Build a compile-time switch dispatcher from a list of key-handler pairs.
	 * Returns a function of type `String -> Void`.
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

		var hasArgs:Bool = false;
		var switchCases:Array<Case> = [];
		for (e in parsed) {
			switch (e.expr) {
				case EObjectDecl(fields):
					var key = null;
					var handler = null;
					var args = null;

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

					switch (Context.typeof(handler)) {
						case TFun(args, _):
							if (args.length == 0) {
								switchCases.push({
									values: [macro $v{key}],
									expr: macro ${handler}()
								});
							} else if (args.length > 0) {
                                hasArgs = true;

								switchCases.push({
									values: [macro $v{key}],
									expr: macro ${handler}($i{"args"})
								});
							}
						default:
					}

				case _:
					Context.error("Expected object literal for SwitchCase", e.pos);
			}
		}

		var funcArgs:Array<FunctionArg> = [{name: "key", type: macro :Dynamic}];
		if (hasArgs) {
			funcArgs.push({name: "args", type: macro :haxe.Rest<Dynamic>, opt: false});
		}
		return {
			expr: EFunction(FAnonymous, {
				args: funcArgs,
				ret: macro :Void,
				expr: {
					expr: ESwitch(macro key, switchCases, macro throw "Case not found"),
					pos: Context.currentPos()
				}
			}),
			pos: Context.currentPos()
		};
	}
}
