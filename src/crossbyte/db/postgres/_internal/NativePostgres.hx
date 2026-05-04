package crossbyte.db.postgres._internal;

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

	@:native("crossbyte_postgres_escape")
	public static function escape(handle:VoidPointer, value:String):String;

	@:native("crossbyte_postgres_last_error")
	public static function lastError():String;
}
