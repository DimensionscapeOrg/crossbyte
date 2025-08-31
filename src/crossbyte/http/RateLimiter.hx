package crossbyte.http;

/**
 * ...
 * @author Christopher Speciale
 */
class RateLimiter {
	private var requestCounts:Map<String, Int>;
	private var resetTime:Float;

	public function new(resetTime:Float = 60.0) {
		this.requestCounts = new Map<String, Int>();
		this.resetTime = resetTime;
		haxe.Timer.delay(() -> requestCounts = new Map<String, Int>(), Std.int(resetTime * 1000));
	}

	public function isRateLimited(clientIp:String):Bool {
		if (!requestCounts.exists(clientIp)) {
			requestCounts.set(clientIp, 1);
			return false;
		}

		var count:Int = requestCounts.get(clientIp);
		if (count > 10) { // limit to 10 requests per resetTime period
			return true;
		}

		requestCounts.set(clientIp, count + 1);
		return false;
	}
}
