package crossbyte.db.postgres._internal;

// Not built for any JavaScript target: it binds directly to native code, which neither a browser nor Node can load.
#if !js

import crossbyte.ipc._internal.VoidPointer;

@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/db/postgres/_internal/NativePostgresBuild.xml"/>')
@:include("./NativePostgres.h")
extern class NativePostgres {
	@:native("crossbyte_postgres_open")
	public static function open(host:String, port:Int, user:String, password:String, database:String, sslMode:String, connectTimeout:Int, libraryPaths:Array<String>):VoidPointer;

	@:native("crossbyte_postgres_close")
	public static function close(handle:VoidPointer):Void;

	@:native("crossbyte_postgres_is_open")
	public static function isOpen(handle:VoidPointer):Bool;

	@:native("crossbyte_postgres_request_json")
	public static function requestJson(handle:VoidPointer, sql:String):String;

	@:native("crossbyte_postgres_request_params")
	public static function requestParams(handle:VoidPointer, sql:cpp.ConstCharStar, params:cpp.ConstPointer<cpp.UInt8>, paramsLength:Int):Int;

	@:native("crossbyte_postgres_result_data")
	public static function resultData():cpp.ConstPointer<cpp.UInt8>;

	@:native("crossbyte_postgres_escape")
	public static function escape(handle:VoidPointer, value:String):String;

	@:native("crossbyte_postgres_last_error")
	public static function lastError():String;
}
#end
