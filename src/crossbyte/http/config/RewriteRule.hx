package crossbyte.http.config;

typedef RewriteRule = {
	public var pattern:String;
	public var target:String;
	@:optional public var flags:Array<RewriteFlag>;
	@:optional public var conditions:Array<RewriteCondition>;
}
