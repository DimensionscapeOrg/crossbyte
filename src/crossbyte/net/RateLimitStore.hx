package crossbyte.net;

/**
	Where a `RateLimiter` keeps its buckets when they have to outlive the
	process, or be shared by several: on PHP, where each request is a
	process of its own, and for a service run as several processes or
	behind a load balancer, which would otherwise each let a client through
	at the full rate. A limiter given none keeps its buckets in memory,
	which is what one long-running server wants, and costs nothing per
	check.

	A store keeps each key's bucket: the tokens it held, when they were
	counted, and a revision every write moves on. The limiter reads a
	bucket, works out what it holds now, and writes it back only if no one
	wrote it meanwhile, reading it again when someone did, as the
	compare-and-swap backends of Bucket4j's distributed buckets do: one
	atomic step per check, however many requests check one key at once.

	`crossbyte.db.kv.KVRateLimitStore` keeps them in a `KVStore`: SQLite
	natively and on PHP, Postgres natively, or memory anywhere. Anything
	with a compare-and-set (Redis's `WATCH`, a row's version column) can be
	one.
**/
interface RateLimitStore {
	/** The bucket under `key`, or null when there is none. **/
	function get(key:String):Null<RateLimitBucket>;

	/**
		Writes `key`'s bucket only if what is stored is still at revision
		`expected` (`0` when there was nothing), in one step that no other
		write can come between. Answers whether it wrote: `false` is the
		sign that someone else wrote the bucket first.

		@param tokens What the bucket holds.
		@param updatedAt When they were counted, in seconds since the epoch.
		@param fullAt When the bucket is full again, in seconds since the
			epoch: from then on it is the same as no bucket, and a store may
			forget it.
	**/
	function compareAndSet(key:String, tokens:Float, updatedAt:Float, fullAt:Float, expected:Float):Bool;

	/** Forgets `key`'s bucket, if there is one. **/
	function delete(key:String):Void;
}
