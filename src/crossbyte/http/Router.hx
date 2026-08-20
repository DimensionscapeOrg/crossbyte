package crossbyte.http;

// Not built for the browser: it routes requests arriving at the HTTP server.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.http.HTTPServerConfig.Middleware;
import crossbyte.url.URLRequestHeader;

/**
 * Dispatches requests to handlers by method and path pattern, as middleware.
 *
 * ```haxe
 * var router = new Router();
 * router.get("/users/:id", ctx -> ctx.handler.respond(200, "application/json", findUser(ctx.params.get("id"))));
 * router.post("/users", ctx -> ctx.handler.respond(201, "application/json", createUser(ctx.handler.requestText)));
 * config.middleware.push(router.middleware());
 * ```
 *
 * Patterns compile at registration into segment lists — literals,
 * single-segment `:param` captures, and a trailing `*rest` that takes the
 * remainder. No regular expressions: a route table is small, fixed and
 * written by the application author, so matching is a segment walk down
 * the table — linear in routes and segments — with nothing to compile per
 * request, nothing to cache, and no pathological pattern to defend
 * against.
 *
 * Precedence is registration order, first match wins — not specificity
 * scoring, because ordering rules that take a document to predict are how
 * two routes silently swap priority in a refactor. The author who writes
 * `/users/new` above `/users/:id` gets what the file says, in the order it
 * says it.
 *
 * Matching is exact on segment count. `/users/:id` matches `/users/42` and
 * not `/users/42/`: the trailing slash is one more, empty, segment, and
 * folding the two spellings together would canonicalize URLs by accident.
 * For the same reason `*rest` stands for at least one segment —
 * `/files/*rest` does not match `/files`, while `/files/` matches with an
 * empty capture, the slash being a segment of its own. Params hold
 * whatever their segments hold: the request path is URL-decoded before
 * middleware runs, and the router does not decode again. That upstream
 * decode also turns `+` into a space on sys targets, so params never hold
 * a literal `+` and a route spelling one in a literal segment is
 * unreachable until the handler's decoding is fixed.
 *
 * Matching also sees the pre-rewrite path. The rewrite decision is
 * computed before middleware runs but applied only to requests the router
 * releases with `next()`, so a matched route — its `405` included —
 * preempts any rewrite configured for the same path, the default
 * `^/api/.*$` PHP rewrite among them. A deployment that wants both keeps
 * routes and rewrites on disjoint paths.
 *
 * At the edges:
 *
 * - **No pattern matches the path** — the router calls `next()` and steps
 *   aside. It is a guest in the middleware chain, not the owner of the
 *   request: static files, `tryFiles`, rewrites and PHP behave exactly as
 *   if it were absent.
 * - **A pattern matches, the method does not** — `405` with an `Allow`
 *   header listing the methods registered on the matching patterns, and no
 *   `next()`: falling through would turn a wrong-method API call into a
 *   filesystem probe, answered by the dispatch gate's own `405` listing
 *   the static methods instead of the route's.
 * - **The method is `OPTIONS` and no `options()` or `any()` route claims
 *   it** — a path miss, not a `405`. A `405` carries no
 *   `Access-Control-Allow-Methods`, which fails a browser's CORS preflight
 *   outright, so registering a `POST` route would silently remove working
 *   cross-origin access to its path. Falling through lets the server's own
 *   preflight handling answer as if the router were absent.
 * - **A handler throws** — the middleware chain's own catch answers: a
 *   thrown `Int` becomes the response status, an intentional escape hatch,
 *   and anything else becomes `500`. The router adds no error vocabulary
 *   of its own.
 *
 * A matched handler owns the response: answer with `ctx.handler.respond()`.
 * The router calls neither `respond()` nor `next()` on its behalf, so a
 * handler that answers nothing leaves the connection waiting. What happens
 * to the connection after `respond()` — closing it, keeping it alive — is
 * the handler's concern, not the router's.
 *
 * `HEAD` is never derived from `get()`: a `HEAD` the author did not write
 * is a response the author did not frame. Register `head()` where `HEAD`
 * should answer. `PUT` and `DELETE` routes work — the server's own method
 * gate applies only to requests no middleware claims — and their bodies
 * are already read when a route runs, body framing being header-driven
 * rather than method-driven.
 */
class Router {
	@:noCompletion private static inline final ANY_METHOD:String = "*";

	@:noCompletion private var __routes:Array<Route>;

	/** Creates a router with an empty route table. */
	public function new() {
		__routes = [];
	}

	/** Registers `handler` for `GET` requests matching `pattern`. Returns `this` so calls chain. */
	public function get(pattern:String, handler:RouteContext->Void):Router {
		return __add("GET", pattern, handler);
	}

