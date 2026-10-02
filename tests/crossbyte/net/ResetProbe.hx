package crossbyte.net;

/**
	A client that connects over TCP and resets at once -- a close with a
	linger of zero -- for the tests of what a listener does with a
	connection gone before it is taken. Nothing else in the suite can reset
	a connection that has sent and been sent nothing.

	A file of its own because the C below has preprocessor lines, and the
	suite's coverage check, which reads a test class's conditionals off the
	start of each line, would take them for Haxe's.
**/
#if cpp
@:cppFileCode("
#include <string.h>
#ifdef HX_WINDOWS
#include <winsock2.h>
typedef SOCKET crossbyte_probe_socket;
#define CROSSBYTE_PROBE_INVALID INVALID_SOCKET
#define crossbyte_probe_close closesocket
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
typedef int crossbyte_probe_socket;
#define CROSSBYTE_PROBE_INVALID (-1)
#define crossbyte_probe_close close
#endif

static int crossbyte_probe_connect_and_reset(int port) {
	crossbyte_probe_socket s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == CROSSBYTE_PROBE_INVALID) {
		return -1;
	}
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((unsigned short)port);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		crossbyte_probe_close(s);
		return -2;
	}
	struct linger lin;
	lin.l_onoff = 1;
	lin.l_linger = 0;
	if (setsockopt(s, SOL_SOCKET, SO_LINGER, (const char *)&lin, sizeof(lin)) != 0) {
		crossbyte_probe_close(s);
		return -3;
	}
	crossbyte_probe_close(s);
	return 0;
}
")
#end
class ResetProbe {
	/**
		Connects to `port` on 127.0.0.1 and resets the connection. Answers 0
		once it has, a negative number if it could not, and -100 on every
		target but cpp, which has no way to make a socket reset.
	**/
	public static function connectAndReset(port:Int):Int {
		#if cpp
		return untyped __cpp__("crossbyte_probe_connect_and_reset({0})", port);
		#else
		return -100;
		#end
	}
}
