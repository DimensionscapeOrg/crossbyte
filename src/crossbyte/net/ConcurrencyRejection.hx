package crossbyte.net;

/**
 * Why a `ConcurrencyLimiter` refused a request.
 *
 * A string underneath, so a reason can go straight into a log line, a metric
 * label or a close message.
 */
enum abstract ConcurrencyRejection(String) to String {
	/**
	 * The limiter was at capacity and had no room left to wait -- its queue
	 * was full, or it keeps none.
	 */
	var SATURATED = "saturated";

	/**
	 * The request waited `maxWait` seconds and capacity never came free.
	 */
	var TIMED_OUT = "timed-out";

	/**
	 * The limiter was closed before the request was granted.
	 */
	var CLOSED = "closed";

	/**
	 * The request's cost is more than the whole limit, so no amount of
	 * waiting would admit it.
	 */
	var EXCEEDS_LIMIT = "exceeds-limit";
}
