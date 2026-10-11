package crossbyte._internal.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/**
	`DispatchTable` and `Dispatch.make`: each builds a `switch` from cases
	whose keys are constants of one type and whose handlers take the same
	arguments, checked as it is compiled.
**/
class DispatchTableMacro {
	/** `Dispatch.make`: a function holding the switch. **/
	public static function make(cases:Expr, otherwise:Null<Expr>):Expr {
		var keys:Array<Expr> = [];
		var handlers:Array<Expr> = [];
		var entries:Array<Expr> = switch (cases.expr) {
			case EArrayDecl(values): values;
			default: Context.error("Dispatch.make takes an array of { key, handler }", cases.pos);
		}
		for (entry in entries) {
			switch (entry.expr) {
				case EObjectDecl(fields):
					var key:Null<Expr> = null;
					var handler:Null<Expr> = null;
					for (field in fields) {
						switch (field.field) {
							case "key":
								key = field.expr;
							case "handler":
								handler = field.expr;
							default:
								Context.error('A case has a key and a handler, and no ${field.field}', field.expr.pos);
						}
					}
					if (key == null || handler == null) {
						Context.error("A case needs a key and a handler", entry.pos);
					}
					keys.push(key);
					handlers.push(handler);
				default:
					Context.error("Expected a case: { key, handler }", entry.pos);
			}
		}
		if (keys.length == 0) {
			Context.error("A DispatchTable needs at least one case", cases.pos);
		}
		var hasOtherwise:Bool = otherwise != null && switch (otherwise.expr) {
			case EConst(CIdent("null")): false;
			default: true;
		};

		var keyType:Type = __keyType(keys);
		var signature:Signature = __handlerSignature(handlers);
		var args:Array<Expr> = [for (i in 0...signature.args.length) macro $i{"__dispatchArg" + i}];

		var statements:Array<Expr> = [];
		var switchCases:Array<Case> = [];
		for (i in 0...handlers.length) {
			switchCases.push({values: [keys[i]], expr: __handle(handlers[i], "__dispatchHandler" + i, [], args, signature, statements)});
		}
		var missing:Expr = hasOtherwise ? __handle(otherwise, "__dispatchOtherwise", [macro __dispatchKey], args,
			__otherwiseSignature(otherwise, keyType, signature), statements) : __refuse(macro __dispatchKey);

		var params:Array<FunctionArg> = [{name: "__dispatchKey", type: TypeTools.toComplexType(keyType)}];
		for (i in 0...signature.args.length) {
			params.push({name: "__dispatchArg" + i, type: TypeTools.toComplexType(signature.args[i].t), opt: signature.args[i].opt});
		}
		var lookup:Expr = {expr: ESwitch(macro __dispatchKey, switchCases, missing), pos: Context.currentPos()};
		var dispatcher:Expr = {
			expr: EFunction(FAnonymous, {args: params, ret: TypeTools.toComplexType(signature.ret), expr: macro {
				$lookup;
			}}),
			pos: Context.currentPos()
		};
		// Typed as a plain function type, so it reads as (Opcode, String) -> Void
		// rather than by the dispatcher's own parameter names.
		var dispatchType:ComplexType = TFunction([TypeTools.toComplexType(keyType)].concat([
			for (arg in signature.args) arg.opt ? TOptional(TypeTools.toComplexType(arg.t)) : TypeTools.toComplexType(arg.t)
		]), TypeTools.toComplexType(signature.ret));
		statements.push(macro var __dispatchDispatcher:$dispatchType = $dispatcher);
		statements.push(macro __dispatchDispatcher);
		return {expr: EBlock(statements), pos: Context.currentPos()};
	}

