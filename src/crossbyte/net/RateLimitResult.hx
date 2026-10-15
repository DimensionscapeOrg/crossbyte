package crossbyte.net;

/**
	What `RateLimiter.consume` found: whether the request may go ahead, and
	what a server tells the client either way. The fields are those of the
	IETF `RateLimit` header fields and `Retry-After`:

	```hx
	// Given limiter:crossbyte.net.RateLimiter, address:String.
	var result = limiter.consume(crossbyte.net.RateLimiter.addressKey(address));
	var headers = ["RateLimit-Limit: " + result.limit, "RateLimit-Remaining: " + result.remaining,
		"RateLimit-Reset: " + Math.ceil(result.resetAfter)];
	if (!result.allowed) {
		headers.push("Retry-After: " + Math.ceil(result.retryAfter));
		// ...and answer 429 Too Many Requests with them.
	}
	```
**/
class RateLimitResult {
	/** Whether the tokens were there, and were spent. **/
	public final allowed:Bool;

	/** The bucket's capacity, `maxRequests`: what `RateLimit-Limit` says. **/
	public final limit:Int;

	/** The whole tokens left, after this request if it was allowed: `RateLimit-Remaining`. **/
	public final remaining:Int;

	/**
		Seconds until this request's cost could be spent: `0` when it was,
		`Math.POSITIVE_INFINITY` for a cost past `limit`, which never can.
		What `Retry-After` says, rounded up.
	**/
	public final retryAfter:Float;

	/** Seconds until the bucket is full again: `RateLimit-Reset`, rounded up. **/
	public final resetAfter:Float;

	public function new(allowed:Bool, limit:Int, remaining:Int, retryAfter:Float, resetAfter:Float) {
		this.allowed = allowed;
		this.limit = limit;
		this.remaining = remaining;
		this.retryAfter = retryAfter;
		this.resetAfter = resetAfter;
	}

	public function toString():String {
		return '[RateLimitResult ${allowed ? "allowed" : "limited"}: $remaining of $limit left, retry after $retryAfter s, full after $resetAfter s]';
	}
}
