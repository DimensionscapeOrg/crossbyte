#if perf_new
/**
	A JSON reader whose objects are built with `crossbyte._internal.AnonBuilder`,
	a builder per shape seen, to price fixed-slot objects against
	`haxe.Json.parse`'s `{}` plus `Reflect.setField` in the path that would use
	them: `ByteArray.readObject` with `ObjectEncoding.JSON`. A measuring device
	for `PerfCore jsonread`, not a proposed parser.
**/
class ShapedJson extends haxe.format.JsonParser {
	static var __shapes:Array<crossbyte._internal.AnonBuilder> = [];

	var __names:Array<String> = [];
	var __values:Array<Dynamic> = [];

	public static function read(text:String):Dynamic {
		return new ShapedJson(text).doParse();
	}

	override function parseRec():Dynamic {
		while (true) {
			var c = nextChar();
			switch (c) {
				case ' '.code, '\r'.code, '\n'.code, '\t'.code:
				case '{'.code:
					var base:Int = __names.length;
					var field:String = null;
					var comma:Null<Bool> = null;
					while (true) {
						var c = nextChar();
						switch (c) {
							case ' '.code, '\r'.code, '\n'.code, '\t'.code:
							case '}'.code:
								if (field != null || comma == false)
									invalidChar();
								return __build(base);
							case ':'.code:
								if (field == null)
									invalidChar();
								__names.push(field);
								__values.push(parseRec());
								field = null;
								comma = true;
							case ','.code:
								if (comma) comma = false else invalidChar();
							case '"'.code:
								if (field != null || comma) invalidChar();
								field = parseString();
							default:
								invalidChar();
						}
					}
				default:
					pos--;
					return super.parseRec();
			}
		}
	}

	function __build(base:Int):Dynamic {
		var count:Int = __names.length - base;
		var names:Array<String> = __names.slice(base);
		var shape:crossbyte._internal.AnonBuilder = null;
		for (candidate in __shapes) {
			if (candidate.matches(names, count)) {
				shape = candidate;
				break;
			}
		}
		if (shape == null) {
			shape = new crossbyte._internal.AnonBuilder(names);
			__shapes.push(shape);
		}
		var object:Dynamic = shape.begin();
		for (i in 0...count) {
			shape.set(object, i, __values[base + i]);
		}
		__names.resize(base);
		__values.resize(base);
		return object;
	}
}
#end