	/**
		Builds a `DispatchTable` from a class's `@:case` methods: `call`,
		`exists`, `get`, `keys` and `size`, as `DispatchTable` describes.
	**/
	public static function build():Array<Field> {
		var fields:Array<Field> = Context.getBuildFields();
		var local:ClassType = Context.getLocalClass().get();
		var cases:Array<{field:Field, fn:Function, keys:Array<Expr>}> = [];
		var fallback:Null<{field:Field, fn:Function}> = null;
		for (field in fields) {
			var marked:Array<MetadataEntry> = field.meta == null ? [] : [for (m in field.meta) if (m.name == ":case") m];
			var isDefault:Bool = field.meta != null && Lambda.exists(field.meta, m -> m.name == ":default");
			switch (field.kind) {
				case FFun(fn):
					if (marked.length > 0 && isDefault) {
						Context.error("A method is a case or the default, not both", field.pos);
					}
					if (marked.length > 0) {
						var keys:Array<Expr> = [];
						for (m in marked) {
							if (m.params == null || m.params.length == 0) {
								Context.error("@:case names the keys its method handles", m.pos);
							}
							keys = keys.concat(m.params);
						}
						cases.push({field: field, fn: fn, keys: keys});
					} else if (isDefault) {
						if (fallback != null) {
							Context.error("A table has one @:default", field.pos);
						}
						fallback = {field: field, fn: fn};
					}
				default:
					if (marked.length > 0 || isDefault) {
						Context.error("@:case and @:default mark methods", field.pos);
					}
			}
		}
		if (cases.length == 0) {
			Context.error("A DispatchTable needs at least one @:case method", local.pos);
		}
		for (field in fields) {
			if (["call", "exists", "get", "keys", "size"].indexOf(field.name) >= 0) {
				Context.error('A DispatchTable makes its own ${field.name}: name this something else', field.pos);
			}
		}

		var isStatic:Bool = __isStatic(cases[0].field);
		for (c in cases) {
			if (__isStatic(c.field) != isStatic) {
				Context.error("A table's cases are all static methods or all instance methods", c.field.pos);
			}
		}
		if (fallback != null && __isStatic(fallback.field) != isStatic) {
			Context.error("The default is static as the cases are, or not as they are not", fallback.field.pos);
		}

		var allKeys:Array<Expr> = [];
		for (c in cases) {
			allKeys = allKeys.concat(c.keys);
		}
		var keyType:Type = __keyType(allKeys);
		var keyCT:ComplexType = TypeTools.toComplexType(keyType);

		// The table's signature: the first case's, whose arguments say their
		// types; every other case takes the same.
		var first:Function = cases[0].fn;
		var signature:Signature = {args: [for (arg in first.args) {name: arg.name, opt: arg.opt == true, t: __argType(arg, cases[0].field)}], ret: first.ret == null ? Context.getType("Void") : Context.resolveType(first.ret, cases[0].field.pos)};
		var handlerType:Type = TFun(signature.args, signature.ret);
		for (c in cases) {
			var own:Type = TFun([for (arg in c.fn.args) {name: arg.name, opt: arg.opt == true, t: __argType(arg, c.field)}], c.fn.ret == null ? signature.ret : Context.resolveType(c.fn.ret, c.field.pos));
			if (!Context.unify(own, handlerType)) {
				Context.error('This case is ${TypeTools.toString(own)}, where the table\'s cases are ${TypeTools.toString(handlerType)}', c.field.pos);
			}
		}
		if (fallback != null) {
			var own:Type = TFun([for (arg in fallback.fn.args) {name: arg.name, opt: arg.opt == true, t: __argType(arg, fallback.field)}], fallback.fn.ret == null ? signature.ret : Context.resolveType(fallback.fn.ret, fallback.field.pos));
			var expected:Type = TFun([{name: "key", opt: false, t: keyType}].concat(signature.args), signature.ret);
			if (!Context.unify(own, expected)) {
				Context.error('The default is ${TypeTools.toString(own)}, where it takes the key and then what the cases take: ${TypeTools.toString(expected)}', fallback.field.pos);
			}
		}

		var isVoid:Bool = __isVoid(signature.ret);
		var owner:Expr = isStatic ? macro $i{local.name} : macro this;
		var keyName:String = Lambda.exists(signature.args, arg -> arg.name == "key") ? "__key" : "key";
		var keyRef:Expr = macro $i{keyName};
		var params:Array<FunctionArg> = [{name: keyName, type: keyCT}];
		var passed:Array<Expr> = [];
		for (arg in signature.args) {
			params.push({name: arg.name, type: TypeTools.toComplexType(arg.t), opt: arg.opt});
			passed.push(macro $i{arg.name});
		}
		// Each case is called through its owner, `this` or the class, so an
		// argument named as a method does not stand in for it.
		var calls:Array<Case> = [];
		var gets:Array<Case> = [];
		for (c in cases) {
			var method:Expr = {expr: EField(owner, c.field.name), pos: c.field.pos};
			var call:Expr = {expr: ECall(method, passed), pos: c.field.pos};
			calls.push({values: c.keys, expr: isVoid ? call : macro return $call});
			gets.push({values: c.keys, expr: method});
		}
		var missing:Expr = if (fallback != null) {
			var call:Expr = {expr: ECall({expr: EField(owner, fallback.field.name), pos: fallback.field.pos}, [keyRef].concat(passed)), pos: fallback.field.pos};
			isVoid ? call : macro return $call;
		} else {
			__refuse(keyRef);
		};
		var pos:Position = local.pos;
		var access:Array<Access> = isStatic ? [APublic, AStatic, AInline] : [APublic, AInline];
		var handlerCT:ComplexType = TFunction([for (arg in signature.args) arg.opt ? TOptional(TypeTools.toComplexType(arg.t)) : TypeTools.toComplexType(arg.t)], TypeTools.toComplexType(signature.ret));

		fields.push({
			name: "call",
			doc: "The case for `key`, called with the arguments; the default, or an `ArgumentError`, for a key no case names.",
			access: access,
			kind: FFun({args: params, ret: TypeTools.toComplexType(signature.ret), expr: macro {
				${{expr: ESwitch(keyRef, calls, missing), pos: pos}};
			}}),
			pos: pos
		});
		fields.push({
			name: "exists",
			doc: "Whether a case names `key`.",
			access: access,
			kind: FFun({args: [{name: "key", type: keyCT}], ret: macro :Bool, expr: macro return ${{expr: ESwitch(macro key, [{values: allKeys, expr: macro true}], macro false), pos: pos}}}),
			pos: pos
		});
		fields.push({
			name: "get",
			doc: "The case for `key` as a function value, or null when no case names it.",
			access: isStatic ? [APublic, AStatic] : [APublic],
			kind: FFun({args: [{name: "key", type: keyCT}], ret: TPath({pack: [], name: "Null", params: [TPType(handlerCT)]}), expr: macro return ${{expr: ESwitch(macro key, gets, macro null), pos: pos}}}),
			pos: pos
		});
		fields.push({
			name: "keys",
			doc: "Every key, in the order the cases name them.",
			access: [APublic, AStatic, AFinal],
			kind: FVar(TPath({pack: ["haxe", "ds"], name: "ReadOnlyArray", params: [TPType(keyCT)]}), {expr: EArrayDecl(allKeys), pos: pos}),
			pos: pos
		});
		fields.push({
			name: "size",
			doc: "How many keys.",
			access: [APublic, AStatic, AInline],
			kind: FVar(macro :Int, macro $v{allKeys.length}),
			pos: pos
		});
		return fields;
	}

