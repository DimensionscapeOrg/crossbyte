package crossbyte.io;

import crossbyte.Future;
import crossbyte.errors.ArgumentError;
import crossbyte.io._internal.store.IStoreBackend;
import crossbyte.io._internal.store.StoreBackend;

/**
 * Durable key/value storage, on every target CrossByte builds for.
 *
 * Keys are strings, values are bytes, and there are no queries. That is
 * deliberately the shape `localStorage` has, because the shape is right -- it
 * is why the Web API is still in use twenty years on. What is wrong with
 * `localStorage` is the implementation: synchronous, string-only, about five
 * megabytes, and blocking the page it runs in. This keeps the interface and
 * replaces the implementation, with IndexedDB in a browser and a file
 * elsewhere.
 *
 * It sits beside `File` rather than inside `crossbyte.db` because it is not a
 * database and the difference is not cosmetic. `db` is synchronous SQL drivers
 * plus a thread pool to keep them off the loop, and a page has neither. This is
 * for what a client needs to survive a reload: a cache, a session, a queue of
 * messages waiting for a reconnect. Nobody wants a join in a browser tab.
 *
 * Every operation is asynchronous on every target, including the ones that
 * could do it synchronously. Not because browsers force it -- because a
 * synchronous signature decides which targets can implement the method, and
 * this framework has already paid for that lesson once: a PHP bridge whose
 * `execute()` returns a response is the only remaining reason PHP cannot run on
 * Node. Everything else about it ported.
 *
 * ```haxe
 * Store.open("session").then(store -> {
 *     var token = new ByteArray();
 *     token.writeUTFBytes("abc123");
 *     store.put("token", token).then(_ -> trace("saved"));
 * });
 * ```
 *
 * A value is written and read whole, so one has to fit in memory. That is a
 * real bound and it is deliberate: streaming into IndexedDB would mean chunking
 * a value across several keys behind a manifest, which is a second format with
 * its own half-written-set problem, in service of values this is not for. A
 * cached asset larger than memory belongs in a file, and `File` is right there
 * on every target that has one. Too large fails loudly either way -- a quota
 * error in a page, an allocation failure elsewhere -- and never silently
 * truncates.
 *
 * @see `crossbyte.db` for a server's data, which is a different problem.
 */
class Store {
	@:noCompletion private var __backend:IStoreBackend;
	@:noCompletion private var __closed:Bool = false;

	/** The name this store was opened with. */
	public final name:String;

	@:noCompletion private function new(name:String, backend:IStoreBackend) {
		this.name = name;
		this.__backend = backend;
	}

	/**
	 * Opens the store called `name`, creating it if it is not there.
	 *
	 * The name separates one store from another within an application -- it is
	 * not a path, and it is not a namespace between applications. Two
	 * CrossByte programs on one machine that both open "session" are opening
	 * their own, because the file backend resolves it under the application
	 * storage directory.
	 *
	 * @param name Store name. Letters, digits, `-`, `_` and `.` only, so that
	 *        it is a legal file name and a legal IndexedDB store name without
	 *        either target having to escape it into something the other would
	 *        not recognise.
	 * @throws ArgumentError If `name` is empty or holds anything else.
	 */
	public static function open(name:String):Future<Store> {
		if (name == null || name == "") {
			throw new ArgumentError("A store needs a name.");
		}

		if (!~/^[A-Za-z0-9._-]+$/.match(name)) {
			throw new ArgumentError("A store name may hold only letters, digits, '.', '-' and '_'; got '" + name + "'.");
		}

		var future = new Future<Store>();
		var backend:IStoreBackend = StoreBackend.create(name);

		backend.open(function(error:String):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(new Store(name, backend));
		});

