#include <hxcpp.h>
#include "NativeSocketAddress.h"

#include <string.h>

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
#include <winsock2.h>
#include <Ws2tcpip.h>
typedef int SocketLen;
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
typedef int SOCKET;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
typedef socklen_t SocketLen;
#endif

namespace {

static int stdSocketType = 0;

static int crossbyte_socket_type() {
	if (stdSocketType == 0) {
		Dynamic probe = _hx_std_socket_new(false, false);
		stdSocketType = probe->__GetType();
		_hx_std_socket_close(probe);
	}
	return stdSocketType;
}

struct SocketWrapper : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };

	SOCKET socket;

	int __GetType() const {
		return crossbyte_socket_type();
	}
};

static SOCKET crossbyte_val_sock(Dynamic inValue) {
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

	return reinterpret_cast<SocketWrapper*>(inValue.mPtr)->socket;
}

static Array<int> crossbyte_address_to_array(const sockaddr* address, SocketLen length) {
	if (address == 0) {
		return null();
	}

	if (address->sa_family == AF_INET && length >= (SocketLen)sizeof(sockaddr_in)) {
		const sockaddr_in* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
		Array<int> result = Array_obj<int>::__new(2, 2);
		result[0] = *(const int*)&ipv4->sin_addr;
		result[1] = ntohs(ipv4->sin_port);
		return result;
	}

	if (address->sa_family == AF_INET6 && length >= (SocketLen)sizeof(sockaddr_in6)) {
		const sockaddr_in6* ipv6 = reinterpret_cast<const sockaddr_in6*>(address);
		const unsigned char* bytes = reinterpret_cast<const unsigned char*>(&ipv6->sin6_addr);
		Array<int> result = Array_obj<int>::__new(18, 18);
		result[0] = 0;
		result[1] = ntohs(ipv6->sin6_port);
		for (int i = 0; i < 16; ++i) {
			result[i + 2] = bytes[i];
		}
		return result;
	}

	return null();
}

static Array<int> crossbyte_socket_name_info(Dynamic socket, bool peer) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	sockaddr_storage address;
	memset(&address, 0, sizeof(address));
	SocketLen addressLength = sizeof(address);

	hx::EnterGCFreeZone();
	int status = peer
		? getpeername(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength)
		: getsockname(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength);
	hx::ExitGCFreeZone();

	if (status == SOCKET_ERROR) {
		return null();
	}

	return crossbyte_address_to_array(reinterpret_cast<sockaddr*>(&address), addressLength);
}

static void crossbyte_block_error() {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	int error = WSAGetLastError();
	hx::ExitGCFreeZone();
	if (error == WSAEWOULDBLOCK || error == WSAEALREADY) {
		hx::Throw(HX_CSTRING("Blocking"));
	}
#else
	hx::ExitGCFreeZone();
	if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS || errno == EALREADY) {
		hx::Throw(HX_CSTRING("Blocking"));
	}
#endif
	hx::Throw(HX_CSTRING("Socket operation failed"));
}

} // namespace

Dynamic crossbyte_socket_accept(Dynamic socket) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	sockaddr_storage address;
	memset(&address, 0, sizeof(address));
	SocketLen addressLength = sizeof(address);

	hx::EnterGCFreeZone();
	SOCKET accepted = accept(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength);
	if (accepted == INVALID_SOCKET) {
		crossbyte_block_error();
	}
	hx::ExitGCFreeZone();

	SocketWrapper* wrapper = new SocketWrapper();
	wrapper->socket = accepted;
	return wrapper;
}

Array<int> crossbyte_socket_host_info(Dynamic socket) {
	return crossbyte_socket_name_info(socket, false);
}

Array<int> crossbyte_socket_peer_info(Dynamic socket) {
	return crossbyte_socket_name_info(socket, true);
}