	/**
		The keys' type, after checking each is a constant of it and no two
		are the same value.
	**/
	private static function __keyType(keys:Array<Expr>):Type {
		var keyType:Null<Type> = null;
		var seen:Map<String, Expr> = new Map();
		for (key in keys) {
			var typed:TypedExpr = try Context.typeExpr(key) catch (error:Dynamic) Context.error(Std.string(error), key.pos);
			var value:Null<String> = __constant(typed);
			if (value == null) {
				Context.error('A DispatchTable key is a constant (a literal, an inline variable or an enum abstract value), and ${ExprTools.toString(key)} is not', key.pos);
			}
			if (keyType == null) {
				keyType = typed.t;
				switch (TypeTools.followWithAbstracts(keyType)) {
					case TAbstract(_.get() => {pack: [], name: "Int"}, _) | TInst(_.get() => {pack: [], name: "String"}, _):
					default:
						Context.error('A DispatchTable key is an Int, a String or an enum abstract over one, and this is ${TypeTools.toString(keyType)}', key.pos);
				}
			} else if (!Context.unify(typed.t, keyType)) {
				Context.error('This key is ${TypeTools.toString(typed.t)}, where the table\'s keys are ${TypeTools.toString(keyType)}', key.pos);
			}
			if (seen.exists(value)) {
				Context.error('Two cases name the key ${ExprTools.toString(key)}: this one and ${ExprTools.toString(seen.get(value))}', key.pos);
			}
			seen.set(value, key);
		}
		return keyType;
	}

	/** A key's value, tagged by kind, or null when it is not a constant. **/
	private static function __constant(e:TypedExpr):Null<String> {
		return switch (e.expr) {
			case TConst(TInt(v)): "i" + v;
			case TConst(TString(s)): "s" + s;
			// Constants of other types, so the error is their type's.
			case TConst(TFloat(f)): "f" + f;
			case TConst(TBool(b)): "b" + b;
			case TUnop(OpNeg, false, {expr: TConst(TInt(v))}): "i" + (-v);
			case TCast(inner, _) | TParenthesis(inner) | TMeta(_, inner): __constant(inner);
			case TField(_, FStatic(_, field)):
				var f:ClassField = field.get();
				switch (f.kind) {
					case FVar(AccInline, _):
						var value:Null<TypedExpr> = f.expr();
						value == null ? null : __constant(value);
					default: null;
				}
			default: null;
		}
	}

