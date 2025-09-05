package crossbyte.rpc._internal;

import crossbyte.utils.Hash;
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ComplexTypeTools;

using haxe.macro.Tools;

class RPCCommandMacro {
	private static function initWriters():Map<String, (Expr, Expr) -> Expr> {
		var m = new Map<String, (Expr, Expr) -> Expr>();

		m.set("Int", function(out, v) return macro {
			$out.reserve(4);
			$out.writeInt($v);
		});
		m.set("Bool", function(out, v) return macro {
			$out.reserve(1);
			$out.writeByte($v ? 1 : 0);
		});
		m.set("Float", function(out, v) return macro {
			$out.reserve(8);
			$out.writeDouble($v);
		});
		m.set("String", function(out, v) return macro {
			$out.writeVarUTF($v);
		});
		m.set("haxe.io.Bytes", function(out, v) return macro {
			$out.writeVarUInt($v.length);
			$out.reserve($v.length);
			$out.write($v);
		});

		return m;
	}

	private static final TYPE_WRITERS:Map<String, (Expr, Expr) -> Expr> = initWriters();

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var newFields:Array<Field> = [];
		for (field in fields) {
			if (field.name != "new" && field.meta.filter(m -> m.name == ":rpc").length > 0) {
				switch (field.kind) {
					case FFun(method):
						var metaName = "meta_" + field.name;

						field.kind = createWrapperFunction(field, metaName, method.args).kind;

						var metaField = createMetaFunction(metaName, field.name, method.args, field.pos);
						newFields.push(metaField);
					default:
						Context.error("Field " + field.name + " is marked as :rpc but is not a function.", field.pos);
				}
			}
		}

		injectPing(newFields, Context.currentPos());

		return fields.concat(newFields);
	}

	private static function createMetaFunction(metaName:String, commandName:String, args:Array<FunctionArg>, errPos:Position):Field {
		var argNames = args.map(a -> macro $i{a.name});
		var statements:Array<Expr> = [];
		var opCode:Int = Hash.fnv1a32(haxe.io.Bytes.ofString(commandName));
		statements.push(macro var payload:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(4));
		statements.push(macro payload.writeInt($v{opCode}));

		for (i in 0...args.length) {
			statements.push(writerForArg(args[i], errPos));
		}

		statements.push(macro payload.flush());
		statements.push(macro var framed:crossbyte.io.ByteArrayOutput = new crossbyte.io.ByteArrayOutput(payload.length + 4));
		statements.push(macro framed.writeInt(payload.length));
		statements.push(macro framed.writeBytes(payload));
		statements.push(macro connection.send(framed));

		return {
			name: metaName,
			doc: "Auto-generated RPC meta for " + commandName,
			access: [APrivate, AInline],
			kind: FFun({
				args: [{name: "connection", type: macro :crossbyte.net.NetConnection}].concat(args),
				expr: macro {$b{statements};},
				ret: macro :Void
			}),
			pos: Context.currentPos()
		};
	}

	private static function createWrapperFunction(field:Field, metaName:String, args:Array<FunctionArg>):Field {
		var callArgs:Array<Expr> = [macro this.__nc].concat(args.map(a -> macro $i{a.name}));

		var retType:ComplexType = switch (field.kind) {
			case FFun(f) if (f.ret != null): f.ret;
			case _: macro :Void;
		};

		return {
			name: field.name,
			doc: "Replaced existing method with auto-generated RPC wrapper for: " + field.name,
			access: field.access.concat([AInline]),
			kind: FFun({
				args: args,
				expr: macro $i{metaName}($a{callArgs}),
				ret: retType
			}),
			pos: field.pos
		};
	}

	private static function writerForArg(a:FunctionArg, errPos:Position):Expr {
		var ct:ComplexType = a.type;
		if (ct == null)
			Context.error("RPC arg '" + a.name + "' must have an explicit type.", errPos);

		var isOpt = a.opt || isNullWrapped(ct);
		var base = unwrapNull(ct);
		var key = typeKey(base);

		var fn = TYPE_WRITERS.get(key);
		if (fn == null)
			Context.error("Unsupported RPC arg type for '" + a.name + "': " + key, errPos);

		var valueExpr:Expr = macro $i{a.name};

		var writeValue:Expr = fn(macro payload, valueExpr);

		return isOpt ? macro {
			if ($valueExpr == null)
				payload.writeByte(0);
			else {
				payload.writeByte(1);
				$writeValue;
			}
		} : writeValue;
	}

	private static inline function isNullWrapped(ct:ComplexType):Bool {
		return switch (ct) {
			case TPath({name: "Null", params: _}): true;
			case _: false;
		}
	}

	private static inline function unwrapNull(ct:ComplexType):ComplexType {
		return switch (ct) {
			case TPath({name: "Null", params: [TPType(inner)]}): inner;
			case _: ct;
		}
	}

	private static function typeKey(ct:ComplexType):String {
		return switch (ct) {
			case TPath(tp):
				var pack:String = tp.pack.length > 0 ? tp.pack.join(".") + "." : "";
				pack + tp.name;
			case _: ComplexTypeTools.toString(ct);
		}
	}

	private static function injectPing(newFields:Array<Field>, pos:Position):Void {
		var pingName = "ping";
		var metaName = "meta_ping";

		var args:Array<FunctionArg> = [];

		var wrapper = createWrapperFunction({
			name: pingName,
			access: [APublic],
			kind: FFun({
				args: null,
				ret: macro :Void,
				expr: null
			}),
			pos: pos,
			meta: null,
			doc: "System reserved RPC ping()."
		}, metaName, args);

		var meta = createMetaFunction(metaName, pingName, args, pos);

		newFields.push(wrapper);
		newFields.push(meta);
	}
}
#end
