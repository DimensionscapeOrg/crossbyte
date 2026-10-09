#include <hxcpp.h>
#include "NativeSocketAddress.h"

#include <string.h>

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
#include <winsock2.h>
#include <Ws2tcpip.h>
typedef int SocketLen;
#else
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <limits.h>
#include <math.h>
#include <vector>
#if defined(__linux__)
#include <netinet/udp.h>
#include <sys/mman.h>
#endif
typedef int SOCKET;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
typedef socklen_t SocketLen;
#endif

#if !defined(MSG_NOSIGNAL)
#define MSG_NOSIGNAL 0
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

static void crossbyte_sockaddr_to_dynamic(const sockaddr* address, SocketLen length, Dynamic outAddress) {
	if (address == 0 || outAddress.mPtr == 0) {
		return;
	}

	if (address->sa_family == AF_INET && length >= (SocketLen)sizeof(sockaddr_in)) {
		const sockaddr_in* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
		outAddress->__SetField(HX_CSTRING("host"), *(const int*)&ipv4->sin_addr, hx::paccDynamic);
		outAddress->__SetField(HX_CSTRING("port"), ntohs(ipv4->sin_port), hx::paccDynamic);
		outAddress->__SetField(HX_CSTRING("ipv6"), null(), hx::paccDynamic);
		return;
	}

	if (address->sa_family == AF_INET6 && length >= (SocketLen)sizeof(sockaddr_in6)) {
		const sockaddr_in6* ipv6 = reinterpret_cast<const sockaddr_in6*>(address);
		const unsigned char* bytes = reinterpret_cast<const unsigned char*>(&ipv6->sin6_addr);
		Array<unsigned char> encoded = Array_obj<unsigned char>::__new(16, 16);
		for (int i = 0; i < 16; ++i) {
			encoded[i] = bytes[i];
		}
		outAddress->__SetField(HX_CSTRING("host"), 0, hx::paccDynamic);
		outAddress->__SetField(HX_CSTRING("port"), ntohs(ipv6->sin6_port), hx::paccDynamic);
		outAddress->__SetField(HX_CSTRING("ipv6"), encoded, hx::paccDynamic);
	}
}

static void crossbyte_dynamic_to_sockaddr(Dynamic inAddress, sockaddr_storage& storage, SocketLen& length) {
	memset(&storage, 0, sizeof(storage));

	int port = inAddress->__Field(HX_CSTRING("port"), hx::paccDynamic);
	Dynamic ipv6Value = inAddress->__Field(HX_CSTRING("ipv6"), hx::paccDynamic);

	if (ipv6Value.mPtr != 0) {
		Array<unsigned char> ipv6 = ipv6Value.Cast<Array<unsigned char> >();
		if (ipv6->length < 16) {
			hx::Throw(HX_CSTRING("Invalid IPv6 address"));
		}

		sockaddr_in6* address = reinterpret_cast<sockaddr_in6*>(&storage);
		address->sin6_family = AF_INET6;
		address->sin6_port = htons(port);
		memcpy(&address->sin6_addr, &ipv6[0], 16);
		length = sizeof(sockaddr_in6);
		return;
	}

	int host = inAddress->__Field(HX_CSTRING("host"), hx::paccDynamic);
	sockaddr_in* address = reinterpret_cast<sockaddr_in*>(&storage);
	address->sin_family = AF_INET;
	address->sin_port = htons(port);
	*(int*)&address->sin_addr.s_addr = host;
	length = sizeof(sockaddr_in);
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
	SOCKET accepted;
	// Not inherited by a process started while the connection is open: a
	// child holding a copy keeps the connection open after it is closed
	// here. Close-on-exec from accept4 where there is one, so a process
	// another thread starts meanwhile cannot take it either.
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	accepted = accept(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength);
#else
	// ECONNABORTED is a connection reset while it waited in the queue: macOS
	// and the BSDs fail its accept, where Linux and Windows hand it over.
	// That connection is gone, not the listener, so this takes the next, as
	// libuv and Go do, rather than report the server's own failure
	// whenever a client connected and reset.
	do {
		addressLength = sizeof(address);
	#if defined(HX_LINUX) && defined(SOCK_CLOEXEC)
		accepted = accept4(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength, SOCK_CLOEXEC);
	#else
		accepted = accept(nativeSocket, reinterpret_cast<sockaddr*>(&address), &addressLength);
	#endif
	} while (accepted == INVALID_SOCKET && (errno == EINTR || errno == ECONNABORTED));
#endif
	if (accepted == INVALID_SOCKET) {
		crossbyte_block_error();
	}
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	SetHandleInformation((HANDLE)accepted, HANDLE_FLAG_INHERIT, 0);
#else
	#if !(defined(HX_LINUX) && defined(SOCK_CLOEXEC))
	int descriptorFlags = fcntl(accepted, F_GETFD, 0);
	if (descriptorFlags >= 0) {
		fcntl(accepted, F_SETFD, descriptorFlags | FD_CLOEXEC);
	}
	#endif
	#ifdef __APPLE__
	int noSigPipe = 1;
	setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
	#endif
#endif
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

int crossbyte_socket_send_to(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	// `length > bufferLength - position` rather than `position + length >
	// bufferLength`. position is already known to be within the buffer, so
	// the subtraction cannot go negative, while the sum overflows for a
	// large length, and signed overflow is undefined here, so a compiler
	// is entitled to assume it cannot happen and drop the test.
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		hx::Throw(HX_CSTRING("Invalid data position"));
	}

	sockaddr_storage nativeAddress;
	SocketLen nativeAddressLength = 0;
	crossbyte_dynamic_to_sockaddr(address, nativeAddress, nativeAddressLength);

	const char* data = (const char*)&buffer[0];

	hx::EnterGCFreeZone();
	int sent;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	sent = sendto(
		nativeSocket,
		data + position,
		length,
		MSG_NOSIGNAL,
		reinterpret_cast<sockaddr*>(&nativeAddress),
		nativeAddressLength
	);
#else
	do {
		sent = sendto(
			nativeSocket,
			data + position,
			length,
			MSG_NOSIGNAL,
			reinterpret_cast<sockaddr*>(&nativeAddress),
			nativeAddressLength
		);
		// A connected datagram socket: macOS and the BSDs refuse an address
		// on its sends (EISCONN), where Linux takes the one it is connected
		// to. DatagramSocket names its peer whether or not it is connected,
		// so the send goes again without one: the peer it is connected to is
		// the only one it may send to.
		if (sent == SOCKET_ERROR && errno == EISCONN) {
			sent = send(nativeSocket, data + position, length, MSG_NOSIGNAL);
		}
	} while (sent == SOCKET_ERROR && errno == EINTR);
#endif
	if (sent == SOCKET_ERROR) {
		crossbyte_block_error();
	}
	hx::ExitGCFreeZone();
	return sent;
}