	/**
		The handlers' signature: the first's arguments, and its return type
		when any handler says what it returns, Void when none does.
	**/
	private static function __handlerSignature(handlers:Array<Expr>):Signature {
		var types:Array<Type> = [for (handler in handlers) Context.typeof(handler)];
		var args:Array<{name:String, opt:Bool, t:Type}>;
		var ret:Type;
		switch (Context.follow(types[0])) {
			case TFun(a, r):
				args = a;
				ret = r;
			default:
				Context.error('A handler is a function, and this is ${TypeTools.toString(types[0])}', handlers[0].pos);
				return null;
		}
		for (arg in args) {
			switch (Context.follow(arg.t)) {
				case TMono(_):
					Context.error('Give the first handler\'s arguments their types: ${arg.name} has none', handlers[0].pos);
				default:
			}
		}
		var declared:Bool = false;
		for (handler in handlers) {
			switch (handler.expr) {
				case EFunction(_, f) if (f.ret == null):
				default:
					declared = true;
			}
		}
		if (!declared) {
			ret = Context.getType("Void");
		}
		var handlerType:Type = TFun(args, ret);
		for (i in 0...handlers.length) {
			if (!Context.unify(types[i], handlerType)) {
				Context.error('This handler is ${TypeTools.toString(types[i])}, where the table\'s handlers are ${TypeTools.toString(handlerType)}', handlers[i].pos);
			}
		}
		return {args: args, ret: ret};
	}

	/** The signature `otherwise` must have: the key, then the handlers' arguments. **/
	private static function __otherwiseSignature(otherwise:Expr, keyType:Type, signature:Signature):Signature {
		var expected:Signature = {args: [{name: "key", opt: false, t: keyType}].concat(signature.args), ret: signature.ret};
		var own:Type = Context.typeof(otherwise);
		if (!Context.unify(own, TFun(expected.args, expected.ret))) {
			Context.error('The fallback is ${TypeTools.toString(own)}, where it takes the key and then what the handlers take: ${TypeTools.toString(TFun(expected.args, expected.ret))}', otherwise.pos);
		}
		return expected;
	}

	/**
		A case's body. A handler written as a function is copied in, its
		arguments bound to the dispatcher's, so nothing is called; a static
		method is called directly; anything else is evaluated once, with the
		table, and called.
	**/
	private static function __handle(handler:Expr, name:String, leading:Array<Expr>, args:Array<Expr>, signature:Signature, statements:Array<Expr>):Expr {
		var passed:Array<Expr> = leading.concat(args);
		var isVoid:Bool = __isVoid(signature.ret);
		switch (handler.expr) {
			case EFunction(FArrow | FAnonymous, f) if (f.expr != null):
				var body:Array<Expr> = [];
				for (i in 0...f.args.length) {
					var argName:String = f.args[i].name;
					var value:Expr = passed[i];
					body.push(macro var $argName = $value);
				}
				body.push(__returns(f.expr, isVoid));
				return {expr: EBlock(body), pos: handler.pos};
			default:
		}
		var callee:Expr = switch (Context.typeExpr(handler).expr) {
			case TField(_, FStatic(_, _.get() => {kind: FMethod(_)})): handler;
			default:
				var type:ComplexType = TFunction([for (arg in signature.args) arg.opt ? TOptional(TypeTools.toComplexType(arg.t)) : TypeTools.toComplexType(arg.t)], TypeTools.toComplexType(signature.ret));
				statements.push(macro var $name:$type = $handler);
				macro $i{name};
		};
		var call:Expr = {expr: ECall(callee, passed), pos: handler.pos};
		return isVoid ? call : macro return $call;
	}

	/**
		A handler's body as a case's: its returns are the dispatcher's, and in
		a table whose handlers return nothing, the value an arrow function's
		body gives is dropped. A function inside it keeps its own returns.
	**/
	private static function __returns(e:Expr, isVoid:Bool):Expr {
		return switch (e.expr) {
			case EFunction(_, _): e;
			case EReturn(value) if (isVoid && value != null):
				macro {
					${__returns(value, isVoid)};
					return;
				};
			case EMeta({name: ":implicitReturn"}, inner): __returns(inner, isVoid);
			default: ExprTools.map(e, x -> __returns(x, isVoid));
		}
	}

	private static function __refuse(key:Expr):Expr {
		return macro throw new crossbyte.errors.ArgumentError("DispatchTable: no case for " + Std.string($key));
	}

	private static function __argType(arg:FunctionArg, field:Field):Type {
		if (arg.type == null) {
			Context.error('Give ${field.name}\'s argument ${arg.name} its type: a table\'s cases are checked against each other', field.pos);
		}
		return Context.resolveType(arg.type, field.pos);
	}

	private static function __isStatic(field:Field):Bool {
		return field.access != null && field.access.indexOf(AStatic) >= 0;
	}

	private static function __isVoid(type:Type):Bool {
		return switch (Context.follow(type)) {
			case TAbstract(_.get() => {pack: [], name: "Void"}, _): true;
			default: false;
		}
	}
}

private typedef Signature = {
	args:Array<{name:String, opt:Bool, t:Type}>,
	ret:Type
}
#end
