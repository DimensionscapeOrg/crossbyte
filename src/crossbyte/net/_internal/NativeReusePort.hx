package crossbyte.net._internal;

#if cpp
/**
	Sets `SO_REUSEPORT` on an hxcpp socket handle, for `ReusePort`. Answers
	why it could not, or null once it is set.
**/
@:noCompletion
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/net/_internal/NativeReusePortBuild.xml"/>')
@:include("./NativeReusePort.h")
extern class NativeReusePort {
	@:native("crossbyte_socket_reuse_port") public static function set(socket:Dynamic):Null<String>;
}
#end
