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
		The error a `DispatchTable` class of the functions in `block`
		fails to build with, or null when it builds. Each function is a method
		with the metadata written on it, static unless marked `@:instance`;
		a variable is a public field, or a `static inline var` marked
		`@:static`. The class is a module of its own, so a key it names that
		is not a literal or one of its own constants is written with its full
		path. Given `parent`, a type path, the class extends that class rather
		than implementing `DispatchTable` itself.
	**/
	public static macro function tableErrorOf(block:Expr, ?parent:ExprOf<String>):ExprOf<Null<String>> {
		var fields:Array<Field> = [];
		var functions:Array<Expr> = switch (block.expr) {
			case EBlock(exprs): exprs;
			default: [block];
		};
		for (e in functions) {
			var meta:Array<MetadataEntry> = [];
			var inner:Expr = e;
			var done:Bool = false;
			while (!done) {
				switch (inner.expr) {
					case EMeta(m, x):
						meta.push(m);
						inner = x;
					default:
						done = true;
				}
			}
			switch (inner.expr) {
				case EFunction(FNamed(name, _), f):
					var isInstance:Bool = Lambda.exists(meta, m -> m.name == ":instance");
					fields.push({
						name: name,
						access: isInstance ? [] : [AStatic],
						kind: FFun(f),
						meta: [for (m in meta) if (m.name != ":instance") m],
						pos: inner.pos
					});
				case EVars(vars):
					var isStatic:Bool = Lambda.exists(meta, m -> m.name == ":static");
					for (v in vars) {
						fields.push({name: v.name, access: isStatic ? [APublic, AStatic, AInline] : [APublic], kind: FVar(v.type, v.expr), pos: inner.pos});
					}
				default:
					Context.error("tableErrorOf takes named functions", inner.pos);
			}
		}
		var name:String = "DispatchTableProbe" + __probes++;
		Context.defineType({
			pack: ["crossbyte", "ds"],
			name: name,
			pos: block.pos,
			kind: switch (parent == null ? null : parent.expr) {
				case EConst(CString(path)):
					// A type of a module of another name, `pack.Module.Type`, is
					// that module's sub-type.
					var parts:Array<String> = path.split(".");
					var last:String = parts.pop();
					var module:String = parts[parts.length - 1];
					if (module.charAt(0) == module.charAt(0).toUpperCase()) {
						parts.pop();
						TDClass({pack: parts, name: module, sub: last});
					} else {
						TDClass({pack: parts, name: last});
					}
				default:
					TDClass(null, [{pack: ["crossbyte", "ds"], name: "DispatchTable"}]);
			},
			fields: fields
		});
		try {
			switch (Context.getType("crossbyte.ds." + name)) {
				case TInst(c, _):
					c.get().statics.get();
					c.get().fields.get();
				default:
			}
		} catch (error:Dynamic) {
			return macro $v{Std.string(error)};
		}
		return macro null;
	}

	#if macro
	private static var __probes:Int = 0;
	#end

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