int crossbyte_socket_recv_from(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	// `length > bufferLength - position` rather than `position + length >
	// bufferLength`. position is already known to be within the buffer, so
	// the subtraction cannot go negative, while the sum overflows for a
	// large length, and signed overflow is undefined here, so a compiler
	// is entitled to assume it cannot happen and drop the test.
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		hx::Throw(HX_CSTRING("Invalid data position"));
	}

	sockaddr_storage nativeAddress;
	memset(&nativeAddress, 0, sizeof(nativeAddress));
	SocketLen nativeAddressLength = sizeof(nativeAddress);
	char* data = (char*)&buffer[0];

	hx::EnterGCFreeZone();
	int received;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	received = recvfrom(
		nativeSocket,
		data + position,
		length,
		MSG_NOSIGNAL,
		reinterpret_cast<sockaddr*>(&nativeAddress),
		&nativeAddressLength
	);
#else
	do {
		received = recvfrom(
			nativeSocket,
			data + position,
			length,
			MSG_NOSIGNAL,
			reinterpret_cast<sockaddr*>(&nativeAddress),
			&nativeAddressLength
		);
	} while (received == SOCKET_ERROR && errno == EINTR);
#endif
	if (received == SOCKET_ERROR) {
		crossbyte_block_error();
	}
	hx::ExitGCFreeZone();

	crossbyte_sockaddr_to_dynamic(reinterpret_cast<sockaddr*>(&nativeAddress), nativeAddressLength, address);
	return received;
}

/*
	The same four transfers without an exception for "would block": each
	answers -1 when the socket has nothing to give or no room to take, and
	throws only for a real failure, as the throwing forms do.

	A would-block is the ordinary end of every pass over a non-blocking
	socket (the read that finds a UDP socket empty, the send a slow peer's
	full window refuses), and reported by a C++ throw it costs 1.9 us, caught
	in Haxe and thrown again as haxe.io.Error.Blocked for 4.3 us in all,
	where the call itself is a few hundred nanoseconds. A server writing to
	a peer that stopped reading would pay that on every pass, for every such
	peer.
*/
namespace {

// True when the last call failed only because it would have blocked. Read
// before leaving the GC-free zone: leaving it can clear the error code.
static bool crossbyte_would_block() {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	int error = WSAGetLastError();
	return error == WSAEWOULDBLOCK || error == WSAEALREADY;
#else
	return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS || errno == EALREADY;
#endif
}

// True when the last receive failed with an earlier datagram's ICMP error
// rather than anything about this socket: on Windows a "port unreachable"
// (WSAECONNRESET) or "TTL expired" (WSAENETRESET) for something this socket
// sent, reported on whichever read comes next unless switched off (see
// crossbyte_udp_ignore_unreachable); elsewhere the same for a connected
// socket (ECONNREFUSED, and the unreachable host or network). Nothing was
// received, and the socket is as good as before. Read, as the above,
// inside the GC-free zone.
static bool crossbyte_unreachable_report() {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	int error = WSAGetLastError();
	return error == WSAECONNRESET || error == WSAENETRESET;
#else
	return errno == ECONNREFUSED || errno == EHOSTUNREACH || errno == ENETUNREACH;
#endif
}

// True when the last send failed because its datagram is larger than the
// socket can send (EMSGSIZE): past UDP's 65,507 bytes over IPv4 or 65,527
// over IPv6 anywhere, and on macOS past the socket's send buffer, 9,216
// bytes unless raised. Read, as the above, inside the GC-free zone.
static bool crossbyte_too_large() {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	return WSAGetLastError() == WSAEMSGSIZE;
#else
	return errno == EMSGSIZE;
#endif
}

}

