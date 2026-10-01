package crossbyte.io._internal;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

/**
	Records what names the program being built, for `ApplicationIdentity`.

	Two things, both known only to the compiler: the `crossbyte_app_id`
	define, read while the class is built, and the main class, which the
	compiler settles only after typing, so it is read when the output is
	generated and left on the class as runtime metadata. Asked of
	`Context.getMainExpr()`, which answers in that phase and no earlier.
**/
class ApplicationIdentityMacro {
	public static inline var DEFINE:String = "crossbyte_app_id";
	public static inline var META:String = "crossbyteMainClass";

	public static function build():Array<Field> {
		var fields:Array<Field> = Context.getBuildFields();
		var pos:Position = Context.currentPos();
		var defined:Null<String> = Context.definedValue(DEFINE);

		if (defined != null) {
			defined = StringTools.trim(defined);
			var problem:Null<String> = FilePath.portableNameProblem(defined);

			if (problem != null) {
				Context.error('-D $DEFINE=$defined cannot name a directory everywhere: $problem', pos);
			}
		}

		fields.push({
			name: "defined",
			access: [APublic, AStatic],
			kind: FProp("default", "never", macro :Null<String>, macro $v{defined}),
			meta: [{name: ":noCompletion", pos: pos}],
			pos: pos
		});

		Context.onGenerate(function(types:Array<Type>):Void {
			var name:Null<String> = mainClass();

			for (type in types) {
				switch (type) {
					case TInst(ref, _) if (ref.toString() == "crossbyte.io._internal.ApplicationIdentity"):
						var cls:ClassType = ref.get();
						// A compilation server keeps the class between builds,
						// and with it what the last build added.
						cls.meta.remove(META);
						if (name != null) {
							cls.meta.add(META, [macro $v{name}], cls.pos);
						}
					default:
				}
			}
		});

		return fields;
	}

	/**
		The class whose static `main` the program starts at. The main
		expression is that call alone, or, in a build that uses the event
		loop, as CrossByte does, a block of it and `haxe.EntryPoint.run()`.

		Aedifex, CrossByte's build tool, starts every application at a
		`ProgramMain` of its own that constructs the project's main class:
		that class is the one meant, or every application Aedifex built
		would have the one name.
	**/
	private static function mainClass():Null<String> {
		var cls:Null<ClassType> = mainOf(Context.getMainExpr());

		if (cls == null) {
			return null;
		}

		if (cls.pack.length == 0 && cls.name == "ProgramMain") {
			var started:Null<ClassType> = constructedBy(cls);
			if (started != null) {
				cls = started;
			}
		}

		return cls.pack.length == 0 ? cls.name : cls.pack.join(".") + "." + cls.name;
	}

	private static function mainOf(expr:Null<TypedExpr>):Null<ClassType> {
		if (expr == null) {
			return null;
		}

		return switch (expr.expr) {
			case TCall({expr: TField(_, FStatic(ref, field))}, _) if (field.get().name == "main"):
				ref.get();
			case TBlock(exprs):
				var found:Null<ClassType> = null;
				for (inner in exprs) {
					found = mainOf(inner);
					if (found != null) {
						break;
					}
				}
				found;
			case TMeta(_, inner) | TParenthesis(inner):
				mainOf(inner);
			default:
				null;
		}
	}

	/** The first class `cls.main` constructs, or null. **/
	private static function constructedBy(cls:ClassType):Null<ClassType> {
		var found:Null<ClassType> = null;

		function look(expr:TypedExpr):Void {
			if (found != null) {
				return;
			}

			switch (expr.expr) {
				case TNew(ref, _, _):
					found = ref.get();
				default:
					haxe.macro.TypedExprTools.iter(expr, look);
			}
		}

		for (field in cls.statics.get()) {
			if (field.name == "main") {
				var body:Null<TypedExpr> = field.expr();
				if (body != null) {
					look(body);
				}
			}
		}

		return found;
	}
}
#end
