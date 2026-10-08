#include <hxcpp.h>
#include "NativeKeepAlive.h"

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mstcpip.h>
typedef int KeepAliveLen;
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
typedef int SOCKET;
#define INVALID_SOCKET (-1)
typedef socklen_t KeepAliveLen;
#endif

/*
	TCP keepalive for the database clients that drive a sys.net.Socket of
	their own (MongoDB's), the way the hxcpp fork's MySQL client sets it
	on its socket: so a connection to a server that has vanished, a partition
	or a host that died without closing, is noticed rather than waited on.
	The same calls and the same rules: `idle` seconds without traffic before
	the first probe, `interval` between probes, `count` unanswered probes
	before the connection is dropped, and 0 for each leaves the system's own.
	Windows before 10 (1703) has no count to set, and keeps it at ten.
*/

namespace {

// hxcpp's socket handle, as NativeSocketAddress.cpp reads it: the socket is
// the wrapper's one field.
struct KeepAliveSocketWrapper : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };

	SOCKET socket;
};

static SOCKET keepalive_socket(Dynamic handle) {
	if (handle.mPtr == 0) {
		return INVALID_SOCKET;
	}

	return reinterpret_cast<KeepAliveSocketWrapper*>(handle.mPtr)->socket;
}

static int keepalive_option(SOCKET s, int level, int option) {
	// Zeroed first: Windows writes SO_KEEPALIVE as a single byte.
	int value = 0;
	KeepAliveLen size = sizeof(value);

	if (getsockopt(s, level, option, (char*)&value, &size) != 0) {
		return -1;
	}

	return value;
}

}

bool crossbyte_db_keepalive_set(Dynamic handle, bool on, int idle, int interval, int count) {
	SOCKET s = keepalive_socket(handle);

	if (s == INVALID_SOCKET) {
		return false;
	}

	int flag = on ? 1 : 0;

	if (setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, (const char*)&flag, sizeof(flag)) != 0) {
		return false;
	}

	if (!on) {
		return true;
	}

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	if (idle > 0 || interval > 0) {
		// Both at once, or neither: the system's own are two hours and one
		// second.
		struct tcp_keepalive values;
		DWORD returned = 0;
		values.onoff = 1;
		values.keepalivetime = (ULONG)(idle > 0 ? idle : 7200) * 1000;
		values.keepaliveinterval = (ULONG)(interval > 0 ? interval : 1) * 1000;

		if (WSAIoctl(s, SIO_KEEPALIVE_VALS, &values, sizeof(values), NULL, 0, &returned, NULL, NULL) != 0) {
			return false;
		}
	}
#ifdef TCP_KEEPCNT
	// Refused where Windows is too old to know it, which leaves the ten.
	if (count > 0) {
		setsockopt(s, IPPROTO_TCP, TCP_KEEPCNT, (const char*)&count, sizeof(count));
	}
#endif
#else
#if defined(TCP_KEEPIDLE)
	if (idle > 0) {
		setsockopt(s, IPPROTO_TCP, TCP_KEEPIDLE, (const char*)&idle, sizeof(idle));
	}
#elif defined(TCP_KEEPALIVE)
	if (idle > 0) {
		setsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, (const char*)&idle, sizeof(idle));
	}
#endif
#ifdef TCP_KEEPINTVL
	if (interval > 0) {
		setsockopt(s, IPPROTO_TCP, TCP_KEEPINTVL, (const char*)&interval, sizeof(interval));
	}
#endif
#ifdef TCP_KEEPCNT
	if (count > 0) {
		setsockopt(s, IPPROTO_TCP, TCP_KEEPCNT, (const char*)&count, sizeof(count));
	}
#endif
#endif
	return true;
}

/*
	The keepalive the socket has, read back from it rather than taken from
	what was asked for: on (0 or 1), then the idle and interval in seconds
	and the probe count, each -1 where the system does not report it.
*/
Array<int> crossbyte_db_keepalive_state(Dynamic handle) {
	Array<int> state = Array_obj<int>::__new(4, 4);
	SOCKET s = keepalive_socket(handle);

	for (int i = 0; i < 4; ++i) {
		state[i] = -1;
	}

	if (s == INVALID_SOCKET) {
		return state;
	}

	int on = keepalive_option(s, SOL_SOCKET, SO_KEEPALIVE);
	state[0] = on < 0 ? -1 : (on != 0 ? 1 : 0);
#if defined(TCP_KEEPIDLE)
	state[1] = keepalive_option(s, IPPROTO_TCP, TCP_KEEPIDLE);
#elif defined(TCP_KEEPALIVE)
	state[1] = keepalive_option(s, IPPROTO_TCP, TCP_KEEPALIVE);
#endif
#ifdef TCP_KEEPINTVL
	state[2] = keepalive_option(s, IPPROTO_TCP, TCP_KEEPINTVL);
#endif
#ifdef TCP_KEEPCNT
	state[3] = keepalive_option(s, IPPROTO_TCP, TCP_KEEPCNT);
#endif
	return state;
}