/**
	What a send of a datagram too large for its socket throws, in place of
	"Socket operation failed", so DatagramSocket can name the datagram's size
	and the socket's send buffer.
**/
#define CROSSBYTE_TOO_LARGE "Datagram too large"

/**
	`send`, or -1 when the socket's buffer is full. Any other failure throws
	"EOF", as hxcpp's `socket_send` does, so the two map to the same Haxe
	errors. An out-of-range position or length sends nothing, as there.
**/
int crossbyte_socket_try_send(Dynamic socket, Array<unsigned char> buffer, int position, int length) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		return 0;
	}

	// volatile: the start of the buffer stays visible in this frame, so the
	// collector's conservative scan keeps it in place while send reads it.
	const char* volatile data = (const char*)&buffer[0];
	hx::EnterGCFreeZone();
	int sent;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	sent = send(nativeSocket, data + position, length, MSG_NOSIGNAL);
#else
	do {
		sent = send(nativeSocket, data + position, length, MSG_NOSIGNAL);
	} while (sent == SOCKET_ERROR && errno == EINTR);
#endif
	if (sent == SOCKET_ERROR) {
		bool wouldBlock = crossbyte_would_block();
		hx::ExitGCFreeZone();
		if (wouldBlock) {
			return -1;
		}
		hx::Throw(HX_CSTRING("EOF"));
	}
	hx::ExitGCFreeZone();
	return sent;
}

/**
	`recv`, or -1 when nothing is waiting; 0 is the end of the stream. Any
	other failure throws "EOF", as hxcpp's `socket_recv` does.
**/
int crossbyte_socket_try_recv(Dynamic socket, Array<unsigned char> buffer, int position, int length) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		return 0;
	}

	char* volatile data = (char*)&buffer[0];
	hx::EnterGCFreeZone();
	int received;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	received = recv(nativeSocket, data + position, length, MSG_NOSIGNAL);
	if (received == SOCKET_ERROR && WSAGetLastError() == WSAEMSGSIZE) {
		// As hxcpp's recv: a datagram longer than the buffer filled it.
		hx::ExitGCFreeZone();
		return length;
	}
#else
	do {
		received = recv(nativeSocket, data + position, length, MSG_NOSIGNAL);
	} while (received == SOCKET_ERROR && errno == EINTR);
#endif
	if (received == SOCKET_ERROR) {
		bool wouldBlock = crossbyte_would_block();
		hx::ExitGCFreeZone();
		if (wouldBlock) {
			return -1;
		}
		hx::Throw(HX_CSTRING("EOF"));
	}
	hx::ExitGCFreeZone();
	return received;
}

/** `crossbyte_socket_send_to`, answering -1 for a full buffer rather than throwing. **/
int crossbyte_socket_try_send_to(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		hx::Throw(HX_CSTRING("Invalid data position"));
	}

	sockaddr_storage nativeAddress;
	SocketLen nativeAddressLength = 0;
	crossbyte_dynamic_to_sockaddr(address, nativeAddress, nativeAddressLength);

	const char* volatile data = (const char*)&buffer[0];

	hx::EnterGCFreeZone();
	int sent;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	sent = sendto(nativeSocket, data + position, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&nativeAddress), nativeAddressLength);
#else
	do {
		sent = sendto(nativeSocket, data + position, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&nativeAddress), nativeAddressLength);
		// See crossbyte_socket_send_to: a connected socket on macOS and the BSDs.
		if (sent == SOCKET_ERROR && errno == EISCONN) {
			sent = send(nativeSocket, data + position, length, MSG_NOSIGNAL);
		}
	} while (sent == SOCKET_ERROR && errno == EINTR);
