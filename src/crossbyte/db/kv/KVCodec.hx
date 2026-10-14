package crossbyte.db.kv;

import haxe.io.Bytes;

/**
	How a `KVRepo` turns its values into a record's bytes and back, and the
	fingerprint of that format, kept beside each value it writes.
	`KVCodecs` makes the usual ones: JSON, an `RPCStruct` class's binary
	codec, plain text and bytes.

	**Threading.** A codec may be used by several threads at once: keep
	none of a call's state in it.
**/
interface KVCodec<T> {
	/**
		The fingerprint of the format, 0 for none: stored as each record's
		`KVRecord.schema`, and a record whose schema is not this one is
		refused as it is read (`KVError` `SchemaMismatch`) rather than read
		as this format. For an `RPCStruct` value, its layout.
	**/
	var schema(get, never):Int;

	/** `value` as bytes. **/
	function encode(value:T):Bytes;

	/** The value `bytes` holds; throws when they are not one. **/
	function decode(bytes:Bytes):T;
}
