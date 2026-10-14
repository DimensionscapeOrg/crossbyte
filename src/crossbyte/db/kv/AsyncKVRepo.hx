package crossbyte.db.kv;

// Built where AsyncKVStore is: not for JavaScript.
#if !js
import crossbyte.Future;
import crossbyte.db.kv._internal.KVKeys;
import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	A `KVRepo` used from a runtime without waiting for it: typed values under
	a key prefix, each call run on an `AsyncKVStore`'s workers and answered
	with a `Future` on the runtime that made it.

	```haxe
	import crossbyte.db.kv.AsyncKVRepo;
	import crossbyte.db.kv.AsyncKVStore;
	import crossbyte.db.kv.KVCodecs;

	// Given kv:AsyncKVStore.
	var players = new AsyncKVRepo<{name:String, level:Int}>(kv, "players/", KVCodecs.json());
	players.put("alice", {name: "Alice", level: 1})
		.flatMap(saved -> players.compareAndSet("alice", {name: "Alice", level: 2}, saved.revision))
		.then(written -> trace(written == null ? "someone wrote it first" : "level 2"));
	```

	A value is encoded as the call is made, on the calling thread, so the
	caller may change it at once; it is decoded on the worker, so the
	runtime's thread does neither the reading nor the decoding. A record of
	another schema, or that its codec cannot read, fails the future with the
	`KVError` as its `cause`, as `KVRepo` throws it.
**/
class AsyncKVRepo<T> {
	/** The store its calls run on. **/
	public final store:AsyncKVStore;

	/** What every key of its records starts with in the store; it may be empty. **/
	public final prefix:String;

	/** How its values are written and read. **/
	public final codec:KVCodec<T>;

	/**
		@throws ArgumentError When `store` or `codec` is null, or `prefix`
		holds what no key may.
	**/
	public function new(store:AsyncKVStore, prefix:String, codec:KVCodec<T>) {
		if (store == null || codec == null) {
			throw new ArgumentError("An AsyncKVRepo needs a store and a codec.");
		}

		KVKeys.check(prefix, KVOptions.MOST_KEY_BYTES, "A repository's prefix", true);
		this.store = store;
		this.prefix = prefix;
		this.codec = codec;
	}

	/** `KVRepo.get`, on a worker. **/
	public function get(key:String):Future<Null<KVItem<T>>> {
		var prefix:String = this.prefix;
		var codec:KVCodec<T> = this.codec;
		return store.submit(function(kv:KVStore):Null<KVItem<T>> {
			var record:Null<KVRecord> = kv.get(prefix + key);
			return record == null ? null : KVRepo.__item(record, prefix, codec);
		});
	}

	/** `KVRepo.put`, on a worker; `value` encoded first. **/
	public function put(key:String, value:T):Future<KVItem<T>> {
		var encoded:Bytes;

		try {
			encoded = codec.encode(value);
		} catch (error:Dynamic) {
			return Future.failed('The value for $key cannot be written: ${Std.string(error)}', error);
		}

		var full:String = prefix + key;
		var schema:Int = codec.schema;
		return store.submit(function(kv:KVStore):KVItem<T> {
			var record:KVRecord = kv.put(full, encoded, schema);
			return new KVItem(key, value, record.revision, record.createdAt, record.updatedAt);
		});
	}

	/** `KVRepo.compareAndSet`, on a worker: null when the record was not at `expected`. **/
	public function compareAndSet(key:String, value:T, expected:Float):Future<Null<KVItem<T>>> {
		var encoded:Bytes;

		try {
			encoded = codec.encode(value);
		} catch (error:Dynamic) {
			return Future.failed('The value for $key cannot be written: ${Std.string(error)}', error);
		}

		var full:String = prefix + key;
		var schema:Int = codec.schema;
		return store.submit(function(kv:KVStore):Null<KVItem<T>> {
			var record:Null<KVRecord> = kv.compareAndSet(full, encoded, expected, schema);
			return record == null ? null : new KVItem(key, value, record.revision, record.createdAt, record.updatedAt);
		});
	}

	/** `KVRepo.delete`, on a worker. **/
	public function delete(key:String):Future<Bool> {
		return store.delete(prefix + key);
	}

	/** `KVRepo.compareAndDelete`, on a worker. **/
	public function compareAndDelete(key:String, expected:Float):Future<Bool> {
		return store.compareAndDelete(prefix + key, expected);
	}

	/** `KVRepo.scan`, on a worker. **/
	public function scan(?options:KVScanOptions):Future<KVPage<KVItem<T>>> {
		var scan:KVScanOptions;

		try {
			scan = KVRepo.__inStore(prefix, options);
		} catch (error:Dynamic) {
			return Future.failed(Std.string(error), error);
		}

		var prefix:String = this.prefix;
		var codec:KVCodec<T> = this.codec;
		return store.submit(kv -> KVRepo.__page(kv.scan(scan), prefix, codec));
	}
}
#end