#endif
	if (sent == SOCKET_ERROR) {
		bool wouldBlock = crossbyte_would_block();
		bool tooLarge = !wouldBlock && crossbyte_too_large();
		hx::ExitGCFreeZone();
		if (wouldBlock) {
			return -1;
		}
		if (tooLarge) {
			hx::Throw(HX_CSTRING(CROSSBYTE_TOO_LARGE));
		}
		hx::Throw(HX_CSTRING("Socket operation failed"));
	}
	hx::ExitGCFreeZone();
	return sent;
}

/**
	`crossbyte_socket_recv_from`, answering -1 when nothing is waiting rather
	than throwing; `address` is left as it was then.
**/
int crossbyte_socket_try_recv_from(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
		hx::Throw(HX_CSTRING("Invalid data position"));
	}

	sockaddr_storage nativeAddress;
	memset(&nativeAddress, 0, sizeof(nativeAddress));
	SocketLen nativeAddressLength = sizeof(nativeAddress);
	char* volatile data = (char*)&buffer[0];

	hx::EnterGCFreeZone();
	int received;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	received = recvfrom(nativeSocket, data + position, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&nativeAddress), &nativeAddressLength);
#else
	do {
		received = recvfrom(nativeSocket, data + position, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&nativeAddress), &nativeAddressLength);
	} while (received == SOCKET_ERROR && errno == EINTR);
#endif
	if (received == SOCKET_ERROR) {
		bool wouldBlock = crossbyte_would_block();
		bool unreachable = crossbyte_unreachable_report();
		hx::ExitGCFreeZone();
		if (wouldBlock) {
			return -1;
		}
		if (unreachable) {
			return -3;
		}
		hx::Throw(HX_CSTRING("Socket operation failed"));
	}
	hx::ExitGCFreeZone();

	crossbyte_sockaddr_to_dynamic(reinterpret_cast<sockaddr*>(&nativeAddress), nativeAddressLength, address);
	return received;
}

/**
	Stops Windows reporting an earlier datagram's ICMP error (a "port
	unreachable" for something this socket sent, or "TTL expired") as a
	failed receive on this socket: it does so unless told not to, on
	whichever read comes next, though nothing is wrong with the socket. Elsewhere
	an unconnected datagram socket is told nothing of them. Nothing to do,
	and nothing reported, where the system refuses.
**/
void crossbyte_udp_ignore_unreachable(Dynamic socket) {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	BOOL report = FALSE;
	DWORD returned = 0;
	// SIO_UDP_CONNRESET and SIO_UDP_NETRESET, from mstcpip.h.
	WSAIoctl(nativeSocket, _WSAIOW(IOC_VENDOR, 12), &report, sizeof(report), 0, 0, &returned, 0, 0);
	WSAIoctl(nativeSocket, _WSAIOW(IOC_VENDOR, 15), &report, sizeof(report), 0, 0, &returned, 0, 0);
#endif
}

/**
	Why a non-blocking connect failed, or null when it did not: SO_ERROR, in
	the system's words. A connect that has finished, either way, makes the
	socket writable, and on POSIX a refused or unreachable one is writable
	too; only SO_ERROR tells them apart. Windows reports the failure in
	select's exception set instead, and the answer here agrees with it.
**/
String crossbyte_socket_connect_error(Dynamic socket) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int error = 0;
	SocketLen length = sizeof(error);

	if (getsockopt(nativeSocket, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &length) == SOCKET_ERROR) {
		return String::create("the socket could not say whether it connected");
	}

	if (error == 0) {
		return null();
	}

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	char text[256];
	DWORD written = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, 0, (DWORD)error, 0, text, sizeof(text), 0);
	while (written > 0 && (text[written - 1] == '\r' || text[written - 1] == '\n' || text[written - 1] == '.')) {
		text[--written] = 0;
	}
	return written > 0 ? String::create(text) : String::create("connect failed");
#else
	return String::create(strerror(error));
#endif
}

#if defined(__linux__)
#ifndef SOL_UDP
#define SOL_UDP 17
#endif
#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif

namespace {
// Whether the kernel takes UDP_SEGMENT. Assumed until a send says otherwise:
// a kernel before 4.18, or a device that cannot checksum for it, refuses
// with one of these, and every send after goes without.
static volatile bool crossbyte_udp_gso = true;

static bool crossbyte_gso_refused(int error) {
	return error == EINVAL || error == EIO || error == EOPNOTSUPP || error == ENOPROTOOPT;
}

// How many datagrams from `first` form a run worth cutting from one send:
// to one peer, lying end to end in one chunk, each as long as the first but
// the last, which may be shorter. At most 64 of them and 65,000 bytes, which
// every kernel that cuts at all accepts.
static int crossbyte_gso_run(Array<int> spans, Array<Dynamic> targets, int first, int count, int& total) {
	int segment = spans[3 * first + 2];
	total = segment;
	if (segment <= 0) {
		return 1;
	}
	int run = 1;
	while (first + run < count && run < 64) {
		int k = first + run;
		int length = spans[3 * k + 2];
		if (targets[k].mPtr != targets[first].mPtr || spans[3 * k] != spans[3 * first]
				|| spans[3 * k + 1] != spans[3 * first + 1] + total
				|| length <= 0 || length > segment || total + length > 65000) {
			break;
		}
		total += length;
		run++;
		if (length < segment) {
			break;
		}
	}
	return run;
}
}
#endif

