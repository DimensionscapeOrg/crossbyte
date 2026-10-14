package crossbyte.db.kv;

/**
	Which keys a `KVStore.scan` reads, and how many: an object literal makes
	one, each field it leaves out at its default, so `store.scan({prefix:
	"users/", limit: 50})` reads the first 50 keys that start with `users/`.

	The bounds narrow one another: a scan reads the keys that start with
	`prefix`, are at or after `startAt`, after `startAfter`, and before
	`endBefore`, in ascending order by code point (the order of their UTF-8
	bytes). Each is a key's text and none is required; none at all reads the
	whole store, a page at a time.
**/
@:structInit
final class KVScanOptions {
	/** `limit` unless given: 100. **/
	public static inline var DEFAULT_LIMIT:Int = 100;

	/** Only keys that start with this. Null or empty for any. **/
	public final prefix:Null<String> = null;

	/** Only keys at or after this one. **/
	public final startAt:Null<String> = null;

	/**
		Only keys after this one: `KVPage.next` of the page before, to read
		the next.
	**/
	public final startAfter:Null<String> = null;

	/** Only keys before this one. **/
	public final endBefore:Null<String> = null;

	/**
		The most records a page holds: `DEFAULT_LIMIT`, 100, unless given, and
		from 1 to the store's `KVOptions.maxScanLimit`. A page may hold fewer,
		at `KVOptions.maxPageBytes`.
	**/
	public final limit:Int = DEFAULT_LIMIT;

	/**
		Whether the page holds tombstones (`KVRecord.tombstone`), which a
		delete leaves: for a reader keeping a copy of the store, who needs to
		hear of a delete as of a write. `false` unless given.
	**/
	public final includeTombstones:Bool = false;
}
