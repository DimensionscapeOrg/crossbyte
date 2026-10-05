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

	/**
		Datagrams received in batches, by one `recvmmsg` (Linux; see
		NativeSocketAddress.cpp). `batchSupported` says whether there are
		any here; `batchNew` maps a batch of `capacity` slots of 64 KB, or
		answers null; `batchReceive` takes in up to `max` waiting datagrams,
		how many, -1 for none waiting, -2 for a kernel without the call,
		and `batchTake`/`batchCopy` read datagram `index` of them: its
		length and source, then its bytes. `batchFree` unmaps it now.
	**/
	@:native("crossbyte_udp_batch_supported") public static function batchSupported():Bool;
	@:native("crossbyte_udp_batch_new") public static function batchNew(capacity:Int):Dynamic;
	@:native("crossbyte_udp_batch_capacity") public static function batchCapacity(batch:Dynamic):Int;
	@:native("crossbyte_udp_batch_receive") public static function batchReceive(socket:Dynamic, batch:Dynamic, max:Int):Int;
	@:native("crossbyte_udp_batch_take") public static function batchTake(batch:Dynamic, index:Int, address:Dynamic):Int;
	@:native("crossbyte_udp_batch_copy") public static function batchCopy(batch:Dynamic, index:Int, buffer:haxe.io.BytesData, position:Int):Void;
	@:native("crossbyte_udp_batch_free") public static function batchFree(batch:Dynamic):Void;
}
#end
