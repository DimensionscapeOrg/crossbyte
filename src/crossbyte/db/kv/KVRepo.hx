package crossbyte.db.kv;

import crossbyte.db.kv._internal.KVKeys;
import crossbyte.errors.ArgumentError;

/**
	Typed values in a `KVStore`: the records under one key prefix, each value
	written and read through a `KVCodec`, with the codec's schema kept beside
	it and checked as it is read.

	```haxe
	import crossbyte.db.kv.KVCodecs;
	import crossbyte.db.kv.KVRepo;
	import crossbyte.db.kv.MemoryKVStore;

	var profiles = new KVRepo<{name:String, level:Int}>(new MemoryKVStore(), "profiles/", KVCodecs.json());
	var saved = profiles.put("alice", {name: "Alice", level: 1});
	var read = profiles.get("alice"); // read.value.level == 1, read.key == "alice"
	profiles.compareAndSet("alice", {name: "Alice", level: 2}, saved.revision);
	```

	Keys are the repository's own: `"alice"` above is the store's
	`"profiles/alice"`, and what it reads back has the prefix taken off.
	Several repositories with different prefixes share one store, as etcd's
	clients share one keyspace through its namespaces.

	A record written with another schema than the codec's (another
	`RPCStruct` layout, a JSON schema number raised since) is refused with a
	`KVError` of `SchemaMismatch`, naming the key, and one the codec cannot
	read with `Undecodable`. A codec that cannot write a value throws what
	it throws (an `RPCStruct` field out of its range, an `ArgumentError`).

	**Threading.** As its store's; the codec may be shared.
**/
class KVRepo<T> {
	/** The store it keeps its records in. **/
	public final store:KVStore;

	/** What every key of its records starts with in the store; it may be empty. **/
	public final prefix:String;

	/** How its values are written and read. **/
	public final codec:KVCodec<T>;

	/**
		@throws ArgumentError When `store` or `codec` is null, or `prefix`
		holds what no key may.
	**/
	public function new(store:KVStore, prefix:String, codec:KVCodec<T>) {
		if (store == null || codec == null) {
			throw new ArgumentError("A KVRepo needs a store and a codec.");
		}

		KVKeys.check(prefix, KVOptions.MOST_KEY_BYTES, "A repository's prefix", true);
		this.store = store;
		this.prefix = prefix;
		this.codec = codec;
	}

	/**
		The value under `key`, or null when there is none.

		@throws KVError `SchemaMismatch` or `Undecodable` for a record this
		codec does not read; `TooLarge` as `KVStore.get`.
	**/
	public function get(key:String):Null<KVItem<T>> {
		var record:Null<KVRecord> = store.get(prefix + key);
		return record == null ? null : __item(record, prefix, codec);
	}

	/** Writes `value` under `key`, whatever is there; as `KVStore.put`. **/
	public function put(key:String, value:T):KVItem<T> {
		var record:KVRecord = store.put(prefix + key, codec.encode(value), codec.schema);
		return new KVItem(key, value, record.revision, record.createdAt, record.updatedAt);
	}

	/**
		Writes `value` under `key` only if its record is at revision
		`expected` (0: only if there is none); null when it was not. As
		`KVStore.compareAndSet`.
	**/
	public function compareAndSet(key:String, value:T, expected:Float):Null<KVItem<T>> {
		var record:Null<KVRecord> = store.compareAndSet(prefix + key, codec.encode(value), expected, codec.schema);
		return record == null ? null : new KVItem(key, value, record.revision, record.createdAt, record.updatedAt);
	}

	/** Deletes the value under `key`; as `KVStore.delete`. **/
	public function delete(key:String):Bool {
		return store.delete(prefix + key);
	}

	/** Deletes the value under `key` only at revision `expected`; as `KVStore.compareAndDelete`. **/
	public function compareAndDelete(key:String, expected:Float):Bool {
		return store.compareAndDelete(prefix + key, expected);
	}

	/**
		The values in key order a page at a time, as `KVStore.scan` reads
		records: `options`' bounds are keys within the repository, and the
		page's `next` is one too. A repository reads values, so asking for
		tombstones is refused: scan the store for those.

		@throws ArgumentError As `KVStore.scan`, and for `includeTombstones`.
		@throws KVError As `get`, for any record of the page.
	**/
	public function scan(?options:KVScanOptions):KVPage<KVItem<T>> {
		var page:KVPage<KVRecord> = store.scan(__inStore(prefix, options));
		return __page(page, prefix, codec);
	}

	/** `options`, its bounds within the store. **/
	@:noCompletion public static function __inStore(prefix:String, options:Null<KVScanOptions>):KVScanOptions {
		var scan:KVScanOptions = options == null ? ({} : KVScanOptions) : options;

		if (scan.includeTombstones) {
			throw new ArgumentError("A repository reads values, and a tombstone has none: scan its store with includeTombstones for those.");
		}

		return {
			prefix: scan.prefix == null ? prefix : prefix + scan.prefix,
			startAt: scan.startAt == null ? null : prefix + scan.startAt,
			startAfter: scan.startAfter == null ? null : prefix + scan.startAfter,
			endBefore: scan.endBefore == null ? null : prefix + scan.endBefore,
			limit: scan.limit
		};
	}

	@:noCompletion public static function __page<T>(page:KVPage<KVRecord>, prefix:String, codec:KVCodec<T>):KVPage<KVItem<T>> {
		var items:Array<KVItem<T>> = [for (record in page.items) __item(record, prefix, codec)];
		return new KVPage(items, page.more, page.next == null ? null : page.next.substr(prefix.length));
	}

	/** `record` decoded, its key within the repository; refused when its schema is not the codec's, or the codec cannot read it. **/
	@:noCompletion public static function __item<T>(record:KVRecord, prefix:String, codec:KVCodec<T>):KVItem<T> {
		if (record.schema != codec.schema) {
			throw new KVError(SchemaMismatch, record.key,
				'${record.key} was written with schema ${record.schema}, and this codec reads schema ${codec.schema}: it is refused rather than read as another format. '
				+ 'For an RPCStruct value, the class\'s fields have changed since it was written.');
		}

		var value:T;

		try {
			value = codec.decode(record.value);
		} catch (e:Dynamic) {
			throw new KVError(Undecodable, record.key, '${record.key} is not a value its codec reads: ${Std.string(e)}');
		}

		return new KVItem(record.key.substr(prefix.length), value, record.revision, record.createdAt, record.updatedAt);
	}
}
