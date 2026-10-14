package crossbyte.db.kv;

// Built where AsyncDatabase is: not for JavaScript, which has no threads to run a store on.
#if !js
import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.db.AsyncDatabase;
import crossbyte.db.ConnectionPool;
import crossbyte.errors.ArgumentError;
import crossbyte.sys.Task;
import haxe.io.Bytes;

/**
	A `KVStore` used from a runtime without waiting for it: each call runs on
	a worker thread with a store from a `ConnectionPool`, through an
	`AsyncDatabase`, and answers with a `Future` that completes on the runtime
	that made the call.

	```haxe
	import crossbyte.db.ConnectionPool;
	import crossbyte.db.kv.AsyncKVStore;
	import crossbyte.db.kv.KVStore;
	import crossbyte.db.kv.SQLiteKVStore;
	import haxe.io.Bytes;

	var pool = new ConnectionPool<KVStore>({
		factory: () -> SQLiteKVStore.open("data/game.db"),
		close: store -> store.close(),
		maxSize: 4
	});
	var kv = AsyncKVStore.of(pool);
	kv.put("users/alice", Bytes.ofString("{}")).then(record -> trace('written at ${record.revision}'));
	kv.get("users/alice").then(record -> trace(record == null ? "none" : record.value.toString()));
	```

	A server's runtime that reads its database directly stops for every
	statement: for the disk, the lock another connection holds, the network
	to PostgreSQL. Here only a worker waits. The answer's callbacks run on the
	runtime's thread, so they may touch the runtime's state: at its next pass,
	or at once, by the call that gives one, when the work was done before it
	was given. A call made off any runtime is answered on the worker.

	Each pooled store is its own connection, so give the pool a factory that
	opens one. A `MemoryKVStore` can stand behind it too, the one store for
	every place in the pool, since any thread may use it.

	A value passed in is copied as the call is made, so the caller's buffer
	is theirs again at once. What a store refuses (a key too long, a value
	too large) fails the future with the store's error as its `cause`, as
	does a job `AsyncDatabase` turns away: past `maxQueued`, or waiting past
	`queueTimeout`.

	Writes that belong together go in one `transaction`, whose body runs on
	one worker with one store, inside `begin()` and `commit()`: calls made
	one after another here may each go to a different store in the pool.
**/
class AsyncKVStore {
	/** What runs the calls: the pool of stores and the workers. **/
	public final database:AsyncDatabase<KVStore>;

	/**
		@throws ArgumentError When `database` is null.
	**/
	public function new(database:AsyncDatabase<KVStore>) {
		if (database == null) {
			throw new ArgumentError("An AsyncKVStore needs an AsyncDatabase of stores.");
		}

		this.database = database;
	}

	/**
		An `AsyncKVStore` over `pool`, with a worker for each store it may
		hold unless `workerCount` says otherwise: `AsyncDatabase.of`.
	**/
	public static function of(pool:ConnectionPool<KVStore>, ?workerCount:Int):AsyncKVStore {
		return new AsyncKVStore(AsyncDatabase.of(pool, workerCount));
	}

	/** `KVStore.get`, on a worker. **/
	public function get(key:String):Future<Null<KVRecord>> {
		return submit(store -> store.get(key));
	}

	/** `KVStore.put`, on a worker; `value` copied first. **/
	public function put(key:String, value:Bytes, schema:Int = 0):Future<KVRecord> {
		var own:Bytes = __copy(value);
		return submit(store -> store.put(key, own, schema));
	}

	/** `KVStore.compareAndSet`, on a worker: null when the record was not at `expected`. **/
	public function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Future<Null<KVRecord>> {
		var own:Bytes = __copy(value);
		return submit(store -> store.compareAndSet(key, own, expected, schema));
	}

	/** `KVStore.delete`, on a worker. **/
	public function delete(key:String):Future<Bool> {
		return submit(store -> store.delete(key));
	}

	/** `KVStore.compareAndDelete`, on a worker. **/
	public function compareAndDelete(key:String, expected:Float):Future<Bool> {
		return submit(store -> store.compareAndDelete(key, expected));
	}

	/** `KVStore.scan`, on a worker. **/
	public function scan(?options:KVScanOptions):Future<KVPage<KVRecord>> {
		return submit(store -> store.scan(options));
	}

	/** `KVStore.purgeTombstones`, on a worker. **/
	public function purgeTombstones(before:Float):Future<Int> {
		return submit(store -> store.purgeTombstones(before));
	}

	/**
		Runs `body` on a worker with one store, inside a transaction: committed
		when it returns, rolled back when it throws, which fails the future
		with what it threw. Its answer is the future's.
	**/
	public function transaction<R>(body:KVStore->R):Future<R> {
		if (body == null) {
			throw new ArgumentError("AsyncKVStore.transaction needs a body.");
		}

		return __future(() -> database.transaction(store -> store.begin(), store -> store.commit(), store -> store.rollback(), body));
	}

	/**
		Runs `body` on a worker with a store from the pool, and answers what
		it answers: for several calls on one store, read in one go. Use
		`transaction` for writes that must land together.
	**/
	public function submit<R>(body:KVStore->R):Future<R> {
		if (body == null) {
			throw new ArgumentError("AsyncKVStore.submit needs a body.");
		}

		return __future(() -> database.submit(body));
	}

	/** Stops the workers and closes the pool's stores: `AsyncDatabase.shutdown`. **/
	public function shutdown(drain:Bool = true):Void {
		database.shutdown(drain);
	}

	/** The task `start` submits, as a future; failed at once when it is refused. **/
	@:noCompletion private static function __future<R>(start:Void->Task<R>):Future<R> {
		var completer:Completer<R> = new Completer<R>();
		var task:Task<R>;

		try {
			task = start();
		} catch (error:Dynamic) {
			// Refused: maxQueued jobs waiting, or the workers stopped.
			completer.fail(error);
			return completer.future;
		}

		task.onComplete(value -> completer.complete(value));
		task.onError(error -> completer.fail(error));
		task.onCancel(() -> completer.fail("The key/value store's job was cancelled before it ran."));
		return completer.future;
	}

	@:noCompletion private static inline function __copy(value:Null<Bytes>):Null<Bytes> {
		return value == null ? null : value.sub(0, value.length);
	}
}
#end
