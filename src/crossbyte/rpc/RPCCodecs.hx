package crossbyte.rpc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/**
	The codecs of structures, for generic code that works with values it
	does not name (see `RPCCodec`).
**/
class RPCCodecs {
	/**
		The codec of a class that implements `RPCStruct`:
		`RPCCodecs.of(OtherShip)` is an `RPCCodec<OtherShip>`, the same one
		each time. Its reader, writer and patches are generated at compile
		time, as a contract's are, and are the ones a contract carrying the
		class uses.

		An anonymous structure has no codec (it cannot be made, copied in
		place or patched), so naming one fails the build, as does any type
		that is not such a class.
	**/
	public static macro function of(type:Expr):Expr {
		final path:String = pathOf(type);
		final pos = type.pos;
		final resolved = try Context.getType(path) catch (_:Dynamic) null;
		if (resolved == null) {
			Context.error('RPCCodecs.of: no type $path.', pos);
		}
		return crossbyte.rpc._internal.RPCPatches.codecOf(resolved, pos);
	}

	#if macro
	static function pathOf(e:Expr):String {
		return switch (e.expr) {
			case EConst(CIdent(name)): name;
			case EField(owner, name): pathOf(owner) + "." + name;
			case EParenthesis(inner): pathOf(inner);
			case _: Context.error("RPCCodecs.of takes a type: RPCCodecs.of(OtherShip).", e.pos);
		}
	}
	#end
}
