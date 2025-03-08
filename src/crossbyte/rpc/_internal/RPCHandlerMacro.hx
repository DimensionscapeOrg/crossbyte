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
		var rpcMethods:Array<Field> = [];

		for (field in fields) {
			if (field.name != "new" && field.meta.exists(m -> m.name == ":rpc")) {
				switch (field.kind) {
					case FFun(method):
						if (method.args.length > 8) {
							Context.error("Field " + field.name + " is limited to no more than 8 parameters", field.pos);
						}
						rpcMethods.push(field);
					default:
						Context.error("Field " + field.name + " is marked as @:rpc but is not a function.", field.pos);
				}
			}
		}

		rpcCount = rpcMethods.length;

		// Generate CallSig variables
		var callSigs:Array<Field> = [];
		rpcMethods.sort((a, b) -> Reflect.compare(a.name, b.name));

		for (i in 0...rpcCount) {
			var field = rpcMethods[i];
			switch (field.kind) {
				case FFun(method):
					callSigs.push(buildCallSig(i, field.name, method.args));
				default:
					Context.error("Unexpected non-function field in @:rpc processing: " + field.name, field.pos);
			}
		}

		var callField = generateCallMethod(rpcMethods);

		return fields.concat(callSigs).concat([callField]);
	}

	private static function buildCallSig(index:Int, name:String, args:Array<FunctionArg>):Field {
		var paramTypes:Array<ComplexType> = [];
		for (arg in args) {
			paramTypes.push(arg.type);
		}
		while (paramTypes.length < 8) {
			paramTypes.push(TPath({pack: [], name: "Dynamic", params: []})); // Fill remaining slots with Dynamic
		}

		var callSigType:ComplexType = TPath({
			pack: [],
			name: "CallSig",
			params: [for (p in paramTypes) TPType(p)]
		});

		return {
			name: name + "_sig",
			access: [APrivate, AStatic, AInline],
			kind: FieldType.FVar(callSigType, macro $v{index + 1}),
			pos: Context.currentPos()
		};
	}

	private static function generateCallMethod(fields:Array<Field>):Field {
		// Create the `call` method that processes calls dynamically
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

		return {
			name: "call",
			access: [AOverride, AInline],
			//meta: [{name: ":generic", pos: Context.currentPos()}],
			kind: FieldType.FFun({
				ret: TPath({pack: [], name: "Void", params: []}),
				params: [
					{name: "P1"}, {name: "P2"}, {name: "P3"}, {name: "P4"},
					{name: "P5"}, {name: "P6"}, {name: "P7"}, {name: "P8"}
				],
				args: [
					{name: "type", type: callSigType},
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

	private static function getSwitchExpr(fields:Array<Field>):Expr {
		var switchCases:Array<Case> = [];
		var argIndex:Array<String> = ["a", "b", "c", "d", "e", "f", "g", "h"];

		for (field in fields) {
			switch (field.kind) {
				case FFun(method):
					var funcName = field.name;
					var sigName = funcName + "_sig";

					var argVars:Array<Expr> = [];
					for (i in 0...method.args.length) {
						argVars.push(macro $i{argIndex[i]});
					}

					var callExpr:Expr = {
						expr: ECall({
							expr: EField({expr: EConst(CIdent("this")), pos: Context.currentPos()}, funcName),
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
}
#end
