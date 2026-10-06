package crossbyte._internal.socket;

#if cpp
/**
	Socket options and process limits hxcpp's sockets do not reach: the size
	of a socket's send and receive buffers (`SO_SNDBUF`, `SO_RCVBUF`), and
	the process's limit on open descriptors (`RLIMIT_NOFILE`) on Linux and
	macOS.

	The C is in this class's own file, so nothing outside it is built for it.
**/
@:noCompletion
@:cppFileCode("
#ifdef HX_WINDOWS
#include <winsock2.h>
#else
#include <sys/socket.h>
#include <sys/resource.h>
#include <errno.h>
#ifdef __APPLE__
#include <sys/syslimits.h>
#endif
#endif

namespace {
// hxcpp's socket handle as its Socket.cpp declares it: an hx::Object holding
// the descriptor. Mirrored rather than reached, since hxcpp keeps it private
// to that file, and checked by class id before it is trusted, as
// DatagramSocket does.
struct CrossByteTcpHandle : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };
#ifdef HX_WINDOWS
	SOCKET socket;
#else
	int socket;
#endif
};

bool crossbyte_tcp_of(::Dynamic handle, CrossByteTcpHandle **out) {
	if (handle.mPtr == 0 || !handle.mPtr->_hx_isInstanceOf(hx::clsIdSocket)) {
		return false;
	}
	*out = reinterpret_cast<CrossByteTcpHandle *>(handle.mPtr);
	return true;
}
}

// One of a socket's buffer sizes, or -1 where it cannot be read.
static int crossbyte_tcp_buffer(::Dynamic handle, bool receive) {
	CrossByteTcpHandle *s;
	if (!crossbyte_tcp_of(handle, &s)) {
		return -1;
	}
	int size = 0;
#ifdef HX_WINDOWS
	int length = sizeof(size);
#else
	socklen_t length = sizeof(size);
#endif
	if (getsockopt(s->socket, SOL_SOCKET, receive ? SO_RCVBUF : SO_SNDBUF, (char *)&size, &length) != 0) {
		return -1;
	}
	return size;
}

// Asks for one of a socket's buffer sizes; false if the system refused.
static bool crossbyte_tcp_set_buffer(::Dynamic handle, bool receive, int size) {
	CrossByteTcpHandle *s;
	if (!crossbyte_tcp_of(handle, &s)) {
		return false;
	}
	return setsockopt(s->socket, SOL_SOCKET, receive ? SO_RCVBUF : SO_SNDBUF, (const char *)&size, sizeof(size)) == 0;
}

// The process's limit on open descriptors, soft then hard, clamped to an
// Int; -1 for both where there is none to read (Windows).
static void crossbyte_nofile(int *soft, int *hard) {
#ifdef HX_WINDOWS
	*soft = -1;
	*hard = -1;
#else
	struct rlimit limit;
	if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
		*soft = -1;
		*hard = -1;
		return;
	}
	*soft = (limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur > 0x7FFFFFFF) ? 0x7FFFFFFF : (int)limit.rlim_cur;
	*hard = (limit.rlim_max == RLIM_INFINITY || limit.rlim_max > 0x7FFFFFFF) ? 0x7FFFFFFF : (int)limit.rlim_max;
#endif
}

// Raises the soft limit on open descriptors to the hard one, as Go and the
// JVM do as they start; on macOS no higher than OPEN_MAX, past which it is
// refused there. The soft limit afterwards, or -1 where there is none.
static int crossbyte_raise_nofile() {
#ifdef HX_WINDOWS
	return -1;
#else
	struct rlimit limit;
	if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
		return -1;
	}
	if (limit.rlim_cur < limit.rlim_max) {
		struct rlimit raised = limit;
		raised.rlim_cur = limit.rlim_max;
		if (setrlimit(RLIMIT_NOFILE, &raised) != 0) {
#ifdef __APPLE__
			if (limit.rlim_cur < (rlim_t)OPEN_MAX) {
				raised.rlim_cur = (limit.rlim_max < (rlim_t)OPEN_MAX) ? limit.rlim_max : (rlim_t)OPEN_MAX;
				setrlimit(RLIMIT_NOFILE, &raised);
			}
#endif
		}
	}
	int soft = 0;
	int hard = 0;
	crossbyte_nofile(&soft, &hard);
	return soft;
#endif
}

// Sets the soft limit on open descriptors; false where it cannot be set.
static bool crossbyte_set_nofile(int soft) {
#ifdef HX_WINDOWS
	return false;
#else
	struct rlimit limit;
	if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
		return false;
	}
	limit.rlim_cur = (rlim_t)soft;
	return setrlimit(RLIMIT_NOFILE, &limit) == 0;
#endif
}
")
class NativeSocketOptions {
	/** One of `handle`'s buffer sizes as the system reports it, or -1. **/
	public static function bufferSize(handle:Dynamic, receive:Bool):Int {
		return untyped __cpp__("crossbyte_tcp_buffer({0}, {1})", handle, receive);
	}

	/** Asks for one of `handle`'s buffer sizes; false if the system refused. **/
	public static function setBufferSize(handle:Dynamic, receive:Bool, size:Int):Bool {
		return untyped __cpp__("crossbyte_tcp_set_buffer({0}, {1}, {2})", handle, receive, size);
	}

	/** The soft limit on open descriptors, or -1 where there is none. **/
	public static function descriptorLimit():Int {
		var soft:Int = 0;
		var hard:Int = 0;
		untyped __cpp__("crossbyte_nofile(&{0}, &{1})", soft, hard);
		return soft;
	}

	/** The hard limit on open descriptors, or -1 where there is none. **/
	public static function descriptorHardLimit():Int {
		var soft:Int = 0;
		var hard:Int = 0;
		untyped __cpp__("crossbyte_nofile(&{0}, &{1})", soft, hard);
		return hard;
	}

	/** Raises the soft limit to the hard one where it can: the soft limit after, or -1. **/
	public static function raiseDescriptorLimit():Int {
		return untyped __cpp__("crossbyte_raise_nofile()");
	}

	/** Sets the soft limit on open descriptors, for tests; false where it cannot. **/
	public static function setDescriptorLimit(soft:Int):Bool {
		return untyped __cpp__("crossbyte_set_nofile({0})", soft);
	}
}
#end
