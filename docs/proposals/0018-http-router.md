# Proposal 0018 — HTTP router

**Status:** Implemented

**Motivation:** The server's dynamic surface is one typedef:
`Middleware = (HTTPRequestHandler, ?Dynamic->Void) -> Void`. Everything else
is static files and the PHP bridge — `GET` serves the filesystem, and a
`POST` to anything that is not PHP is answered `405`. `respond()` exists and
works, but every application that wants `POST /api/users/42` to reach a
function starts by hand-writing the same thing inside a middleware: split
the path, match the segments, pull out the id, switch on the method. The
framework has an opinion about sockets, timers, migrations and metrics, and
no opinion about the single most common thing an HTTP service does.

A router is that opinion. As a middleware, not a core change: an application
that never constructs one loses nothing, which is the same modularity
argument the extension haxelibs already make.

---

## Surface

```haxe
var router = new Router();

router.get("/health", ctx -> ctx.handler.respond(200, "application/json", '{"ok":true}'));

router.get("/users/:id", ctx -> {
	var id:String = ctx.params.get("id");
	ctx.handler.respond(200, "application/json", findUser(id));
});

router.post("/users", ctx -> {
	var body:String = ctx.handler.requestText;
	ctx.handler.respond(201, "application/json", createUser(body));
});

router.get("/files/*rest", ctx -> serveFromBucket(ctx.params.get("rest"), ctx.handler));

config.middleware.push(router.middleware());
```

`RouteContext` is the handler plus what matching learned: `handler`,
`params:Map<String, String>`. Nothing more. `respond()`, `requestText`,
headers and cookies already live on the handler; wrapping them again would
be a second API for the same objects.

Registration: `get`, `post`, `put`, `delete`, `head`, `options`, and `any`.
The server's own method gate (`ALLOWED_METHODS`) applies to what reaches
dispatch, not to middleware, so `PUT` and `DELETE` routes work — and body
reading is framing-driven (`Content-Length`/chunked), not method-driven, so
a `PUT` body is already read before middleware runs. The dispatch gate stays
exactly as it is for requests no route claims.

## Matching

Patterns compile at registration into segment lists — literal, `:param`, or
a trailing `*rest` — and matching is a segment walk. No regular expressions:
a route table is small, fixed, and written by the application author, and a
segment walk is O(path) with nothing to compile per request, nothing to
cache, and no pathological pattern to defend against. The rewrite engine
keeps regexes because it emulates mod_rewrite; the router does not inherit
that obligation.

Precedence is registration order, first match wins. Not specificity
scoring: ordering rules that require a document to predict are how two
routes silently swap priority in a refactor. The author who writes
`/users/new` above `/users/:id` gets what the file says, in the order it
says it.

`:param` values are single segments, decoded by the existing request path
handling — percent-decoding per RFC 3986, so a literal `+` in a pattern
matches a literal `+` in the path and only `%XX` means anything else.
`*rest` must be final and captures the remainder unsplit.

Matching sees the pre-rewrite request path: the rewrite decision is
computed before middleware runs but applied only to requests the router
releases with `next()`. A matched route — its `405` included — therefore
preempts any rewrite configured for the same path, the default
`^/api/.*$` PHP rewrite among them; a deployment that wants both keeps
routes and rewrites on disjoint paths.

## Semantics at the edges

- **No route matches the path:** call `next()`. The router is a guest in the
  middleware chain, not the owner of the request — static files, `tryFiles`,
  rewrites and PHP behave exactly as if the router were absent. A service
  that is all API registers routes and lets everything else 404 the way it
  already does.
- **The path matches, the method does not:** `405` with an `Allow` header
  listing the methods actually registered for that pattern, then done — not
  `next()`, because falling through would turn a wrong-method API call into
  a filesystem probe, and the dispatch gate's own `405` lists the static
  methods rather than the route's.
- **The method is `OPTIONS` and no `options()` or `any()` route claims
  it:** a path miss, not a `405`. A `405` carries no
  `Access-Control-Allow-Methods`, which fails a browser's CORS preflight
  outright — registering a `POST` route would silently remove working
  cross-origin access to its path. Falling through lets the server's own
  preflight handling answer as if the router were absent.
- **A handler throws:** the middleware chain's existing error path
  answers — a thrown `Int` becomes the response status, an intentional
  escape hatch, and anything else becomes `500`. The router adds no error
  vocabulary of its own.

## What this refuses to do

- **Regex or optional segments.** A route that needs `[0-9]+` validation
  does it in the handler, where failure can be answered with a body that
  says so.
- **Per-route middleware chains.** Compose functions in the handler; one
  chain per server is the model the config already has.
- **Body parsing.** `requestText` and `requestBody` exist; JSON and
  multipart belong to their own proposals, not smuggled in here.
- **Mounting/prefix nesting.** A second router at `/api` is a `*rest` route
  away when someone needs it; speculative now.

## Test plan

- Matching is pure: unit tests on interp for literals, `:param` extraction,
  `*rest`, decode behavior, registration-order precedence, and the
  wrong-method → `Allow` computation.
- Through a real server on native: a `GET` route responding, a `POST` route
  reading its body, `405` with `Allow` on wrong method, fallthrough to a
  static file when no route matches, a throwing handler producing the
  chain's `500`.
- A `PUT` route round-trip, pinning that framing-driven body reads hold for
  methods the static gate would refuse.
