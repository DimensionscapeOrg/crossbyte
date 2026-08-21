package crossbyte.io._internal.store;

/**
 * Picks the backend for the target being built.
 *
 * Two, not three: IndexedDB where there is a page, and a file everywhere with
 * a filesystem. SQLite was considered for the native side and deferred,
 * because it is not available on Node -- choosing it would have meant three
 * implementations and a Node gap on the first day. If the file store proves
 * too slow or too fragile, SQLite is the upgrade, behind this same interface,
 * which is the point of having one.
 */
class StoreBackend {
	public static function create(name:String):IStoreBackend {
		#if (js && !nodejs)
		return new IndexedDBStore(name);
		#else
		return new FileStore(name);
		#end
	}
}
