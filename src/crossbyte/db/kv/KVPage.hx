package crossbyte.db.kv;

/**
	One page of a scan: records (or a repository's items) in ascending key
	order, and where the next page starts.

	```haxe
	// Given store:crossbyte.db.kv.KVStore.
	var page = store.scan({prefix: "users/"});
	while (true) {
		for (record in page.items) {
			trace(record.key);
		}
		if (page.next == null) {
			break;
		}
		page = store.scan({prefix: "users/", startAfter: page.next});
	}
	```
**/
final class KVPage<R> {
	/** What the page holds, in ascending key order. **/
	public final items:Array<R>;

	/**
		Whether keys in the range are left after this page: it stopped at the
		scan's `limit`, or at the store's `KVOptions.maxPageBytes`.
	**/
	public final more:Bool;

	/**
		The key to pass as `KVScanOptions.startAfter` for the next page: the
		last item's, when `more`; null when the range is done.
	**/
	public final next:Null<String>;

	public function new(items:Array<R>, more:Bool, next:Null<String>) {
		this.items = items;
		this.more = more;
		this.next = next;
	}
}
