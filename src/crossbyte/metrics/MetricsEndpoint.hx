package crossbyte.metrics;

// Not built for the browser: it serves metrics over HTTP, which means listening,
// and a page cannot. Node can, and the gate used to exclude it anyway -- the
// same "JavaScript means browser" reading that kept the HTTP server's own tests
// off Node long after the server ran there. This is middleware over
// HTTPRequestHandler and needs exactly what that needs.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import crossbyte.http.HTTPRequestHandler;

/**
 * Serves a registry in Prometheus text exposition format.
 *
 * Built as middleware so it composes with existing routing rather than
 * needing its own listener:
 *
 * ```haxe
 * var config = new HTTPServerConfig("0.0.0.0", 8080, root);
 * config.middleware.push(MetricsEndpoint.middleware(Metrics.shared));
 * ```
 *
 * Requests to the configured path are answered here; everything else
 * passes through untouched.
 *
 * **Exposure.** The endpoint is unauthenticated: anything registered is
 * readable by anyone who can reach the port. Metric names and labels
 * describe internals, so bind the server to a private interface, put the
 * path behind a proxy rule, or add an authentication middleware ahead of
 * this one when the port is public.
 */
class MetricsEndpoint {
	/**
	 * Content type for the Prometheus 0.0.4 text format.
	 */
	public static inline final CONTENT_TYPE:String = "text/plain; version=0.0.4; charset=utf-8";

	/**
	 * Default path served.
	 */
	public static inline final DEFAULT_PATH:String = "/metrics";

	/**
	 * Builds middleware that serves `registry` at `path`.
	 *
	 * @param registry Registry to render. Defaults to `Metrics.shared`.
	 * @param path Path to answer. Defaults to `/metrics`.
	 */
	public static function middleware(?registry:Metrics, ?path:String):(HTTPRequestHandler, ?Dynamic->Void) -> Void {
		var target:Metrics = (registry == null) ? Metrics.shared : registry;
		var servedPath:String = (path == null || path == "") ? DEFAULT_PATH : path;

		if (!StringTools.startsWith(servedPath, "/")) {
			throw new ArgumentError('Metrics path must begin with "/" (got "$servedPath").');
		}

		return function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			if (handler.requestPath != servedPath) {
				next();
				return;
			}

			// Scraping is a read; anything else on this path is a mistake
			// worth reporting rather than silently treating as a scrape.
			if (handler.method != "GET" && handler.method != "HEAD") {
				handler.respond(405, "text/plain; charset=utf-8", "Method Not Allowed");
				return;
			}

			var body:String;
			try {
				body = target.toPrometheus();
			} catch (error:Dynamic) {
				// A failing scrape must not take down the service it
				// observes.
				handler.respond(500, "text/plain; charset=utf-8", "Metrics rendering failed");
				return;
			}

			handler.respond(200, CONTENT_TYPE, body);
		};
	}
}
#end
