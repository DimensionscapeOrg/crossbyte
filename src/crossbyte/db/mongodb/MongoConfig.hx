package crossbyte.db.mongodb;

typedef MongoConfig = {
	@:optional var uri:String;
	@:optional var host:String;
	@:optional var port:Int;
	@:optional var database:String;
	@:optional var username:String;
	@:optional var password:String;
}
