package crossbyte;

/**
 * ...
 * @author Christopher Speciale
 */
@:transitive
@:callable
@:generic
@:forward
abstract Object(Dynamic) from Dynamic to Dynamic {
	public inline function new() {
		this = {};
	}

	@:noCompletion @:dox(hide) public function iterator():Iterator<String> {
		if (#if (haxe_ver >= 4.2) Std.isOfType #else Std.is #end (this, Array)) {
			var arr:Array<Dynamic> = cast this;
			return arr.iterator();
		} else {
			var fields = Reflect.fields(this);
			if (fields == null)
				fields = [];

			return fields.iterator();
		}
	}
}