// Where datagram `k` of a batch starts: in chunk `spans[3k]`, at
// `spans[3k + 1]` (checked by crossbyte_socket_send_batch first).
static inline const char* crossbyte_batch_data(Array<Dynamic>& chunks, Array<int>& spans, int k) {
	Array<unsigned char> chunk = chunks[spans[3 * k]];
	return (const char*)chunk->GetBase() + spans[3 * k + 1];
}

/**
	Sends datagrams `first` to `count` of a batch: datagram i is
	`spans[3i + 2]` bytes of chunk `spans[3i]` (one of `chunks`, each a
	BytesData) from `spans[3i + 1]`, to `targets[i]`, a sys.net.Address.
	Each datagram lies whole in one chunk, so the chunks need not follow one
	another: each datagram's iovec points into its own. Answers how many
	went, from `first`, before one did not; that one is for the caller to
	send alone, which raises what stopped it.

	On Linux a run to one peer (end to end in one chunk, each the same length
	but the last) goes as one send the kernel cuts up (UDP_SEGMENT): over
	loopback, a seventh of the CPU a datagram that sending them one at a time
	costs. The rest go 64 to a call with sendmmsg. Elsewhere each is a sendto.
**/
int crossbyte_socket_send_batch(Dynamic socket, Array<Dynamic> chunks, Array<int> spans, Array<Dynamic> targets, int first, int count) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	if (first < 0 || count < first || count > targets->length || count > spans->length / 3) {
		hx::Throw(HX_CSTRING("Invalid batch"));
	}
	int chunkCount = chunks->length;
	for (int i = first; i < count; ++i) {
		int index = spans[3 * i];
		int position = spans[3 * i + 1];
		int length = spans[3 * i + 2];
		if (index < 0 || index >= chunkCount) {
			hx::Throw(HX_CSTRING("Invalid data position"));
		}
		Array<unsigned char> chunk = chunks[index];
		int chunkLength = chunk.mPtr ? chunk->length : 0;
		if (chunkLength <= 0 || position < 0 || length < 0 || position > chunkLength || length > chunkLength - position) {
			hx::Throw(HX_CSTRING("Invalid data position"));
		}
	}

	int sent = 0;
	int i = first;

#if defined(__linux__)
	enum { BATCH = 64 };
	struct mmsghdr messages[BATCH];
	struct iovec pieces[BATCH];
	sockaddr_storage names[BATCH];

	while (i < count) {
		if (crossbyte_udp_gso) {
			int total = 0;
			int run = crossbyte_gso_run(spans, targets, i, count, total);
			if (run >= 2) {
				sockaddr_storage name;
				SocketLen nameLength = 0;
				crossbyte_dynamic_to_sockaddr(targets[i], name, nameLength);

				char control[CMSG_SPACE(sizeof(unsigned short))];
				memset(control, 0, sizeof(control));
				struct iovec whole;
				whole.iov_base = (void*)crossbyte_batch_data(chunks, spans, i);
				whole.iov_len = total;
				struct msghdr message;
				memset(&message, 0, sizeof(message));
				message.msg_name = &name;
				message.msg_namelen = nameLength;
				message.msg_iov = &whole;
				message.msg_iovlen = 1;
				message.msg_control = control;
				message.msg_controllen = sizeof(control);
				struct cmsghdr* header = CMSG_FIRSTHDR(&message);
				header->cmsg_level = SOL_UDP;
				header->cmsg_type = UDP_SEGMENT;
				header->cmsg_len = CMSG_LEN(sizeof(unsigned short));
				*(unsigned short*)CMSG_DATA(header) = (unsigned short)spans[3 * i + 2];

				hx::EnterGCFreeZone();
				ssize_t result;
				do {
					result = sendmsg(nativeSocket, &message, MSG_NOSIGNAL);
				} while (result < 0 && errno == EINTR);
				int error = errno;
				hx::ExitGCFreeZone();

				if (result >= 0) {
					i += run;
					sent += run;
					continue;
				}
				if (!crossbyte_gso_refused(error)) {
					return sent;
				}
				// Not cut here: everything goes one datagram at a time from now.
				crossbyte_udp_gso = false;
			}
		}

		// Up to BATCH at once, stopping short of the next run worth cutting.
		int n = 0;
		while (i + n < count && n < BATCH) {
			int k = i + n;
			if (n > 0 && crossbyte_udp_gso) {
				int total = 0;
				if (crossbyte_gso_run(spans, targets, k, count, total) >= 2) {
					break;
				}
			}
			pieces[n].iov_base = (void*)crossbyte_batch_data(chunks, spans, k);
			pieces[n].iov_len = spans[3 * k + 2];
			SocketLen nameLength = 0;
			crossbyte_dynamic_to_sockaddr(targets[k], names[n], nameLength);
			memset(&messages[n], 0, sizeof(messages[n]));
			messages[n].msg_hdr.msg_name = &names[n];
			messages[n].msg_hdr.msg_namelen = nameLength;
			messages[n].msg_hdr.msg_iov = &pieces[n];
			messages[n].msg_hdr.msg_iovlen = 1;
			n++;
		}

		hx::EnterGCFreeZone();
		int result;
		do {
			result = sendmmsg(nativeSocket, messages, n, MSG_NOSIGNAL);
		} while (result < 0 && errno == EINTR);
		hx::ExitGCFreeZone();

		if (result <= 0) {
			return sent;
		}
		i += result;
		sent += result;
		if (result < n) {
			return sent;
		}
	}
	return sent;
