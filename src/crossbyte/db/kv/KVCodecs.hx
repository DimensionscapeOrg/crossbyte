package crossbyte.db.kv;

import crossbyte._internal.Utf8;
import crossbyte.io.ByteArray;
#if !php
import crossbyte.rpc.RPCCodec;
#end
import haxe.Json;
import haxe.io.Bytes;

/**
	The codecs a `KVRepo` reads and writes its values with.

	```haxe
	import crossbyte.db.kv.KVCodec;
	import crossbyte.db.kv.KVCodecs;

	var profiles:KVCodec<{name:String, level:Int}> = KVCodecs.json();
	var names:KVCodec<String> = KVCodecs.text();
	```

	For an `RPCStruct` class, `KVCodecs.rpc(RPCCodecs.of(Ship))` stores
	what the compiled RPC lane sends: a few bytes a field, no names, written
	and read without reflection. Its `schema` is the class's layout, so a
	record written before the class's fields changed is refused rather than
	misread.
**/
class KVCodecs {
	/**
		Values as JSON text (`haxe.Json`): for anonymous structures, arrays,
		strings, numbers and booleans, as a typedef describes them. A class's
		instance is written as its fields and read back as a structure of
		them, without its methods: give a class `rpc` instead.

		@param schema Kept with each value, 0 unless given: raise it when the
		structure's shape changes, so records of the old shape are refused
		rather than read as the new.
	**/
	public static function json<T>(schema:Int = 0):KVCodec<T> {
		return new JsonKVCodec<T>(schema);
	}

	#if !php
	/**
		Values of an `RPCStruct` class in the RPC lane's binary form, through
		its generated codec: `KVCodecs.rpc(RPCCodecs.of(Ship))`. Its schema is
		the codec's `RPCCodec.layout`, which changes exactly when the bytes it
		writes do: a field added, removed, renamed or retyped. Wherever RPC
		is built: not on PHP.
	**/
	public static function rpc<T>(codec:RPCCodec<T>):KVCodec<T> {
		if (codec == null) {
			throw new crossbyte.errors.ArgumentError("KVCodecs.rpc needs a codec: RPCCodecs.of(TheClass).");
		}

		return new RPCKVCodec<T>(codec);
	}
	#end

	/** Values as UTF-8 text. **/
	public static function text(schema:Int = 0):KVCodec<String> {
		return new TextKVCodec(schema);
	}

	/** Values as the bytes they are, copied as they are written. **/
	public static function bytes(schema:Int = 0):KVCodec<Bytes> {
		return new BytesKVCodec(schema);
	}
}

@:noCompletion
private final class JsonKVCodec<T> implements KVCodec<T> {
	public var schema(get, never):Int;

	@:noCompletion private final __schema:Int;

	public function new(schema:Int) {
		__schema = schema;
	}

	public function encode(value:T):Bytes {
		return Utf8.bytesOf(Json.stringify(value));
	}

	public function decode(bytes:Bytes):T {
		// The JSON boundary: the parsed value is the caller's type.
		return cast Json.parse(Utf8.stringOf(bytes, 0, bytes.length, true));
	}

	@:noCompletion private inline function get_schema():Int {
		return __schema;
	}
}

#if !php
@:noCompletion
private final class RPCKVCodec<T> implements KVCodec<T> {
	public var schema(get, never):Int;

	@:noCompletion private final __codec:RPCCodec<T>;

	public function new(codec:RPCCodec<T>) {
		__codec = codec;
	}

	public function encode(value:T):Bytes {
		var out:ByteArray = new ByteArray();
		__codec.write(value, out);
		return (out : Bytes).sub(0, out.length);
	}

	public function decode(bytes:Bytes):T {
		var input:ByteArray = ByteArray.fromBytes(bytes);
		input.position = 0;
		var value:T = __codec.read(input);

		if (input.position != bytes.length) {
			throw '${bytes.length - input.position} bytes past the end of a ${__codec.name}';
		}

		return value;
	}

	@:noCompletion private inline function get_schema():Int {
		return __codec.layout;
	}
}
#end

@:noCompletion
private final class TextKVCodec implements KVCodec<String> {
	public var schema(get, never):Int;

	@:noCompletion private final __schema:Int;

	public function new(schema:Int) {
		__schema = schema;
	}

	public function encode(value:String):Bytes {
		return Utf8.bytesOf(value);
	}

	public function decode(bytes:Bytes):String {
		return Utf8.stringOf(bytes, 0, bytes.length, true);
	}

	@:noCompletion private inline function get_schema():Int {
		return __schema;
	}
}

@:noCompletion
private final class BytesKVCodec implements KVCodec<Bytes> {
	public var schema(get, never):Int;

	@:noCompletion private final __schema:Int;

	public function new(schema:Int) {
		__schema = schema;
	}

	public function encode(value:Bytes):Bytes {
		return value == null ? null : value.sub(0, value.length);
	}

	public function decode(bytes:Bytes):Bytes {
		return bytes;
	}

	@:noCompletion private inline function get_schema():Int {
		return __schema;
	}
}
