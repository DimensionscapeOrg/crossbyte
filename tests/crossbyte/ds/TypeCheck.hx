package crossbyte.ds;

#if macro
import haxe.macro.Context;
#end
import haxe.macro.Expr;

/**
	What the compiler makes of an expression, for a case asserting that
	something must not compile: the answer is decided at compile time and
	arrives as a constant, so the case runs on every target.
**/
class TypeCheck {
	/**
		The error `e` fails to type with, where it is written, or null when it
		types.
	**/
	public static macro function errorOf(e:Expr):ExprOf<Null<String>> {
		try {
			Context.typeExpr(e);
		} catch (error:Dynamic) {
			return macro $v{Std.string(error)};
		}
		return macro null;
	}

	/**
		The type `e` has where it is written, as the compiler prints it, or
		the error it fails to type with.
	**/
	public static macro function typeOf(e:Expr):ExprOf<String> {
		try {
			return macro $v{haxe.macro.TypeTools.toString(Context.typeof(e))};
		} catch (error:Dynamic) {
			return macro $v{"error: " + Std.string(error)};
		}
	}
}
