package crossbyte._internal.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
	What `Vector`'s `every`, `filter`, `forEach`, `map` and `some` become
	where they are called.

	Each walks the vector in an inline loop of its own that calls a function
	of `(item, index, vector)`. A function written where it is passed is
	given the arguments it does not name, and handed to that loop as it is,
	so the compiler puts its body in the loop: no closure is made and,
	natively, nothing is boxed to call it. Any other function of none to
	three arguments is evaluated once and called from the loop directly.

	What has no arity to read (an untyped `Function`, a `Dynamic`), a
	callback of more than three arguments, and a call given a `thisObject`
	go to the vector's own method, which asks the callback what it takes.
**/
class VectorMacro {
	/**
		The call `vector.method(callback, thisObject)` becomes: `inlined`
		given a function of all three arguments, or `fallback` given the
		callback and `thisObject` as they are.
	**/
	public static function call(vector:Expr, inlined:String, fallback:String, callback:Expr, thisObject:Null<Expr>):Expr {
		var pos:Position = Context.currentPos();
		if (__given(thisObject)) {
			return macro @:pos(pos) $vector.$fallback($callback, $thisObject);
		}

		var literal:Null<Expr> = __literal(callback);
		if (literal != null) {
			switch (literal.expr) {
				case EFunction(kind, f) if (f.args.length <= 3):
					// The arguments it leaves out, named so its body cannot
					// mean them.
					var args:Array<FunctionArg> = f.args.copy();
					var names:Array<String> = ["_crossbyteVectorItem", "_crossbyteVectorIndex", "_crossbyteVectorOf"];
					while (args.length < 3) {
						args.push({name: names[args.length]});
					}
					var whole:Expr = {
						expr: EFunction(kind, {args: args, ret: f.ret, expr: f.expr, params: f.params}),
						pos: literal.pos
					};
					return macro @:pos(pos) $vector.$inlined($whole);
				default:
					return macro @:pos(pos) $vector.$fallback($callback, null);
			}
		}

		var given:Array<Expr> = [
			macro _crossbyteVectorItem,
			macro _crossbyteVectorIndex,
			macro _crossbyteVectorOf
		];
		var arity:Int = __arity(callback);
		if (arity < 0 || arity > 3) {
			return macro @:pos(pos) $vector.$fallback($callback, null);
		}
		var forward:Expr = macro @:pos(callback.pos) _crossbyteVectorCallback($a{given.slice(0, arity)});
		// The vector and then the callback, each once, as a call evaluates
		// its receiver and then its argument.
		return macro @:pos(pos) {
			var _crossbyteVector = $vector;
			var _crossbyteVectorCallback = $callback;
			_crossbyteVector.$inlined((_crossbyteVectorItem, _crossbyteVectorIndex, _crossbyteVectorOf) -> $forward);
		};
	}

	/** Whether a `thisObject` was given: anything but nothing or `null`. **/
	private static function __given(thisObject:Null<Expr>):Bool {
		if (thisObject == null) {
			return false;
		}
		return switch (thisObject.expr) {
			case EConst(CIdent("null")): false;
			default: true;
		}
	}

	/** The function written as `callback`, through parentheses and metadata. **/
	private static function __literal(callback:Expr):Null<Expr> {
		return switch (callback.expr) {
			case EParenthesis(inner) | EMeta(_, inner): __literal(inner);
			case EFunction(FAnonymous | FArrow, _): callback;
			default: null;
		}
	}

	/** How many arguments `callback`'s type says it takes, or -1. **/
	private static function __arity(callback:Expr):Int {
		var type = try Context.typeof(callback) catch (e:Dynamic) null;
		if (type == null) {
			return -1;
		}
		return switch (Context.follow(type)) {
			case TFun(args, _): args.length;
			default: -1;
		}
	}
}
#end
