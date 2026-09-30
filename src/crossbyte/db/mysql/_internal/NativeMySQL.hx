package crossbyte.db.mysql._internal;

#if cpp
/**
 * The MySQL client hxcpp bundles (`src/hx/libs/mysql` in the fork CrossByte
 * builds against), called directly.
 *
 * Haxe's `sys.db.Mysql` wraps the same client, but only the calls its
 * `sys.db.Connection` interface needs, and nothing a driver has to know after
 * a statement: the status flags that say whether a transaction is open and
 * how quotes are escaped, the insert id and affected rows the OK packet
 * already carried, the error number and SQLSTATE. Those are read here, from
 * what the client kept of the server's last reply, so none of them costs a
 * round trip.
 *
 * Every call is a plain static, never `inline`: the functions the fork added
 * are declared by `@:cppFileCode` in this class's own C++ file, so a call to
 * one inlined into another class's file would not compile.
 */
@:noCompletion
@:buildXml('<include name="${HXCPP}/src/hx/libs/mysql/Build.xml"/>')
@:cppFileCode('
HXCPP_EXTERN_CLASS_ATTRIBUTES int _hx_mysql_server_status(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES bool _hx_mysql_is_tls(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES String _hx_mysql_auth_plugin(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES Dynamic _hx_mysql_create(Dynamic params);
HXCPP_EXTERN_CLASS_ATTRIBUTES void _hx_mysql_open(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES bool _hx_mysql_ping(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES int _hx_mysql_errno(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES String _hx_mysql_sqlstate(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES Float _hx_mysql_thread_id(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES Dynamic _hx_mysql_request_stream(Dynamic handle, String req);
HXCPP_EXTERN_CLASS_ATTRIBUTES Dynamic _hx_mysql_insert_id(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES Dynamic _hx_mysql_affected_rows(Dynamic handle);
HXCPP_EXTERN_CLASS_ATTRIBUTES String _hx_mysql_server_version(Dynamic handle);
')
class NativeMySQL {
	public static inline var STATUS_IN_TRANS:Int = 0x0001;
	public static inline var STATUS_AUTOCOMMIT:Int = 0x0002;
	public static inline var STATUS_NO_BACKSLASH_ESCAPES:Int = 0x0200;

	@:noCompletion private static var __conversionsSet:Bool = false;

	/**
		A connection not yet open, so that when opening it fails the error
		number and SQLSTATE can still be read from it before it is closed.
	**/
	public static function create(params:Dynamic):Dynamic {
		if (!__conversionsSet) {
			// How the client turns a BLOB into Bytes and a DATETIME into a
			// Date; Haxe's own wrapper sets the same pair, so whichever runs
			// last leaves them as they were.
			__setConversion(cpp.Function.fromStaticFunction(__bytesOf), cpp.Function.fromStaticFunction(__dateOf));
			__conversionsSet = true;
		}

		return __create(params);
	}

	public static function open(handle:Dynamic):Void {
		__open(handle);
	}

	public static function ping(handle:Dynamic):Bool {
		return __ping(handle);
	}

	public static function errorCode(handle:Dynamic):Int {
		return __errno(handle);
	}

	public static function sqlState(handle:Dynamic):String {
		return __sqlstate(handle);
	}

	public static function threadId(handle:Dynamic):Float {
		return __threadId(handle);
	}

	public static function selectDatabase(handle:Dynamic, database:String):Void {
		__selectDb(handle, database);
	}

	public static function request(handle:Dynamic, sql:String):Dynamic {
		return __request(handle, sql);
	}

	/**
		A statement whose rows are read as they arrive, one per `resultNext`,
		instead of all of them before the first is returned.
	**/
	public static function requestStream(handle:Dynamic, sql:String):Dynamic {
		return __requestStream(handle, sql);
	}

	/** The id the last statement generated: an `Int`, or an `Int64` past 2^31. **/
	public static function insertId(handle:Dynamic):Dynamic {
		return __insertId(handle);
	}

	/** The rows the last statement changed: an `Int`, or an `Int64` past 2^31. **/
	public static function affectedRows(handle:Dynamic):Dynamic {
		return __affectedRows(handle);
	}

	public static function serverVersion(handle:Dynamic):String {
		return __serverVersion(handle);
	}

	public static function close(handle:Dynamic):Void {
		__close(handle);
	}

	public static function escape(handle:Dynamic, value:String):String {
		return __escape(handle, value);
	}

	public static function serverStatus(handle:Dynamic):Int {
		return __serverStatus(handle);
	}

	public static function isTls(handle:Dynamic):Bool {
		return __isTls(handle);
	}

	public static function authPlugin(handle:Dynamic):String {
		return __authPlugin(handle);
	}

	public static function resultLength(result:Dynamic):Int {
		return __resultGetLength(result);
	}

	public static function resultFields(result:Dynamic):Int {
		return __resultGetNFields(result);
	}

	public static function resultNext(result:Dynamic):Dynamic {
		return __resultNext(result);
	}

	public static function resultGet(result:Dynamic, n:Int):String {
		return __resultGet(result, n);
	}

	public static function resultGetInt(result:Dynamic, n:Int):Int {
		return __resultGetInt(result, n);
	}

	public static function resultGetFloat(result:Dynamic, n:Int):Float {
		return __resultGetFloat(result, n);
	}

	public static function resultFieldNames(result:Dynamic):Array<String> {
		return __resultGetFieldsNames(result);
	}

	private static function __bytesOf(data:Dynamic):Dynamic {
		return haxe.io.Bytes.ofData(data);
	}

	private static function __dateOf(seconds:Float):Dynamic {
		return Date.fromTime(seconds * 1000);
	}

	@:native("_hx_mysql_create")
	extern private static function __create(params:Dynamic):Dynamic;

	@:native("_hx_mysql_open")
	extern private static function __open(handle:Dynamic):Void;

	@:native("_hx_mysql_ping")
	extern private static function __ping(handle:Dynamic):Bool;

	@:native("_hx_mysql_errno")
	extern private static function __errno(handle:Dynamic):Int;

	@:native("_hx_mysql_sqlstate")
	extern private static function __sqlstate(handle:Dynamic):String;

	@:native("_hx_mysql_thread_id")
	extern private static function __threadId(handle:Dynamic):Float;

	@:native("_hx_mysql_select_db")
	extern private static function __selectDb(handle:Dynamic, db:String):Void;

	@:native("_hx_mysql_request")
	extern private static function __request(handle:Dynamic, req:String):Dynamic;

	@:native("_hx_mysql_request_stream")
	extern private static function __requestStream(handle:Dynamic, req:String):Dynamic;

	@:native("_hx_mysql_insert_id")
	extern private static function __insertId(handle:Dynamic):Dynamic;

	@:native("_hx_mysql_affected_rows")
	extern private static function __affectedRows(handle:Dynamic):Dynamic;

	@:native("_hx_mysql_server_version")
	extern private static function __serverVersion(handle:Dynamic):String;

	@:native("_hx_mysql_close")
	extern private static function __close(handle:Dynamic):Dynamic;

	@:native("_hx_mysql_escape")
	extern private static function __escape(handle:Dynamic, str:String):String;

	@:native("_hx_mysql_server_status")
	extern private static function __serverStatus(handle:Dynamic):Int;

	@:native("_hx_mysql_is_tls")
	extern private static function __isTls(handle:Dynamic):Bool;

	@:native("_hx_mysql_auth_plugin")
	extern private static function __authPlugin(handle:Dynamic):String;

	@:native("_hx_mysql_result_get_length")
	extern private static function __resultGetLength(handle:Dynamic):Int;

	@:native("_hx_mysql_result_get_nfields")
	extern private static function __resultGetNFields(handle:Dynamic):Int;

	@:native("_hx_mysql_result_next")
	extern private static function __resultNext(handle:Dynamic):Dynamic;

	@:native("_hx_mysql_result_get")
	extern private static function __resultGet(handle:Dynamic, i:Int):String;

	@:native("_hx_mysql_result_get_int")
	extern private static function __resultGetInt(handle:Dynamic, i:Int):Int;

	@:native("_hx_mysql_result_get_float")
	extern private static function __resultGetFloat(handle:Dynamic, i:Int):Float;

	@:native("_hx_mysql_result_get_fields_names")
	extern private static function __resultGetFieldsNames(handle:Dynamic):Array<String>;

	@:native("_hx_mysql_set_conversion")
	extern private static function __setConversion(charsToBytes:cpp.Callable<Dynamic->Dynamic>, intToDate:cpp.Callable<Float->Dynamic>):Void;
}
#end