#else
	for (; i < count; ++i) {
		sockaddr_storage name;
		SocketLen nameLength = 0;
		crossbyte_dynamic_to_sockaddr(targets[i], name, nameLength);
		const char* data = crossbyte_batch_data(chunks, spans, i);
		int length = spans[3 * i + 2];
		hx::EnterGCFreeZone();
		int result;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
		result = sendto(nativeSocket, data, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&name), nameLength);
#else
		do {
			result = sendto(nativeSocket, data, length, MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&name), nameLength);
			// Connected: no address, as crossbyte_socket_send_to says.
			if (result == SOCKET_ERROR && errno == EISCONN) {
				result = send(nativeSocket, data, length, MSG_NOSIGNAL);
			}
		} while (result == SOCKET_ERROR && errno == EINTR);
#endif
		hx::ExitGCFreeZone();
		if (result == SOCKET_ERROR) {
			return sent;
		}
		sent++;
	}
	return sent;
#endif
}

/*
	Datagrams received in batches, on Linux: recvmmsg takes in every datagram
	waiting, up to a batch, in one system call, where recvfrom takes one,
	and a pass over a socket ends with one recvfrom more, to find it empty.

	A batch is `capacity` slots of 65,536 bytes, past the largest datagram
	UDP carries (65,507 bytes over IPv4, 65,527 over IPv6), so none is ever
	cut short: the kernel discards what does not fit a slot, and a datagram
	longer than its slot would be lost for good. The slots are mapped rather
	than allocated, so the system commits a page of one only when a datagram
	is written into it: a slot that only ever holds datagrams of up to 4 KB
	costs 4 KB, whatever its size. Huge pages are refused for the mapping,
	where they would commit 2 MB at the first byte written.

	Elsewhere there is no batch: crossbyte_udp_batch_supported answers false
	and crossbyte_udp_batch_new null.
*/
namespace {
#if defined(__linux__)
enum { BATCH_SLOT = 65536 };

// The GC's handle on a batch's mapping, which its finalizer unmaps if
// nothing released it first.
struct RecvBatch : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdAbstract };

	int capacity;
	int count;
	size_t mapped;
	char* memory;
	struct mmsghdr* messages;
	char* slots;

	void release() {
		if (memory != 0) {
			munmap(memory, mapped);
		}
		memory = 0;
		messages = 0;
		slots = 0;
		count = 0;
		capacity = 0;
	}

	static void finalize(Dynamic object) {
		((RecvBatch*)object.mPtr)->release();
	}

	String toString() HXCPP_OVERRIDE {
		return HX_CSTRING("DatagramSocket receive batch");
	}
};

static RecvBatch* crossbyte_batch_of(Dynamic batch) {
	if (batch.mPtr == 0) {
		return 0;
	}
	RecvBatch* found = dynamic_cast<RecvBatch*>(batch.mPtr);
	return (found != 0 && found->memory != 0) ? found : 0;
}

// Datagram `index` of what the last receive took in, or a throw.
static struct mmsghdr* crossbyte_batch_message(RecvBatch* found, int index) {
	if (found == 0 || index < 0 || index >= found->count) {
		hx::Throw(HX_CSTRING("Invalid batch index"));
	}
	return &found->messages[index];
}
#endif
}

/** Whether datagrams can be received in batches here: on Linux. **/
bool crossbyte_udp_batch_supported() {
#if defined(__linux__)
	return true;
#else
	return false;
#endif
}

