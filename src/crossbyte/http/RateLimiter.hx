package crossbyte.http;

/**
 * ...
 * @author Christopher Speciale
 */
class RateLimiter {
	private var requestCounts:Map<String, Int>;
	private var resetTime:Float;
	private var windowEndsAt:Float;

	public function new(resetTime:Float = 60.0) {
		this.requestCounts = new Map<String, Int>();
		this.resetTime = resetTime;
		this.windowEndsAt = haxe.Timer.stamp() + resetTime;
	}

	public function isRateLimited(clientIp:String):Bool {
		var now = haxe.Timer.stamp();
		if (now >= windowEndsAt) {
			requestCounts = new Map<String, Int>();
			windowEndsAt = now + resetTime;
		}

		if (!requestCounts.exists(clientIp)) {
			requestCounts.set(clientIp, 1);
			return false;
		}

		var count:Int = requestCounts.get(clientIp);
		if (count >= 10) { // limit to 10 requests per resetTime period
			return true;
		}

		requestCounts.set(clientIp, count + 1);
		return false;
	}
}
