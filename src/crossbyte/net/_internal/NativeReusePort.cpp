#include <hxcpp.h>
#include "NativeReusePort.h"

#include <string.h>

#if defined(HX_WINDOWS)
#include <winsock2.h>
#else
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
typedef int SOCKET;
#define INVALID_SOCKET (-1)
#endif

// SO_REUSEPORT for ServerSocket.reusePort, set on a listener before it binds.
// Linux spreads the connections arriving on a port over every listening
// socket that set it; the Haxe side asks for it on Linux alone, and this
// refuses everywhere else rather than set an option that means something
// different there.

namespace {

static int reusePortSocketType = 0;

// The class id hxcpp gives its socket handles, learned from one, as the
// address glue beside this file does.
static int crossbyte_reuse_port_socket_type() {
	if (reusePortSocketType == 0) {
		Dynamic probe = _hx_std_socket_new(false, false);
		reusePortSocketType = probe->__GetType();
		_hx_std_socket_close(probe);
	}
	return reusePortSocketType;
}

// hxcpp's own handle: the descriptor straight after the object header.
struct ReusePortSocketWrapper : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };

	SOCKET socket;

	int __GetType() const {
		return crossbyte_reuse_port_socket_type();
	}
};

static SOCKET crossbyte_reuse_port_val_sock(Dynamic inValue) {
	if (inValue.mPtr == 0) {
		hx::Throw(HX_CSTRING("Invalid socket handle"));
		return INVALID_SOCKET;
	}

	if (inValue->__GetType() == vtClass) {
		inValue = inValue->__Field(HX_CSTRING("__s"), hx::paccNever);
		if (inValue.mPtr == 0) {
			hx::Throw(HX_CSTRING("Invalid socket handle"));
			return INVALID_SOCKET;
		}
	}

	return reinterpret_cast<ReusePortSocketWrapper*>(inValue.mPtr)->socket;
}

}

String crossbyte_socket_reuse_port(Dynamic socket) {
#if defined(__linux__) && defined(SO_REUSEPORT)
	SOCKET handle = crossbyte_reuse_port_val_sock(socket);
	int on = 1;
	if (setsockopt(handle, SOL_SOCKET, SO_REUSEPORT, reinterpret_cast<const char*>(&on), sizeof(on)) != 0) {
		return String(strerror(errno));
	}
	return null();
#else
	(void)socket;
	return HX_CSTRING("SO_REUSEPORT spreads connections over listeners on Linux only");
#endif
}
