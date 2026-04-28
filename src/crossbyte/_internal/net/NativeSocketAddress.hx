package crossbyte._internal.net;

#if cpp
@:buildXml("
<files id='haxe'>
	<compilerflag value='-I../../src/crossbyte/_internal/net'/>
	<file name='../../src/crossbyte/_internal/net/NativeSocketAddress.cpp'>
		<depend name='../../src/crossbyte/_internal/net/NativeSocketAddress.h'/>
	</file>
</files>
")
@:include("NativeSocketAddress.h")
extern class NativeSocketAddress {
	@:native("crossbyte_socket_accept") public static function accept(socket:Dynamic):Dynamic;
	@:native("crossbyte_socket_host_info") public static function hostInfo(socket:Dynamic):Array<Int>;
	@:native("crossbyte_socket_peer_info") public static function peerInfo(socket:Dynamic):Array<Int>;
}
#end
