package crossbyte.io._internal;

/**
	What the compiler knew about the program's name: the `crossbyte_app_id`
	define, and the main class. `System.applicationId` decides between them.
**/
@:build(crossbyte.io._internal.ApplicationIdentityMacro.build())
class ApplicationIdentity {
	/**
		The main class's full name, as `pack.Main`, or null for a build with
		no main class, a library loaded by something else.
	**/
	public static function mainClass():Null<String> {
		var meta:Dynamic = haxe.rtti.Meta.getType(ApplicationIdentity);

		if (meta == null) {
			return null;
		}

		var values:Null<Array<Dynamic>> = Reflect.field(meta, "crossbyteMainClass");
		return values == null || values.length == 0 || values[0] == null ? null : Std.string(values[0]);
	}
}
