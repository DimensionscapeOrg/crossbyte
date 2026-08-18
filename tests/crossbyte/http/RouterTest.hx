package crossbyte.http;

import crossbyte.errors.ArgumentError;
import crossbyte.http.Router.RouteContext;
import utest.Assert;

@:access(crossbyte.http.Router)
class RouterTest extends utest.Test {
	public function testLiteralPatternMatchesItsExactPath():Void {
		var router = new Router();
		var hit = false;
		router.get("/health", _ -> hit = true);

		// Matching resolves; dispatch belongs to the middleware, so the
		// handler comes back uninvoked.
		__dispatchHandler(router, "GET", "/health");
		Assert.isFalse(hit);

		Assert.isNull(router.__match("GET", "/healthz"));
		Assert.isNull(router.__match("GET", "/health/extra"));
	}

	public function testParamCapturesExactlyOneSegment():Void {
		var router = new Router();
		router.get("/users/:id", _ -> {});

		Assert.equals("42", __dispatchParams(router, "GET", "/users/42").get("id"));

		// The request path is URL-decoded before middleware runs, so a
		// param holds whatever its segment holds — an encoded %2F became a
		// segment boundary upstream, and the router does not decode again.
		Assert.equals("a b", __dispatchParams(router, "GET", "/users/a b").get("id"));

		// Exactly one segment: a deeper or shorter path is another shape.
		Assert.isNull(router.__match("GET", "/users/42/posts"));
		Assert.isNull(router.__match("GET", "/users"));
	}

	public function testRestCapturesTheRemainderJoined():Void {
		var router = new Router();
		router.get("/files/*rest", _ -> {});

		Assert.equals("a/b/c.txt", __dispatchParams(router, "GET", "/files/a/b/c.txt").get("rest"));
		Assert.equals("one", __dispatchParams(router, "GET", "/files/one").get("rest"));

		// The remainder stands for at least one segment: the bare prefix
		// names the collection, not a member of it.
		Assert.isNull(router.__match("GET", "/files"));

		// A trailing slash is a segment of its own, so it satisfies the
		// one-segment minimum with an empty capture.
		Assert.equals("", __dispatchParams(router, "GET", "/files/").get("rest"));
	}

	public function testTrailingSlashIsADifferentPath():Void {
		var router = new Router();
		router.get("/users/:id", _ -> {});

		// "/users/42/" carries one more, empty, segment; folding the two
		// spellings together would canonicalize URLs by accident.
		Assert.notNull(router.__match("GET", "/users/42"));
		Assert.isNull(router.__match("GET", "/users/42/"));
	}

	public function testRegistrationOrderDecidesPrecedence():Void {
		// The file's order is the rule: no specificity scoring to silently
		// reorder routes in a refactor. Literal-first means the literal
		// wins...
		var which:String = null;
		var literalFirst = new Router();
		literalFirst.get("/users/new", _ -> which = "literal");
		literalFirst.get("/users/:id", _ -> which = "param");
		__dispatchHandler(literalFirst, "GET", "/users/new")(__ctx());
		Assert.equals("literal", which);

		// ...and param-first means the param wins, exactly as written.
		var paramFirst = new Router();
		paramFirst.get("/users/:id", _ -> which = "param");
		paramFirst.get("/users/new", _ -> which = "literal");
		__dispatchHandler(paramFirst, "GET", "/users/new")(__ctx());
		Assert.equals("param", which);
	}

	public function testEveryVerbRegistersItsOwnMethodAndCallsChain():Void {
		var router = new Router();
		var seen:Array<String> = [];
		router.get("/v", _ -> seen.push("GET"))
			.post("/v", _ -> seen.push("POST"))
			.put("/v", _ -> seen.push("PUT"))
			.delete("/v", _ -> seen.push("DELETE"))
			.head("/v", _ -> seen.push("HEAD"))
			.options("/v", _ -> seen.push("OPTIONS"));

		for (verb in ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS"]) {
			__dispatchHandler(router, verb, "/v")(__ctx());
		}
		Assert.equals("GET,POST,PUT,DELETE,HEAD,OPTIONS", seen.join(","));
	}

	public function testHeadIsNotDerivedFromGet():Void {
		var router = new Router();
		router.get("/doc", _ -> {});

		// A HEAD the author did not write is a response the author did not
		// frame: the method miss reports GET rather than inventing a HEAD.
		Assert.equals("GET", __allowFor(router, "HEAD", "/doc"));
	}

