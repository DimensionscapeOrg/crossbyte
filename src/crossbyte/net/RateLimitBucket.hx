package crossbyte.net;

/** One key's bucket, as a `RateLimitStore` holds it. **/
class RateLimitBucket {
	/** The tokens it held at `updatedAt`. **/
	public final tokens:Float;

	/** When `tokens` were counted, in seconds since the epoch. **/
	public final updatedAt:Float;

	/** The revision a write must name to replace it. **/
	public final revision:Float;

	public function new(tokens:Float, updatedAt:Float, revision:Float) {
		this.tokens = tokens;
		this.updatedAt = updatedAt;
		this.revision = revision;
	}
}
