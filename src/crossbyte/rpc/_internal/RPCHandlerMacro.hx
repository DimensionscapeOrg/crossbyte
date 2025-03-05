package crossbyte.rpc._internal;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;
using haxe.macro.TypeTools;

class RPCHandlerMacro {
	private static var rpcCount:Int = 0;

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var newFields:Array<Field> = [];

		for (field in fields) {
			if (field.name != "new" && field.meta.filter(m -> m.name == ":rpc").length > 0) {
				switch (field.kind) {
					case FFun(method):
						var metaName = "meta_" + field.name;
						var metaField = createMetaFunction(metaName, field.name, method.args, method.expr);
						newFields.push(metaField);
					default:
						Context.error("Field " + field.name + " is marked as :rpc but is not a function.", field.pos);
				}
			}
		}
		rpcCount = newFields.length;

		var callSigs:Array<Field> = [];
		newFields.sort((a, b) -> Reflect.compare(a.name, b.name));

		// 🔹 Generate CallSig variables
		for (i in 0...rpcCount) {
			var field = newFields[i];
			// var params = field.kind.getParameters();

			switch (field.kind) {
				case FFun(method): // Correct way to extract function parameters
					var params = method.args; // Get function arguments
					if (params.length > 8) {
						Context.error("Field " + field.name + " is limited to no more than 8 parameters", field.pos);
					}
					callSigs.push(buildCallSig(i, field.name, params));
				default:
					Context.error("Unexpected non-function field in @:rpc processing: " + field.name, field.pos);
			}

			// callSigs.push(buildCallSig(i, field.name, params));
		}

		var callField = overrideCallMethod();
		var staticCallField = getStaticCallMethod(newFields);

