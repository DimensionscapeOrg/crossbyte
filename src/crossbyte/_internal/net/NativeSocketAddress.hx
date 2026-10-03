package crossbyte._internal.net;

#if cpp
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/_internal/net/NativeSocketAddressBuild.xml"/>')
@:include("./NativeSocketAddress.h")
extern class NativeSocketAddress {
	@:native("crossbyte_socket_accept") public static function accept(socket:Dynamic):Dynamic;
	@:native("crossbyte_socket_host_info") public static function hostInfo(socket:Dynamic):Array<Int>;
	@:native("crossbyte_socket_peer_info") public static function peerInfo(socket:Dynamic):Array<Int>;
	@:native("crossbyte_socket_send_to") public static function sendTo(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int, address:Dynamic):Int;
	@:native("crossbyte_socket_recv_from") public static function recvFrom(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int, address:Dynamic):Int;
	@:native("crossbyte_socket_connect_error") public static function connectError(socket:Dynamic):Null<String>;
	@:native("crossbyte_socket_send_batch") public static function sendBatch(socket:Dynamic, buffer:haxe.io.BytesData, spans:Array<Int>, targets:Array<Dynamic>, first:Int, count:Int):Int;
	/** hxcpp's select, by poll on POSIX: no ceiling on a descriptor's number there. **/
	@:native("crossbyte_socket_select") public static function select(rs:Array<Dynamic>, ws:Array<Dynamic>, es:Array<Dynamic>, timeout:Dynamic):Array<Dynamic>;

	/**
		The transfers without an exception for "would block": -1 when the
		socket has nothing to give or no room to take; a real failure still
		throws, as the throwing forms do. `tryRecv` answers 0 at the end of
		the stream.
	**/
	@:native("crossbyte_socket_try_send") public static function trySend(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int):Int;
	@:native("crossbyte_socket_try_recv") public static function tryRecv(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int):Int;
	@:native("crossbyte_socket_try_send_to") public static function trySendTo(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int, address:Dynamic):Int;
	@:native("crossbyte_socket_try_recv_from") public static function tryRecvFrom(socket:Dynamic, buffer:haxe.io.BytesData, position:Int, length:Int, address:Dynamic):Int;
}
#end