		return future;
	}

	/**
	 * Reads `key`, or `null` if nothing was ever written under it.
	 *
	 * Null means absent, and only that. It is never an empty `ByteArray`
	 * standing in for a missing one: a caller that cannot tell "no value" from
	 * "a value of no bytes" will write the wrong thing back, and `File.exists`
	 * answering false where there is no filesystem is the same mistake this
	 * framework already documented once.
	 */
	public function get(key:String):Future<Null<ByteArray>> {
		var future = new Future<Null<ByteArray>>();

		if (!__usable(cast future, key)) {
			return future;
		}

		__backend.get(key, function(error:String, value:Null<ByteArray>):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(value);
		});

		return future;
	}

	/**
	 * Writes `value` under `key`, replacing whatever was there.
	 *
	 * The bytes are copied before the call returns, so a caller reusing its
	 * buffer for the next write cannot change what this one stores.
	 */
	public function put(key:String, value:ByteArray):Future<Store> {
		var future = new Future<Store>();

		if (!__usable(cast future, key)) {
			return future;
		}

		if (value == null) {
			@:privateAccess future.__reject("A value is required; use remove() to delete a key.");
			return future;
		}

		var copy = new ByteArray();
		copy.writeBytes(value, 0, value.length);

		__backend.put(key, copy, function(error:String):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(this);
		});

		return future;
	}

	/** Deletes `key`. Succeeds whether or not it was there. */
	public function remove(key:String):Future<Store> {
		var future = new Future<Store>();

		if (!__usable(cast future, key)) {
			return future;
		}

		__backend.remove(key, function(error:String):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(this);
		});

		return future;
	}

	/**
	 * Every key, or every key starting with `prefix`.
	 *
	 * Returns the whole list, which is right for the hundreds of keys a
	 * session or a small cache holds and wrong for millions. A cursor is the
	 * general answer and a heavier API; this stays until something needs that.
	 */
	public function keys(?prefix:String):Future<Array<String>> {
		var future = new Future<Array<String>>();

		if (__closed) {
			@:privateAccess future.__reject("This store is closed.");
			return future;
		}

		__backend.keys(prefix, function(error:String, found:Array<String>):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(found);
		});

		return future;
	}

	/**
	 * Visits every entry, or every entry under `prefix`, one at a time.
	 *
	 * Return `false` from `visit` to stop. Nothing holds the whole store in
	 * memory -- IndexedDB is walked with a cursor and the file backend reads
	 * one value at a time -- which is the difference between this and
	 * `keys()`, and the reason both exist. Reach for `keys()` when the list is
	 * the answer; reach for this when the values are, or when there may be
	 * more of them than you would like to allocate at once.
	 *
	 * No ordering is promised. IndexedDB walks its own key order and a
	 * directory listing is whatever the filesystem returns, and promising a
	 * shared order would mean sorting -- which would mean holding every key,
	 * which is what this avoids.
	 *
	 * The store may be modified during iteration, and an entry removed before
	 * it is reached is skipped rather than reported. This is a walk, not a
	 * snapshot.
	 */
	public function forEach(visit:(key:String, value:ByteArray) -> Bool, ?prefix:String):Future<Store> {
		var future = new Future<Store>();

		if (__closed) {
			@:privateAccess future.__reject("This store is closed.");
			return future;
		}

		if (visit == null) {
			@:privateAccess future.__reject("A visitor is required.");
			return future;
		}

		__backend.forEach(prefix, visit, function(error:String):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(this);
		});

		return future;
	}

	/**
	 * Writes `text` as UTF-8.
	 *
	 * A helper over `put`, and deliberately the only encoding offered. UTF-8
	 * is unambiguous and identical on every target; anything richer means this
	 * store choosing a serialisation format, and a format is a compatibility
	 * promise across targets and across versions of the framework. A caller
	 * with structured data picks its own and puts the bytes.
	 */
	public function putString(key:String, text:String):Future<Store> {
		if (text == null) {
			var future = new Future<Store>();
			@:privateAccess future.__reject("A value is required; use remove() to delete a key.");
			return future;
		}

		var data = new ByteArray();
		data.writeUTFBytes(text);
		return put(key, data);
	}

	/**
	 * Reads a value written by `putString`, or `null` if the key is absent.
	 *
	 * Absent still reads as `null`, not as `""`. An empty string is a value
	 * somebody stored.
	 */
	public function getString(key:String):Future<Null<String>> {
		// `map` rather than a hand-built future with both arms forwarded, which
		// is what this was: the failure arm in particular was three lines of
		// nothing but passing a message along, and forgetting it is how an
		// adapter turns a failure into a result that never arrives.
		return get(key).map(function(value:Null<ByteArray>):Null<String> {
			if (value == null) {
				return null;
			}

			value.position = 0;
			return value.readUTFBytes(value.length);
		});
	}

	/** Deletes everything in the store. */
	public function clear():Future<Store> {
		var future = new Future<Store>();

		if (__closed) {
			@:privateAccess future.__reject("This store is closed.");
			return future;
		}

		__backend.clear(function(error:String):Void {
			if (error != null) {
				@:privateAccess future.__reject(error);
				return;
			}

			@:privateAccess future.__resolve(this);
		});

		return future;
	}

	/**
	 * Releases the store. Operations after this fail rather than being
	 * ignored, because a write that quietly does nothing is the failure this
	 * whole design is arranged against.
	 */
	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;
		__backend.close();
	}

	@:noCompletion private function __usable(future:Future<Dynamic>, key:String):Bool {
		if (__closed) {
			@:privateAccess future.__reject("This store is closed.");
			return false;
		}

		if (key == null || key == "") {
			@:privateAccess future.__reject("A key is required.");
			return false;
		}

		return true;
	}
}