		return fields.concat(newFields).concat([callField, staticCallField]).concat(callSigs);
	}

	private static function buildCallSig(index:Int, name:String, args:Array<FunctionArg>):Field {
		// Extract argument types and ensure we have exactly 8 parameters
		var paramTypes:Array<ComplexType> = [];
		for (arg in args) {
			paramTypes.push(arg.type);
		}
		while (paramTypes.length < 8) {
			paramTypes.push(TPath({pack: [], name: "Dynamic", params: []})); // Fill remaining slots with Dynamic
		}

		// Construct CallSig type
		var callSigType:ComplexType = TPath({
			pack: [],
			name: "CallSig",
			params: [for (p in paramTypes) TPType(p)] // Convert ComplexTypes into TypeParams
		});

		return {
			name: name + "_sig", // e.g., "movePlayer_sig"
			access: [APrivate, AStatic, AInline],
			kind: FieldType.FVar(callSigType, //  Assign CallSig<P1, ..., P8>
				macro $v{index + 1} //  Assign a deterministic integer ID
			),
			pos: Context.currentPos()
		};
	}

	private static function getStaticCallMethod(fields:Array<Field>):Field {
		// Construct CallSig type correctly
		var typeParams:Array<TypeParam> = [
			TPType(TPath({pack: [], name: "P1", params: []})),
			TPType(TPath({pack: [], name: "P2", params: []})),
			TPType(TPath({pack: [], name: "P3", params: []})),
			TPType(TPath({pack: [], name: "P4", params: []})),
			TPType(TPath({pack: [], name: "P5", params: []})),
			TPType(TPath({pack: [], name: "P6", params: []})),
			TPType(TPath({pack: [], name: "P7", params: []})),
			TPType(TPath({pack: [], name: "P8", params: []}))
		];

		var callSigType:ComplexType = TPath({
			pack: [],
			name: "CallSig",
			params: typeParams
		});

		// 🔹 Generate `override call()` (Instance method that forwards to meta_call)
		return {
			name: "meta_call",
			access: [APrivate, AStatic],
			meta: [{name: ":generic", pos: Context.currentPos()}], // ✅ Add @:generic here
			kind: FieldType.FFun({
				ret: TPath({pack: [], name: "Void", params: []}), // ✅ Fixed return type
				params: [
					// ✅ Fix: Now using TypeParamDecl
					{name: "P1"},
					{name: "P2"},
					{name: "P3"},
					{name: "P4"},
					{name: "P5"},
					{name: "P6"},
					{name: "P7"},
					{name: "P8"}
				],
				args: [
					{name: "type", type: callSigType}, // ✅ Fixed CallSig Type
					{name: "a", type: TPath({pack: [], name: "P1", params: []})},
					{name: "b", type: TPath({pack: [], name: "P2", params: []})},
					{name: "c", type: TPath({pack: [], name: "P3", params: []})},
					{name: "d", type: TPath({pack: [], name: "P4", params: []})},
					{name: "e", type: TPath({pack: [], name: "P5", params: []})},
					{name: "f", type: TPath({pack: [], name: "P6", params: []})},
					{name: "g", type: TPath({pack: [], name: "P7", params: []})},
					{name: "h", type: TPath({pack: [], name: "P8", params: []})}
				],
				expr: getSwitchExpr(fields)
			}),
			pos: Context.currentPos()
		};
	}

	private static var argIndex:Array<String> = ["a", "b", "c", "d", "e", "f","g","h"];
	private static function getSwitchExpr(fields:Array<Field>):Expr {
		var switchCases:Array<Case> = [];

		for (field in fields) {
			switch (field.kind) {
				case FFun(method):
					var funcName = field.name;
					var sigName = funcName + "_sig";

					// Directly reference arguments (arg0, arg1, ..., arg7)
					var argVars:Array<Expr> = [];
					for (i in 0...method.args.length) {
						argVars.push(macro $i{argIndex[i]}); // Correct way to generate arg0, arg1, ..., arg7
					}

					// Fill remaining arguments with `null` if unused
			//		while (argVars.length < 7) {
						//argVars.push(macro null);
				//	}

					var className = Context.getLocalClass().get().name;

					// Correct function call using explicitly named arguments
					var callExpr:Expr = {
						expr: ECall({
							expr: EField({expr: EConst(CIdent(className)), pos: Context.currentPos()}, funcName),
							pos: Context.currentPos()
						}, argVars),
						pos: Context.currentPos()
					};

					switchCases.push({
						values: [macro $i{sigName}],
						expr: callExpr
					});

				case _:
			}
		}

		return {
			expr: ESwitch(macro type, switchCases, null),
			pos: Context.currentPos()
		};
	}

	private static function overrideCallMethod():Field {
		var superType = Context.getLocalClass().get().superClass;
		var fields = superType.t.get().fields.get();
		var hasCall:Bool = fields.filter(f -> f.name == "call").length > 0;

		if (hasCall) {
			// Construct CallSig type correctly
			var typeParams:Array<TypeParam> = [
				TPType(TPath({pack: [], name: "P1", params: []})),
				TPType(TPath({pack: [], name: "P2", params: []})),
				TPType(TPath({pack: [], name: "P3", params: []})),
				TPType(TPath({pack: [], name: "P4", params: []})),
				TPType(TPath({pack: [], name: "P5", params: []})),
				TPType(TPath({pack: [], name: "P6", params: []})),
				TPType(TPath({pack: [], name: "P7", params: []})),
				TPType(TPath({pack: [], name: "P8", params: []}))
			];

			var callSigType:ComplexType = TPath({
				pack: [],
				name: "CallSig",
				params: typeParams
			});

			// 🔹 Generate `override call()` (Instance method that forwards to meta_call)
			return {
				name: "call",
				access: [Access.AOverride, AInline],
				meta: [{name: ":generic", pos: Context.currentPos()}], // ✅ Add @:generic here
				kind: FieldType.FFun({
					ret: TPath({pack: [], name: "Void", params: []}), // ✅ Fixed return type
					params: [
						// ✅ Fix: Now using TypeParamDecl
						{name: "P1"},
						{name: "P2"},
						{name: "P3"},
						{name: "P4"},
						{name: "P5"},
						{name: "P6"},
						{name: "P7"},
						{name: "P8"}
					],
					args: [
						{name: "type", type: callSigType}, // ✅ Fixed CallSig Type
						{name: "a", type: TPath({pack: [], name: "P1", params: []})},
						{name: "b", type: TPath({pack: [], name: "P2", params: []})},
						{name: "c", type: TPath({pack: [], name: "P3", params: []})},
						{name: "d", type: TPath({pack: [], name: "P4", params: []})},
						{name: "e", type: TPath({pack: [], name: "P5", params: []})},
						{name: "f", type: TPath({pack: [], name: "P6", params: []})},
						{name: "g", type: TPath({pack: [], name: "P7", params: []})},
						{name: "h", type: TPath({pack: [], name: "P8", params: []})}
					],
					expr: macro {
						$i{"meta_call"}(type, a, b, c, d, e, f, g, h);
					}
					
				}),
				pos: Context.currentPos()
			};
		}

		return null;
	}

	private static function createMetaFunction(metaName:String, commandName:String, args:Array<FunctionArg>, expr:Expr):Field {
		var argNames = args.map(a -> macro $i{a.name});

		return {
			name: metaName,
			doc: "Auto-generated RPC meta for " + commandName,
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: args,
				expr: expr,
				ret: macro :Void
			}),
			pos: Context.currentPos()
		};
	}
}
#end