	/** Registers `handler` for `POST` requests matching `pattern`. Returns `this` so calls chain. */
	public function post(pattern:String, handler:RouteContext->Void):Router {
		return __add("POST", pattern, handler);
	}

	/** Registers `handler` for `PUT` requests matching `pattern`. Returns `this` so calls chain. */
	public function put(pattern:String, handler:RouteContext->Void):Router {
		return __add("PUT", pattern, handler);
	}

	/** Registers `handler` for `DELETE` requests matching `pattern`. Returns `this` so calls chain. */
	public function delete(pattern:String, handler:RouteContext->Void):Router {
		return __add("DELETE", pattern, handler);
	}

	/**
	 * Registers `handler` for `HEAD` requests matching `pattern`. Returns
	 * `this` so calls chain.
	 *
	 * `respond()` frames `HEAD` responses as zero-length, so a `head()`
	 * route cannot advertise the entity size the matching `GET` would have
	 * returned; a truthful `Content-Length` needs the byte-level response
	 * path and is future work. Do not pass `Content-Length` through the
	 * `headers` argument of `respond()` — it would duplicate the header
	 * `respond()` already writes.
	 */
	public function head(pattern:String, handler:RouteContext->Void):Router {
		return __add("HEAD", pattern, handler);
	}

	/**
	 * Registers `handler` for `OPTIONS` requests matching `pattern`.
	 * Returns `this` so calls chain.
	 *
	 * `OPTIONS` requests with no `options()` or `any()` route fall through
	 * the router rather than answering `405`, so the server's CORS
	 * preflight handling keeps working; see the class doc.
	 */
	public function options(pattern:String, handler:RouteContext->Void):Router {
		return __add("OPTIONS", pattern, handler);
	}

	/**
	 * Registers `handler` for every method on `pattern`. Returns `this` so
	 * calls chain.
	 *
	 * An `any` route is a real match for any method, so it also keeps a
	 * request from being answered `405` by method-specific routes on the
	 * same pattern above it.
	 */
	public function any(pattern:String, handler:RouteContext->Void):Router {
		return __add(ANY_METHOD, pattern, handler);
	}