/**
	A batch for `capacity` datagrams, or null where there are none or the
	system would not map one. Its memory is let go by
	crossbyte_udp_batch_free, or when the batch is collected.
**/
Dynamic crossbyte_udp_batch_new(int capacity) {
#if defined(__linux__)
	if (capacity < 1 || capacity > 1024) {
		hx::Throw(HX_CSTRING("Invalid batch capacity"));
	}
	long page = sysconf(_SC_PAGESIZE);
	if (page <= 0) {
		page = 4096;
	}
	// The headers first, each array aligned as the one before it ends (64,
	// 16 and 128 bytes an entry); the slots from the next page.
	size_t headers = (size_t)capacity * (sizeof(struct mmsghdr) + sizeof(struct iovec) + sizeof(sockaddr_storage));
	headers = (headers + (size_t)page - 1) / (size_t)page * (size_t)page;
	size_t size = headers + (size_t)capacity * BATCH_SLOT;
	void* memory = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (memory == MAP_FAILED) {
		return null();
	}
	#ifdef MADV_NOHUGEPAGE
	madvise(memory, size, MADV_NOHUGEPAGE);
	#endif

	RecvBatch* batch = new RecvBatch();
	batch->capacity = capacity;
	batch->count = 0;
	batch->mapped = size;
	batch->memory = (char*)memory;
	batch->messages = (struct mmsghdr*)memory;
	struct iovec* pieces = (struct iovec*)(batch->messages + capacity);
	sockaddr_storage* names = (sockaddr_storage*)(pieces + capacity);
	batch->slots = (char*)memory + headers;
	// A fresh mapping reads as zeros: only the pointers need setting.
	for (int i = 0; i < capacity; ++i) {
		pieces[i].iov_base = batch->slots + (size_t)i * BATCH_SLOT;
		pieces[i].iov_len = BATCH_SLOT;
		batch->messages[i].msg_hdr.msg_name = &names[i];
		batch->messages[i].msg_hdr.msg_iov = &pieces[i];
		batch->messages[i].msg_hdr.msg_iovlen = 1;
	}
	_hx_set_finalizer(batch, RecvBatch::finalize);
	return batch;
#else
	return null();
#endif
}

/** How many datagrams `batch` takes in at most; 0 once it is freed. **/
int crossbyte_udp_batch_capacity(Dynamic batch) {
#if defined(__linux__)
	RecvBatch* found = crossbyte_batch_of(batch);
	return found == 0 ? 0 : found->capacity;
#else
	return 0;
#endif
}

/**
	Takes in up to `max` waiting datagrams (no more than the batch holds)
	in one recvmmsg: how many, or -1 when none is waiting, or -2 where the
	kernel has no recvmmsg. What the last call took in is gone. Any other
	failure throws, as crossbyte_socket_try_recv_from does; one that comes
	after a datagram was taken in is the next call's to report.
**/
int crossbyte_udp_batch_receive(Dynamic socket, Dynamic batch, int max) {
#if defined(__linux__)
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	RecvBatch* found = crossbyte_batch_of(batch);
	if (found == 0) {
		hx::Throw(HX_CSTRING("Invalid batch"));
	}
	found->count = 0;
	if (max > found->capacity) {
		max = found->capacity;
	}
	if (max < 1) {
		return -1;
	}
	for (int i = 0; i < max; ++i) {
		found->messages[i].msg_hdr.msg_namelen = sizeof(sockaddr_storage);
		found->messages[i].msg_hdr.msg_flags = 0;
		found->messages[i].msg_len = 0;
	}

	struct mmsghdr* messages = found->messages;
	hx::EnterGCFreeZone();
	int received;
	do {
		received = recvmmsg(nativeSocket, messages, (unsigned int)max, MSG_DONTWAIT, 0);
	} while (received < 0 && errno == EINTR);
	if (received < 0) {
		bool wouldBlock = crossbyte_would_block();
		bool missing = errno == ENOSYS;
		bool unreachable = crossbyte_unreachable_report();
		hx::ExitGCFreeZone();
		if (wouldBlock) {
			return -1;
		}
		if (missing) {
			return -2;
		}
		if (unreachable) {
			return -3;
		}
		hx::Throw(HX_CSTRING("Socket operation failed"));
	}
	hx::ExitGCFreeZone();
	found->count = received;
	return received;
#else
	hx::Throw(HX_CSTRING("No batched receive on this system"));
	return -1;
#endif
}

/**
	Datagram `index` of the last receive: its length, with where it came
	from written into `address` (a sys.net.Address) as
	crossbyte_socket_try_recv_from writes it.
**/
int crossbyte_udp_batch_take(Dynamic batch, int index, Dynamic address) {
#if defined(__linux__)
	struct mmsghdr* message = crossbyte_batch_message(crossbyte_batch_of(batch), index);
	crossbyte_sockaddr_to_dynamic(reinterpret_cast<sockaddr*>(message->msg_hdr.msg_name), message->msg_hdr.msg_namelen, address);
	return (int)message->msg_len;
#else
	hx::Throw(HX_CSTRING("No batched receive on this system"));
	return 0;
#endif
}

