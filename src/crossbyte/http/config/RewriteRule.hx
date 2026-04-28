package crossbyte.http.config;

/** Declarative rule describing a rewrite pattern, target, and optional conditions. */
typedef RewriteRule = {
	/** Pattern evaluated against the request path. */
	public var pattern:String;
	/** Target path or route applied when the rule matches. */
	public var target:String;
	/** Optional flags that modify rewrite behavior. */
	@:optional public var flags:Array<RewriteFlag>;
	/** Optional preconditions that must pass before the rule applies. */
	@:optional public var conditions:Array<RewriteCondition>;
}
