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
')
class NativeMySQL {
	public static inline var STATUS_IN_TRANS:Int = 0x0001;
	public static inline var STATUS_AUTOCOMMIT:Int = 0x0002;
	public static inline var STATUS_NO_BACKSLASH_ESCAPES:Int = 0x0200;

	@:noCompletion private static var __conversionsSet:Bool = false;

	public static function connect(params:Dynamic):Dynamic {
		if (!__conversionsSet) {
			// How the client turns a BLOB into Bytes and a DATETIME into a
			// Date; Haxe's own wrapper sets the same pair, so whichever runs
			// last leaves them as they were.
			__setConversion(cpp.Function.fromStaticFunction(__bytesOf), cpp.Function.fromStaticFunction(__dateOf));
			__conversionsSet = true;
		}

		return __connect(params);
	}

	public static function selectDatabase(handle:Dynamic, database:String):Void {
		__selectDb(handle, database);
	}

	public static function request(handle:Dynamic, sql:String):Dynamic {
		return __request(handle, sql);
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

	@:native("_hx_mysql_connect")
	extern private static function __connect(params:Dynamic):Dynamic;

	@:native("_hx_mysql_select_db")
	extern private static function __selectDb(handle:Dynamic, db:String):Void;

	@:native("_hx_mysql_request")
	extern private static function __request(handle:Dynamic, req:String):Dynamic;

	@:native("_hx_mysql_close")
	extern private static function __close(handle:Dynamic):Dynamic;

	@:native("_hx_mysql_escape")
	extern private static function __escape(handle:Dynamic, str:String):String;

	@:native("_hx_mysql_server_status")
	extern private static function __serverStatus(handle:Dynamic):Int;

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
