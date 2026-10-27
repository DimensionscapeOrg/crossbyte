package crossbyte.db;

/**
	Silences a connection the way a partition does, for the tests of TCP
	keepalive: from the moment it is called, nothing arriving on the socket
	reaches TCP, keepalive probes included. A peer that only stops answering
	is no use for that: its system still acknowledges every probe, and the
	connection looks alive for ever.

	Linux only, through a socket filter (`SO_ATTACH_FILTER`, no privilege
	needed) that drops every segment for the socket before TCP sees it, so
	the system sends nothing back: no acknowledgement, no reset. Elsewhere
	`isSupported` is false, and the tests that need it pass over it.

	A file of its own because the C below has preprocessor lines, and the
	suite's coverage check, which reads a test class's conditionals off the
	start of each line, would take them for Haxe's.
**/
#if cpp
@:cppFileCode("
#ifdef __linux__
#include <sys/socket.h>
#include <linux/filter.h>
#include <errno.h>
#include <string.h>

// hxcpp's socket handle: the socket is the wrapper's one field.
struct crossbyte_dead_peer_wrapper : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };
	int socket;
};

// Null once the filter is on; otherwise why it is not.
static String crossbyte_dead_peer_silence(Dynamic handle) {
	if (handle.mPtr == 0) {
		return String(\"the socket has no handle\");
	}
	int fd = reinterpret_cast<crossbyte_dead_peer_wrapper*>(handle.mPtr)->socket;
	// One instruction, BPF_RET | BPF_K with 0: keep none of the packet.
	struct sock_filter code[1] = {{0x06, 0, 0, 0}};
	struct sock_fprog program;
	program.len = 1;
	program.filter = code;
	if (setsockopt(fd, SOL_SOCKET, SO_ATTACH_FILTER, &program, sizeof(program)) == 0) {
		return String();
	}
	int error = errno;
	return String(\"SO_ATTACH_FILTER on descriptor \") + String(fd) + String(\": errno \") + String(error) + String(\" \") + String(strerror(error));
}
#else
static String crossbyte_dead_peer_silence(Dynamic handle) {
	return String(\"not Linux\");
}
#endif
")
#end
class DeadPeerProbe {
	/** Whether `silence` can work here: natively on Linux. **/
	public static var isSupported(get, never):Bool;

	/** Why the last `silence` did not take, or null when it did. **/
	public static var refused(default, null):Null<String> = null;

	/**
		Drops everything that arrives on `socket` from now on. Answers
		whether the system took the filter, and when it did not, `refused`
		says why: the call's errno and its text.
	**/
	public static function silence(socket:sys.net.Socket):Bool {
		#if cpp
		refused = untyped __cpp__("crossbyte_dead_peer_silence({0})", @:privateAccess socket.__s);
		#else
		refused = "not native";
		#end
		return refused == null;
	}

	private static function get_isSupported():Bool {
		#if cpp
		return Sys.systemName() == "Linux";
		#else
		return false;
		#end
	}
}
