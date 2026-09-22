package crossbyte.http;

/**
	Where the rate limiter used to live.

	Nothing in it was ever about HTTP, and a server wants the same bucket for
	admitting connections and for metering a datagram path, so it moved to
	`crossbyte.net.RateLimiter`. This alias is here so existing imports keep
	working; point new code at the new name.
**/
@:deprecated("crossbyte.http.RateLimiter has moved to crossbyte.net.RateLimiter")
typedef RateLimiter = crossbyte.net.RateLimiter;
