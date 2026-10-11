package crossbyte.core._internal;

#if cpp
/**
	SIGPIPE, raised by a write to a pipe or a socket with nobody left to read
	it, whose default action ends the process. A runtime has it ignored, as
	Node, the jvm and Python do, so such a write fails as any other does.

	Sockets never raised it natively (they send with `MSG_NOSIGNAL`, or are
	made with `SO_NOSIGPIPE`), and hxcpp ignores it once a child process has
	been made, so stdout was what was left: a server whose output went to a
	log shipper that died, or a tool piped into `head`, ended with exit code
	141 and no word of why.

	Only from its default: a handler the application set, or an ignore the
	process was started with, stays as it is. Windows has no SIGPIPE.
**/
@:cppFileCode('
#ifndef HX_WINDOWS
#include <signal.h>
#include <string.h>
#endif

static void crossbyte_ignore_default_sigpipe() {
#ifndef HX_WINDOWS
	struct sigaction current;
	if (sigaction(SIGPIPE, NULL, &current) != 0 || current.sa_handler != SIG_DFL) {
		return;
	}
	struct sigaction ignore;
	memset(&ignore, 0, sizeof(ignore));
	sigemptyset(&ignore.sa_mask);
	ignore.sa_handler = SIG_IGN;
	sigaction(SIGPIPE, &ignore, NULL);
#endif
}
')
class Sigpipe {
	/**
		Has SIGPIPE ignored if it is at its default. Asked as each runtime is
		made, rather than once, since what the application sets in between
		is the application's.
	**/
	public static function ignoreIfDefault():Void {
		untyped __cpp__("crossbyte_ignore_default_sigpipe()");
	}
}
#end
