package crossbyte.db.kv;

// Built where AsyncDatabase is: not for JavaScript, which has no threads to run a store on.
#if !js
import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.db.AsyncDatabase;
import crossbyte.db.ConnectionPool;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.sys.Task;
import haxe.io.Bytes;
#if target.threaded
import sys.thread.Mutex;
#end

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
	does a job `AsyncDatabase` turns away (past `maxQueued`, or waiting past
	`queueTimeout`) and a write past `maxQueuedBytes`.

	Writes that belong together go in one `transaction`, whose body runs on
	one worker with one store, inside `begin()` and `commit()`: calls made
	one after another here may each go to a different store in the pool.
**/
@:allow(crossbyte.db.kv.AsyncKVRepo)
class AsyncKVStore {
	/** `maxQueuedBytes` unless set: 64 MiB. **/
	public static inline var DEFAULT_MAX_QUEUED_BYTES:Float = 67108864.0;

	/** What runs the calls: the pool of stores and the workers. **/
	public final database:AsyncDatabase<KVStore>;

	/**
		The most bytes of values the writes not yet done may hold between
		them, copied as they were made: `DEFAULT_MAX_QUEUED_BYTES`, 64 MiB,
		unless set, or 0 for no limit. A write past it fails at once, its
		future with an `IllegalOperationError`, without copying its value.

		`AsyncDatabase.maxQueued` bounds how many calls wait for a worker;
		this bounds what they hold, which the values decide: 100,000 waiting
		writes of a megabyte each would be a hundred gigabytes. A store that
		has stopped keeping up shows as refused writes rather than as memory.
		A write is counted from its call until its future is told.

		@throws ArgumentError When set to NaN or a negative number.
	**/
	public var maxQueuedBytes(default, set):Float = DEFAULT_MAX_QUEUED_BYTES;

	/** The bytes of values the writes not yet done hold. **/
	public var queuedBytes(get, never):Float;

	@:noCompletion private var __queuedBytes:Float = 0.0;
	#if target.threaded
	@:noCompletion private final __bytesLock:Mutex = new Mutex();
	#end

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
		return __write(value == null ? 0 : value.length, () -> {
			var own:Bytes = __copy(value);
			return store -> store.put(key, own, schema);
		});
	}

	/** `KVStore.compareAndSet`, on a worker: null when the record was not at `expected`. **/
	public function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Future<Null<KVRecord>> {
		return __write(value == null ? 0 : value.length, () -> {
			var own:Bytes = __copy(value);
			return store -> store.compareAndSet(key, own, expected, schema);
		});
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

	/**
		A write of `size` bytes of values, counted against `maxQueuedBytes`
		until its job is done; `job` makes the body, copying what it keeps,
		once the bytes are let in.
	**/
	@:noCompletion private function __write<R>(size:Int, job:Void->(KVStore->R)):Future<R> {
		if (!__reserve(size)) {
			var refusal = new IllegalOperationError('AsyncKVStore already holds ${__whole(queuedBytes)} bytes of writes not yet done, and a write of $size more '
				+ 'would pass its maxQueuedBytes of ${__whole(maxQueuedBytes)}: refused rather than queued.');
			return Future.failed(refusal.message, refusal);
		}

		return __future(() -> database.submit(job()), size);
	}

	/**
		The task `start` submits, as a future; failed at once when it is
		refused. `size` bytes counted against `maxQueuedBytes` are let go of
		as the task is done, whichever way.
	**/
	@:noCompletion private function __future<R>(start:Void->Task<R>, size:Int = 0):Future<R> {
		var completer:Completer<R> = new Completer<R>();
		var task:Task<R>;

		try {
			task = start();
		} catch (error:Dynamic) {
			// Refused: maxQueued jobs waiting, or the workers stopped.
			__release(size);
			completer.fail(error);
			return completer.future;
		}

		task.onComplete(value -> {
			__release(size);
			completer.complete(value);
		});
		task.onError(error -> {
			__release(size);
			completer.fail(error);
		});
		task.onCancel(() -> {
			__release(size);
			completer.fail("The key/value store's job was cancelled before it ran.");
		});
		return completer.future;
	}

	/** Counts `size` more bytes in, unless that passes `maxQueuedBytes`. **/
	@:noCompletion private function __reserve(size:Int):Bool {
		if (size <= 0) {
			return true;
		}

		#if target.threaded
		__bytesLock.acquire();
		#end
		var limit:Float = maxQueuedBytes;
		var fits:Bool = limit <= 0 || __queuedBytes + size <= limit;

		if (fits) {
			__queuedBytes += size;
		}
		#if target.threaded
		__bytesLock.release();
		#end
		return fits;
	}

	@:noCompletion private function __release(size:Int):Void {
		if (size <= 0) {
			return;
		}

		#if target.threaded
		__bytesLock.acquire();
		#end
		__queuedBytes -= size;
		#if target.threaded
		__bytesLock.release();
		#end
	}

	@:noCompletion private function get_queuedBytes():Float {
		#if target.threaded
		__bytesLock.acquire();
		#end
		var held:Float = __queuedBytes;
		#if target.threaded
		__bytesLock.release();
		#end
		return held;
	}

	@:noCompletion private function set_maxQueuedBytes(value:Float):Float {
		if (!(value >= 0)) {
			throw new ArgumentError('AsyncKVStore.maxQueuedBytes is a number of bytes, 0 for no limit: $value is not one.');
		}

		return maxQueuedBytes = value;
	}

	@:noCompletion private static inline function __whole(value:Float):String {
		return crossbyte.db.kv._internal.KVWrites.whole(value);
	}

	@:noCompletion private static inline function __copy(value:Null<Bytes>):Null<Bytes> {
		return value == null ? null : value.sub(0, value.length);
	}
}
#end