	public function testMethodMissComputesAllowUnionDedupedInRegistrationOrder():Void {
		var router = new Router();
		router.get("/things/:id", _ -> {});
		router.put("/things/:id", _ -> {});
		// A second GET route matching the same path must not repeat GET in
		// the union, and a route on another path must not leak into it.
		router.get("/things/42", _ -> {});
		router.delete("/things/:id", _ -> {});
		router.post("/elsewhere", _ -> {});

		Assert.equals("GET, PUT, DELETE", __allowFor(router, "POST", "/things/42"));

		// A path no pattern claims is not the router's to answer at all:
		// no match, so the middleware falls through with next().
		Assert.isNull(router.__match("POST", "/nothing/here"));
	}

	public function testAnyMatchesEveryMethodAndSuppressesTheMethodMiss():Void {
		var router = new Router();
		var hits = 0;
		router.get("/mixed", _ -> {});
		router.any("/mixed", _ -> hits++);

		// The GET-only route misses POST, but any() is a real match for
		// every method — dispatch, not 405.
		__dispatchHandler(router, "POST", "/mixed")(__ctx());
		Assert.equals(1, hits);

		__dispatchHandler(router, "DELETE", "/mixed")(__ctx());
		Assert.equals(2, hits);
	}

	public function testUnroutedOptionsIsAPathMissNotAMethodMiss():Void {
		// A 405 would carry no Access-Control-Allow-Methods and so fail a
		// browser's CORS preflight outright: registering a POST route must
		// not silently remove cross-origin access to its path. Unrouted
		// OPTIONS falls through for the server's own preflight handling.
		var router = new Router();
		router.post("/submit", _ -> {});
		Assert.isNull(router.__match("OPTIONS", "/submit"));

		// An explicit options() route still dispatches...
		var explicit = new Router();
		var answered = false;
		explicit.options("/submit", _ -> answered = true);
		__dispatchHandler(explicit, "OPTIONS", "/submit")(__ctx());
		Assert.isTrue(answered);

		// ...and so does any(), which matches every method.
		var wildcard = new Router();
		wildcard.any("/submit", _ -> {});
		Assert.notNull(wildcard.__match("OPTIONS", "/submit"));
	}

	public function testMalformedRoutesAreRefusedAtRegistration():Void {
		var router = new Router();

		// Failing at the line that wrote the route beats matching nothing
		// at request time.
		Assert.raises(() -> router.get("", _ -> {}), ArgumentError);
		Assert.raises(() -> router.get(null, _ -> {}), ArgumentError);
		Assert.raises(() -> router.get("users/:id", _ -> {}), ArgumentError);
		// A segment after the remainder capture could never match anything.
		Assert.raises(() -> router.get("/files/*rest/tail", _ -> {}), ArgumentError);
		// A capture with no name has no key to read it back by.
		Assert.raises(() -> router.get("/users/:", _ -> {}), ArgumentError);
		Assert.raises(() -> router.get("/files/*", _ -> {}), ArgumentError);
		// Two captures sharing a name would fight over one params key, the
		// later silently winning.
		Assert.raises(() -> router.get("/pairs/:id/:id", _ -> {}), ArgumentError);
		Assert.raises(() -> router.get("/pairs/:id/*id", _ -> {}), ArgumentError);
		// A route with nothing to run would claim the request and then
		// answer nothing.
		Assert.raises(() -> router.get("/ok", null), ArgumentError);

		// Nothing half-registered: the failed routes must not have grown
		// the table.
		Assert.isNull(router.__match("GET", "/ok"));
	}

	/**
	 * Unwraps a dispatch's handler, failing the test — rather than
	 * crashing the run on a null — when the match is anything else.
	 */
	private function __dispatchHandler(router:Router, verb:String, path:String):RouteContext->Void {
		return switch (router.__match(verb, path)) {
			case Dispatch(handler, _):
				handler;
			case other:
				Assert.fail('expected $verb $path to dispatch, got $other');
				_ -> {};
		}
	}

	/**
	 * Unwraps a dispatch's captured params, failing the test — rather than
	 * crashing the run on a null — when the match is anything else.
	 */
	private function __dispatchParams(router:Router, verb:String, path:String):Map<String, String> {
		return switch (router.__match(verb, path)) {
			case Dispatch(_, params):
				params;
			case other:
				Assert.fail('expected $verb $path to dispatch, got $other');
				new Map();
		}
	}

	/**
	 * Unwraps a method miss's Allow list, already joined the way the
	 * middleware sends it.
	 */
	private function __allowFor(router:Router, verb:String, path:String):String {
		return switch (router.__match(verb, path)) {
			case MethodMiss(allowed):
				allowed.join(", ");
			case other:
				Assert.fail('expected $verb $path to be a method miss, got $other');
				"";
		}
	}

	/**
	 * A filler context for handlers that ignore it; pure matching never
	 * has a live request to offer.
	 */
	private static function __ctx():RouteContext {
		return {handler: null, params: new Map()};
	}
}
