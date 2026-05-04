package crossbyte.db.postgres;

/** Connection settings for `PostgresConnection`. */
typedef PostgresConfig = {
	@:optional var host:String;
	@:optional var port:Int;
	@:optional var user:String;
	@:optional var password:String;
	@:optional var database:String;
	@:optional var sslMode:String;
	@:optional var connectTimeout:Int;
	@:optional var libraryPath:String;
	@:optional var libraryPaths:Array<String>;
}
