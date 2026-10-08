package crossbyte.http;

/**
	An alias of `crossbyte.net.RateLimiter`, where the rate limiter lives.

	Nothing in it is about HTTP, and a server wants the same bucket for
	admitting connections and for metering a datagram path. This alias
	keeps existing imports working; point new code at the new name.
**/
@:deprecated("crossbyte.http.RateLimiter has moved to crossbyte.net.RateLimiter")
typedef RateLimiter = crossbyte.net.RateLimiter;
