package crossbyte.rpc._internal;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using haxe.macro.Tools;

class RPCCommandMacro {
    public static function build():Array<Field> {
        var fields = Context.getBuildFields();
        var newFields:Array<Field> = [];

        for (field in fields) {
            if (field.name != "new" && field.meta.filter(m -> m.name == ":rpc").length > 0) {
                switch (field.kind) {
                    case FFun(method):
                        var metaName = "meta_" + field.name;

                        // Replace the existing method with the wrapper instead of adding a duplicate.
                        field.kind = createWrapperFunction(field, metaName, method.args).kind;

                        var metaField = createMetaFunction(metaName, field.name, method.args);
                        newFields.push(metaField);
                    default:
                        Context.error("Field " + field.name + " is marked as :rpc but is not a function.", field.pos);
                }
            }
        }

        return fields.concat(newFields);
    }

    private static function createMetaFunction(
        metaName:String, 
        commandName:String, 
        args:Array<FunctionArg>
    ):Field {
        var argNames = args.map(a -> macro $i{a.name});

        return {
            name: metaName,
            doc: "Auto-generated RPC meta for " + commandName,
            access: [APrivate, AStatic, AInline],
            kind: FFun({
                args: [{ name: "__nc", type: macro : crossbyte.net.NetConnection }].concat(args),
                expr: macro {
                   /*  var packet = new crossbyte.io.ByteArray();
                    packet.writeUTF($v{commandName});
                    for (arg in $a{argNames}) {
                        packet.writeUTF(Std.string(arg));
                    }
                    nc.send(packet); */

                    trace("it worked!", $a{argNames}[0], __nc);
                },
                ret: macro : Void
            }),
            pos: Context.currentPos()
        };
    }

    private static function createWrapperFunction(
        field:Field, 
        metaName:String, 
        args:Array<FunctionArg>
    ):Field {
        var argNames = args.map(a -> macro $i{a.name});

        return {
            name: field.name,
            doc: "Replaced existing method with auto-generated RPC wrapper for: " + field.name,
            access: field.access.concat([AInline]),
            kind: FFun({
                args: args,
                expr: macro {
                    $i{metaName}(this.__nc, $a{argNames}[0]);
                },
                ret: macro : Void
            }),
            pos: field.pos
        };
    }
}
#end