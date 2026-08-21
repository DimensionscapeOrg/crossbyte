package crossbyte.io._internal.store;

#if (js && !nodejs)
import crossbyte.io.ByteArray;
import js.html.idb.Database;
import js.html.idb.Request;
import js.html.idb.Transaction;
import js.lib.Uint8Array;

/**
 * A `Store` over IndexedDB, for a page.
 *
 * IndexedDB rather than `localStorage`, which is the API this one's shape is
 * borrowed from. `localStorage` is synchronous and blocks the page, holds
 * strings only, and is capped around five megabytes. IndexedDB is
 * asynchronous, stores binary directly, and is bounded by the origin's quota
 * rather than a fixed ceiling. The interface is worth keeping; the
 * implementation is not.
 *
 * OPFS was the other candidate and is file-shaped: directories, handles,
 * streams. That is a better fit for `File` than for a keyed store, and lower
 * level than anything here needs.
 *
 * Values are stored as `Uint8Array`. IndexedDB would happily take a structured
 * clone of anything, but this store's contract is bytes on every target, and
 * storing something richer here would make the browser's copy of a value
 * different from every other target's.
 */
class IndexedDBStore implements IStoreBackend {
	private static inline var OBJECT_STORE:String = "entries";
	private static inline var VERSION:Int = 1;

	private final name:String;
	private var database:Null<Database>;

	public function new(name:String) {
		this.name = name;
	}

	public function open(done:String->Void):Void {
		var factory = js.Browser.window.indexedDB;

		if (factory == null) {
			// A page can be denied IndexedDB outright -- private browsing in
			// some browsers, or a blocked third-party context. Said plainly
			// rather than reported as an empty store, which would read as "you
			// have saved nothing" and invite the caller to save it again.
			done("This page has no IndexedDB; storage is unavailable here.");
			return;
		}

		var request = factory.open("crossbyte." + name, VERSION);

		request.onupgradeneeded = function(_):Void {
			var db:Database = request.result;

			if (!db.objectStoreNames.contains(OBJECT_STORE)) {
				db.createObjectStore(OBJECT_STORE);
			}
		};

		request.onsuccess = function(_):Void {
			database = request.result;
			done(null);
		};

		request.onerror = function(_):Void {
			done("Could not open IndexedDB: " + __reason(request));
		};
	}

	public function get(key:String, done:(error:String, value:Null<ByteArray>) -> Void):Void {
		var request:Request;

		try {
			request = __transaction(false).objectStore(OBJECT_STORE).get(key);
		} catch (e:Dynamic) {
			done("Could not read '" + key + "': " + Std.string(e), null);
			return;
		}

		request.onsuccess = function(_):Void {
			var stored:Dynamic = request.result;

			// undefined is what IndexedDB returns for a key that is not there,
			// and it has to stay distinguishable from a value of zero bytes.
			if (stored == null) {
				done(null, null);
				return;
			}

			var view:Uint8Array = stored;
			done(null, ByteArray.fromBytes(haxe.io.Bytes.ofData(view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength))));
		};

		request.onerror = function(_):Void {
			done("Could not read '" + key + "': " + __reason(request), null);
		};
	}

	public function put(key:String, value:ByteArray, done:String->Void):Void {
		var request:Request;

		try {
			var bytes:haxe.io.Bytes = value;
			// Bounded to the logical length, not the backing buffer. A
			// ByteArray grows geometrically, so 256 written bytes sit in a
			// 385-byte store -- and a Uint8Array over the whole buffer
			// faithfully saves all 385, padding included. The browser suite
			// caught it as "expected 256 but it is 385", which is the same
			// mistake LZ4 was making in a page a few commits ago: handing back
			// the container instead of the contents.
			request = __transaction(true).objectStore(OBJECT_STORE).put(new Uint8Array(bytes.getData(), 0, bytes.length), key);
		} catch (e:Dynamic) {
			done("Could not write '" + key + "': " + Std.string(e));
			return;
		}

		request.onsuccess = function(_):Void {
			done(null);
		};

		request.onerror = function(_):Void {
			// A quota failure arrives here. It is a write that did not happen,
			// which is the one thing a store must never report as success.
			done("Could not write '" + key + "': " + __reason(request));
		};
	}

	public function remove(key:String, done:String->Void):Void {
		var request:Request;

		try {
			request = __transaction(true).objectStore(OBJECT_STORE).delete(key);
		} catch (e:Dynamic) {
			done("Could not remove '" + key + "': " + Std.string(e));
			return;
		}

		request.onsuccess = function(_):Void {
			done(null);
		};

		request.onerror = function(_):Void {
			done("Could not remove '" + key + "': " + __reason(request));
		};
	}

	public function keys(prefix:Null<String>, done:(error:String, keys:Array<String>) -> Void):Void {
		var request:Request;

		try {
			request = __transaction(false).objectStore(OBJECT_STORE).getAllKeys();
		} catch (e:Dynamic) {
			done("Could not list the store: " + Std.string(e), null);
			return;
		}

		request.onsuccess = function(_):Void {
			var all:Array<Dynamic> = request.result;
			var found:Array<String> = [];

			for (key in all) {
				var text:String = Std.string(key);

				if (prefix == null || StringTools.startsWith(text, prefix)) {
					found.push(text);
				}
			}

			done(null, found);
		};

		request.onerror = function(_):Void {
			done("Could not list the store: " + __reason(request), null);
		};
	}

	public function clear(done:String->Void):Void {
		var request:Request;

		try {
			request = __transaction(true).objectStore(OBJECT_STORE).clear();
		} catch (e:Dynamic) {
			done("Could not clear the store: " + Std.string(e));
			return;
		}

		request.onsuccess = function(_):Void {
			done(null);
		};

		request.onerror = function(_):Void {
			done("Could not clear the store: " + __reason(request));
		};
	}

	public function close():Void {
		if (database != null) {
			database.close();
			database = null;
		}
	}

	private function __transaction(write:Bool):Transaction {
		if (database == null) {
			throw "This store is closed.";
		}

		return database.transaction([OBJECT_STORE], write ? READWRITE : READONLY);
	}

	private function __reason(request:Request):String {
		var error:Dynamic = request.error;
		return error != null ? Std.string(error.name) + ": " + Std.string(error.message) : "unknown error";
	}
}
#end
