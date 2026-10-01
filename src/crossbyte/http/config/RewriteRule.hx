package crossbyte.http.config;

/** Declarative rule describing a rewrite pattern, target, and optional conditions. */
typedef RewriteRule = {
	/** Pattern evaluated against the request path. */
	public var pattern:String;
	/**
		The path a matching request is rewritten to, under `rootDirectory`:
		`$1` to `$9` stand for what the pattern captured, and a `?query` is
		the request's from then on, merged with the one it brought under
		`QSA`: for a static file, a script and a `POST` alike.

		A path, never a route. Rules run once middleware has passed a request
		on, and a `Router` is middleware, so a rule cannot send a request to
		one; rewrite in middleware ahead of the router for that.
	**/
	public var target:String;
	/** Optional flags that modify rewrite behavior. */
	@:optional public var flags:Array<RewriteFlag>;
	/** Optional preconditions that must pass before the rule applies. */
	@:optional public var conditions:Array<RewriteCondition>;
}
