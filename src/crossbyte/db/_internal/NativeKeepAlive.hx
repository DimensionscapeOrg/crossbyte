package crossbyte.db._internal;

#if cpp
/**
	TCP keepalive on an hxcpp socket handle (`sys.net.Socket.__s`), for the
	database clients that drive a socket of their own. See `SocketKeepAlive`.
**/
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/db/_internal/NativeKeepAliveBuild.xml"/>')
@:include("./NativeKeepAlive.h")
extern class NativeKeepAlive {
	/** Turns keepalive on or off, with the probe timing given; 0 leaves the system's. False when the system refused it. **/
	@:native("crossbyte_db_keepalive_set")
	public static function set(socket:Dynamic, on:Bool, idle:Int, interval:Int, count:Int):Bool;

	/** On (1 or 0), idle seconds, interval seconds, count; -1 where the system does not say. **/
	@:native("crossbyte_db_keepalive_state")
	public static function state(socket:Dynamic):Array<Int>;
}
#end
