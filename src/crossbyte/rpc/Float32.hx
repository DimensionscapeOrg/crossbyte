package crossbyte.rpc;

#if (cpp || java || cs || hl)
/**
	A single-precision float, IEEE 754 binary32: four bytes on the RPC wire,
	little-endian, where a `Float` takes eight. For positions, velocities,
	angles (anything a game sends many of and for which seven significant
	digits are enough), that a signature or a field of an `RPCStruct`
	declares as this type.

	Haxe's own `Single` where the target has one (natively, on the jvm and
	on HashLink), so a value is rounded to single precision as it is
	assigned. Elsewhere (JavaScript, the interpreter, neko), which have no
	`Single`, it is a `Float`, rounded to single precision as it is sent:
	what arrives is the same on every target. A contract that declares
	`Single` itself is carried the same way, but builds only on the targets
	that have it; declare `Float32` to build everywhere.

	```haxe
	import crossbyte.rpc.Float32;

	var speed:Float32 = 4.5;
	var asFloat:Float = speed;
	```
**/
typedef Float32 = Single;
#else
/**
	A single-precision float, IEEE 754 binary32: four bytes on the RPC wire,
	little-endian, where a `Float` takes eight. For positions, velocities,
	angles (anything a game sends many of and for which seven significant
	digits are enough), that a signature or a field of an `RPCStruct`
	declares as this type.

	Haxe's own `Single` where the target has one (natively, on the jvm and
	on HashLink), so a value is rounded to single precision as it is
	assigned. Elsewhere (JavaScript, the interpreter, neko), which have no
	`Single`, it is a `Float`, rounded to single precision as it is sent:
	what arrives is the same on every target. A contract that declares
	`Single` itself is carried the same way, but builds only on the targets
	that have it; declare `Float32` to build everywhere.

	```haxe
	import crossbyte.rpc.Float32;

	var speed:Float32 = 4.5;
	var asFloat:Float = speed;
	```
**/
abstract Float32(Float) from Float to Float {}
#end