	/**
	 * Builds the middleware that dispatches into this router.
	 *
	 * The closure reads the live route table, so routes registered after
	 * this call still count; precedence is registration order either way.
	 * Push the result onto `HTTPServerConfig.middleware`.
	 */
	public function middleware():Middleware {
		return function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			switch (__match(handler.method, handler.requestPath)) {
				case null:
					next();
				case MethodMiss(allowed):
					// The path is a route, the method is wrong. Answer here
					// and do not call next(): falling through would turn a
					// wrong-method API call into a filesystem probe, and
					// the dispatch gate's 405 lists the static methods, not
					// these.
					handler.respond(405, "text/plain", "405 Method Not Allowed", [new URLRequestHeader("Allow", allowed.join(", "))]);
				case Dispatch(route, params):
					// Invoked bare, no try/catch:
					// HTTPRequestHandler.__runMiddleware wraps this entire
					// middleware call in its own catch, so a throwing
					// handler lands on the chain's error path — the same
					// one next(error) reaches.
					route({handler: handler, params: params});
			}
		};
	}

	@:noCompletion private function __add(method:String, pattern:String, handler:RouteContext->Void):Router {
		if (handler == null) {
			// A matched route with nothing to run would claim the request
			// and then answer nothing.
			throw new ArgumentError('Route "$pattern" has no handler.');
		}

		var segments:Array<RouteSegment> = __compile(pattern);
		__routes.push({
			method: method,
			segments: segments,
			hasRest: segments[segments.length - 1].match(Rest(_)),
			handler: handler
		});
		return this;
	}

	/**
	 * Compiles a pattern into segments, refusing malformed ones here — at
	 * the line that wrote the route — rather than matching nothing at
	 * request time. Always yields at least one segment, since a valid
	 * pattern begins with `/`.
	 */
	@:noCompletion private static function __compile(pattern:String):Array<RouteSegment> {
		if (pattern == null || pattern == "") {
			throw new ArgumentError("Route pattern must not be empty.");
		}
		if (pattern.charAt(0) != "/") {
			// Request paths always begin with "/", so this pattern could
			// only ever match by accident of normalization.
			throw new ArgumentError('Route pattern must begin with "/" (got "$pattern").');
		}

		var pieces:Array<String> = pattern.split("/");
		pieces.shift(); // The leading "/" contributes an empty first piece.

		var segments:Array<RouteSegment> = [];
		var captureNames:Array<String> = [];
		for (i in 0...pieces.length) {
			var piece:String = pieces[i];
			if (piece.charAt(0) == ":") {
				var name:String = piece.substr(1);
				if (name == "") {
					// A capture with no name has no key to read it back by.
					throw new ArgumentError('Route pattern "$pattern" has a ":" capture with no name.');
				}
				if (captureNames.indexOf(name) >= 0) {
					// Two captures sharing a name would fight over one
					// params key, and the later segment would win silently.
					throw new ArgumentError('Route pattern "$pattern" captures "$name" twice.');
				}
				captureNames.push(name);
				segments.push(Param(name));
			} else if (piece.charAt(0) == "*") {
				var name:String = piece.substr(1);
				if (name == "") {
					throw new ArgumentError('Route pattern "$pattern" has a "*" capture with no name.');
				}
				if (i != pieces.length - 1) {
					// Segments after a remainder capture could never match
					// anything; the route would be dead as written.
					throw new ArgumentError('"*$name" must be the final segment of "$pattern".');
				}
				if (captureNames.indexOf(name) >= 0) {
					throw new ArgumentError('Route pattern "$pattern" captures "$name" twice.');
				}
				segments.push(Rest(name));
			} else {
				segments.push(Literal(piece));
			}
		}

		return segments;
	}

	/**
	 * Resolves `method` and `path` against the route table. `method` is
	 * compared as given; the request handler supplies it uppercased.
	 *
	 * Returns `null` when no pattern matches the path, `Dispatch` when a
	 * route claims the request, or `MethodMiss` when patterns match the
	 * path but none the method — carrying the union of their methods,
	 * deduplicated, in registration order, ready for an `Allow` header.
	 * `OPTIONS` never yields `MethodMiss`; see the comment below.
	 */
	@:noCompletion private function __match(method:String, path:String):Null<RouteMatch> {
		var parts:Array<String> = path.split("/");
		if (parts.length > 0 && parts[0] == "") {
			parts.shift();
		}

		var allowed:Array<String> = [];
		for (route in __routes) {
			var params:Map<String, String> = __matchSegments(route.segments, route.hasRest, parts);
			if (params == null) {
				continue;
			}

			if (route.method == ANY_METHOD || route.method == method) {
				return Dispatch(route.handler, params);
			}

			if (allowed.indexOf(route.method) < 0) {
				allowed.push(route.method);
			}
		}

		if (allowed.length == 0) {
			return null;
		}

		if (method == "OPTIONS") {
			// A 405 here would carry no Access-Control-Allow-Methods, which
			// fails a browser's CORS preflight outright: registering a POST
			// route would silently remove working cross-origin access to
			// its path. Unrouted OPTIONS is a path miss instead, so the
			// server's own preflight handling answers exactly as if the
			// router were absent.
			return null;
		}

		return MethodMiss(allowed);
	}

	@:noCompletion private static function __matchSegments(segments:Array<RouteSegment>, hasRest:Bool, parts:Array<String>):Null<Map<String, String>> {
		if (hasRest) {
			// The remainder capture stands for at least one segment, so the
			// bare prefix is not a match.
			if (parts.length < segments.length) {
				return null;
			}
		} else if (parts.length != segments.length) {
			return null;
		}

		var params:Map<String, String> = new Map();
		for (i in 0...segments.length) {
			switch (segments[i]) {
				case Literal(value):
					if (parts[i] != value) {
						return null;
					}
				case Param(name):
					params.set(name, parts[i]);
				case Rest(name):
					params.set(name, parts.slice(i).join("/"));
			}
		}

		return params;
	}
}

/**
 * What a matched route handler receives: the request, and what matching
 * learned from the path.
 */
typedef RouteContext = {
	/**
	 * The request being answered. `respond()`, `requestBody`, headers and
	 * cookies already live here; the router wraps none of them again.
	 */
	var handler:HTTPRequestHandler;

	/**
	 * Values captured by `:param` and `*rest` segments, keyed by name.
	 */
	var params:Map<String, String>;
}

private typedef Route = {
	var method:String;
	var segments:Array<RouteSegment>;
	var hasRest:Bool;
	var handler:RouteContext->Void;
}

/**
 * What matching resolved; a path nothing matched is `null` instead, so the
 * middleware can fall through with `next()`.
 */
private enum RouteMatch {
	/** A route claims the request: run `handler` with `params`. */
	Dispatch(handler:RouteContext->Void, params:Map<String, String>);

	/** Patterns match the path but none the method: answer `405` allowing `allowed`. */
	MethodMiss(allowed:Array<String>);
}

private enum RouteSegment {
	Literal(value:String);
	Param(name:String);
	Rest(name:String);
}
#end
