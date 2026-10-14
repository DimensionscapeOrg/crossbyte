package crossbyte.db.kv;

import haxe.io.Bytes;

/**
	One record of a `KVStore`: a key's value as it stands, with its revision
	and when it was made and last written.

	A record read from a store is the caller's: its `value` is bytes of its
	own, and changing them changes nothing stored.
**/
final class KVRecord {
	/** The key. **/
	public final key:String;

	/** The value. Empty for a tombstone. **/
	public final value:Bytes;

	/**
		The record's revision: 1 when the key is first written, and one more
		with each write after, a delete included. It goes on counting through
		a delete and a write after it, so a revision once read is never the
		revision of a later value (see `KVStore.compareAndSet`), until
		`KVStore.purgeTombstones` removes the tombstone. A whole number, exact
		to 2^53.
	**/
	public final revision:Float;

	/**
		When this life of the key began, in seconds since the epoch: its first
		write, or its first write after it was deleted.
	**/
	public final createdAt:Float;

	/** When it was last written, its delete included, in seconds since the epoch. **/
	public final updatedAt:Float;

	/**
		The fingerprint of the value's format it was written with, 0 for
		none, so a reader can refuse a record written in a format it does not
		read rather than misread it: a `KVRepo` keeps its codec's
		`KVCodec.schema` here, and refuses a record under another.
	**/
	public final schema:Int;

	/**
		Whether this is what a delete leaves: the key's revision, kept so a
		compare-and-set cannot take the next value for the one deleted. Only a
		scan that asks for them returns tombstones.
	**/
	public final tombstone:Bool;

	public function new(key:String, value:Bytes, revision:Float, createdAt:Float, updatedAt:Float, schema:Int, tombstone:Bool) {
		this.key = key;
		this.value = value;
		this.revision = revision;
		this.createdAt = createdAt;
		this.updatedAt = updatedAt;
		this.schema = schema;
		this.tombstone = tombstone;
	}

	/** The key and revision, and the value's size, for a log: never the value. **/
	public function toString():String {
		return 'KVRecord($key, revision ${crossbyte.db.kv._internal.KVWrites.whole(revision)}${tombstone ? ", tombstone" : ", " + value.length + " bytes"})';
	}
}