/** Copies datagram `index` of the last receive into `buffer` at `position`. **/
void crossbyte_udp_batch_copy(Dynamic batch, int index, Array<unsigned char> buffer, int position) {
#if defined(__linux__)
	RecvBatch* found = crossbyte_batch_of(batch);
	struct mmsghdr* message = crossbyte_batch_message(found, index);
	int length = (int)message->msg_len;
	int bufferLength = buffer->length;
	if (position < 0 || position > bufferLength || length > bufferLength - position) {
		hx::Throw(HX_CSTRING("Invalid data position"));
	}
	if (length > 0) {
		memcpy((char*)&buffer[0] + position, found->slots + (size_t)index * BATCH_SLOT, (size_t)length);
	}
#else
	hx::Throw(HX_CSTRING("No batched receive on this system"));
#endif
}

/** Unmaps a batch's memory now, rather than when it is collected. **/
void crossbyte_udp_batch_free(Dynamic batch) {
#if defined(__linux__)
	RecvBatch* found = crossbyte_batch_of(batch);
	if (found != 0) {
		found->release();
	}
#endif
}

/**
	select, for a socket of any number. On Linux and macOS select takes no
	descriptor at or past FD_SETSIZE (1,024), and hxcpp refuses one rather
	than overflow the set, so a process holding a thousand descriptors could
	ask about none of its newer sockets: a client's connect would never
	finish, and a listener opened then would accept nothing. poll has no such
	ceiling. Windows keeps hxcpp's select, whose set is a
	counted array where a socket's number is no limit, and so does a call
	with no sockets, which is a wait that select times more finely.

	The arguments and the answer are hxcpp's: three arrays of sockets and a
	timeout in seconds, or null for none; then the sockets of each that are
	ready, in the order given. Readable and writable mean what select means
	(data, the end, or an error), and the third is out-of-band data, as
	select's exception set is on POSIX. A wait is in whole milliseconds,
	rounded up.
**/
Array<Dynamic> crossbyte_socket_select(Array<Dynamic> rs, Array<Dynamic> ws, Array<Dynamic> es, Dynamic timeout) {
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
	return _hx_std_socket_select(rs, ws, es, timeout);
#else
	Array<Dynamic> sets[3] = {rs, ws, es};
	int counts[3];
	int total = 0;
	for (int set = 0; set < 3; set++) {
		counts[set] = sets[set].mPtr ? sets[set]->length : 0;
		total += counts[set];
	}
	if (total == 0) {
		return _hx_std_socket_select(rs, ws, es, timeout);
	}

	const short events[3] = {POLLIN, POLLOUT, POLLPRI};
	std::vector<struct pollfd> fds(total);
	int at = 0;
	for (int set = 0; set < 3; set++) {
		for (int i = 0; i < counts[set]; i++) {
			SOCKET nativeSocket = crossbyte_val_sock(sets[set][i]);
			if (nativeSocket == INVALID_SOCKET) {
				hx::Throw(HX_CSTRING("Closed socket in select"));
			}
			fds[at].fd = nativeSocket;
			fds[at].events = events[set];
			fds[at].revents = 0;
			at++;
		}
	}

	int wait = -1;
	if (timeout.mPtr) {
		double seconds = timeout;
		double milliseconds = ceil(seconds * 1000.0);
		wait = seconds <= 0 ? 0 : (milliseconds >= (double)INT_MAX ? INT_MAX : (int)milliseconds);
	}

	hx::EnterGCFreeZone();
	int ready;
	do {
		ready = poll(&fds[0], (nfds_t)total, wait);
	} while (ready < 0 && errno == EINTR);
	int error = errno;
	hx::ExitGCFreeZone();
	if (ready < 0) {
		hx::Throw(HX_CSTRING("Select error ") + String(error));
	}

	Array<Dynamic> result = Array_obj<Dynamic>::__new(3, 3);
	at = 0;
	for (int set = 0; set < 3; set++) {
		Array<Dynamic> chosen = Array_obj<Dynamic>::__new(0, 0);
		for (int i = 0; i < counts[set]; i++, at++) {
			short got = fds[at].revents;
			if (got & POLLNVAL) {
				// What select says of a descriptor that is not open.
				hx::Throw(HX_CSTRING("Select error ") + String(EBADF));
			}
			bool isReady = set == 0 ? (got & (POLLIN | POLLHUP | POLLERR)) != 0
				: set == 1 ? (got & (POLLOUT | POLLHUP | POLLERR)) != 0
				: (got & POLLPRI) != 0;
			if (isReady) {
				chosen->push(sets[set][i]);
			}
		}
		result[set] = chosen;
	}
	return result;
#endif
}
