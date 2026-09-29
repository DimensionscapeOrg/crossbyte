package crossbyte.db.postgres._internal;

// Not built for any JavaScript target: it binds directly to native code, which neither a browser nor Node can load.
#if !js

import crossbyte.ipc._internal.VoidPointer;
import haxe.io.BytesData;

@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/db/postgres/_internal/NativePostgresBuild.xml"/>')
@:include("./NativePostgres.h")
extern class NativePostgres {
	/** Always returns a handle; `error()` says whether the connection opened. **/
	@:native("crossbyte_postgres_open")
	public static function open(conninfo:String, libraryPaths:Array<String>):VoidPointer;

	/** Why `open` failed, or an empty string when it succeeded. **/
	@:native("crossbyte_postgres_error")
	public static function error(handle:VoidPointer):String;

	@:native("crossbyte_postgres_close")
	public static function close(handle:VoidPointer):Void;

	@:native("crossbyte_postgres_is_open")
	public static function isOpen(handle:VoidPointer):Bool;

	@:native("crossbyte_postgres_request_json")
	public static function requestJson(handle:VoidPointer, sql:String):String;

	@:native("crossbyte_postgres_request_params")
	public static function requestParams(handle:VoidPointer, sql:String, params:BytesData, paramsLength:Int):BytesData;

	@:native("crossbyte_postgres_escape")
	public static function escape(handle:VoidPointer, value:String):String;

	@:native("crossbyte_postgres_cancel")
	public static function cancel(handle:VoidPointer):Bool;

	/**
		libpq's `PQtransactionStatus`: 0 idle, 1 running a statement, 2 in a
		transaction, 3 in a failed transaction, 4 unknown (a bad connection).
		-1 without a connection, or from a libpq that lacks the call.
	**/
	@:native("crossbyte_postgres_transaction_status")
	public static function transactionStatus(handle:VoidPointer):Int;
}
#end
