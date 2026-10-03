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
	// libuv and Go do. Thrown, it read as the server's own failure, "could
	// not accept a connection", whenever a client connected and reset.
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
		// and every send failed there; the peer it is connected to is the
		// only one it may send to, so it goes without one.
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

/**
	Why a non-blocking connect failed, or null when it did not: SO_ERROR, in
	the system's words. A connect that has finished, either way, makes the
	socket writable, and on POSIX a refused or unreachable one is writable
	too, only SO_ERROR tells them apart. Windows reports the failure in
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
// to one peer, lying end to end, each as long as the first but the last,
// which may be shorter. At most 64 of them and 65,000 bytes, which every
// kernel that cuts at all accepts.
static int crossbyte_gso_run(Array<int> spans, Array<Dynamic> targets, int first, int count, int& total) {
	int segment = spans[2 * first + 1];
	total = segment;
	if (segment <= 0) {
		return 1;
	}
	int run = 1;
	while (first + run < count && run < 64) {
		int k = first + run;
		int length = spans[2 * k + 1];
		if (targets[k].mPtr != targets[first].mPtr || spans[2 * k] != spans[2 * first] + total
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

/**
	Sends datagrams `first` to `count` of a batch: datagram i is
	`spans[2i + 1]` bytes of `buffer` from `spans[2i]`, to `targets[i]`, a
	sys.net.Address. Answers how many went, from `first`, before one did not;
	that one is for the caller to send alone, which raises what stopped it.

	On Linux a run to one peer, end to end, each the same length but the
	last, goes as one send the kernel cuts up (UDP_SEGMENT): over loopback,
	a seventh of the CPU a datagram that sending them one at a time costs.
	The rest go 64 to a call with sendmmsg. Elsewhere each is a sendto.
**/
int crossbyte_socket_send_batch(Dynamic socket, Array<unsigned char> buffer, Array<int> spans, Array<Dynamic> targets, int first, int count) {
	SOCKET nativeSocket = crossbyte_val_sock(socket);
	int bufferLength = buffer->length;
	if (first < 0 || count < first || count > targets->length || count > spans->length / 2) {
		hx::Throw(HX_CSTRING("Invalid batch"));
	}
	for (int i = first; i < count; ++i) {
		int position = spans[2 * i];
		int length = spans[2 * i + 1];
		if (position < 0 || length < 0 || position > bufferLength || length > bufferLength - position) {
			hx::Throw(HX_CSTRING("Invalid data position"));
		}
	}

	const char* data = bufferLength > 0 ? (const char*)&buffer[0] : "";
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
				whole.iov_base = (void*)(data + spans[2 * i]);
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
				*(unsigned short*)CMSG_DATA(header) = (unsigned short)spans[2 * i + 1];

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
			pieces[n].iov_base = (void*)(data + spans[2 * k]);
			pieces[n].iov_len = spans[2 * k + 1];
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
		hx::EnterGCFreeZone();
		int result;
#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
		result = sendto(nativeSocket, data + spans[2 * i], spans[2 * i + 1], MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&name), nameLength);
#else
		do {
			result = sendto(nativeSocket, data + spans[2 * i], spans[2 * i + 1], MSG_NOSIGNAL, reinterpret_cast<sockaddr*>(&name), nameLength);
			// Connected: no address, as crossbyte_socket_send_to says.
			if (result == SOCKET_ERROR && errno == EISCONN) {
				result = send(nativeSocket, data + spans[2 * i], spans[2 * i + 1], MSG_NOSIGNAL);
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

/**
	select, for a socket of any number. On Linux and macOS select takes no
	descriptor at or past FD_SETSIZE, 1,024, and hxcpp refuses one
	rather than overflow the set: a process holding a thousand descriptors
	could ask about none of its newer sockets, so a client's connect never
	finished and a listener opened then accepted nothing. poll has no such
	ceiling. Windows keeps hxcpp's select, whose set is a
	counted array where a socket's number is no limit, and so does a call
	with no sockets, which is a wait that select times more finely.

	The arguments and the answer are hxcpp's: three arrays of sockets and a
	timeout in seconds, or null for none; then the sockets of each that are
	ready, in the order given. Readable and writable mean what select means,
	data, the end, or an error, and the third is out-of-band data, as
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
