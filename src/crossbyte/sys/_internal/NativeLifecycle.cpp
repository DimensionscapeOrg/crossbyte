// CrossByte process-lifecycle native bridge.
//
// The signal/console handlers below run on OS-controlled threads (Windows) or
// in async-signal context (POSIX). They must only touch the atomic flag —
// never the Haxe runtime. The Haxe side observes the flag from its own thread
// via ProcessLifecycle.poll().

#include "NativeLifecycle.h"

#include <atomic>

namespace {
	std::atomic<int> g_shutdown_requested{0};
	std::atomic<int> g_handlers_installed{0};
}

#if defined(_WIN32)

#include <Windows.h>

namespace {
	BOOL WINAPI crossbyte_console_ctrl_handler(DWORD controlType) {
		switch (controlType) {
			case CTRL_C_EVENT:
			case CTRL_BREAK_EVENT:
			case CTRL_CLOSE_EVENT:
			case CTRL_LOGOFF_EVENT:
			case CTRL_SHUTDOWN_EVENT:
				g_shutdown_requested.store(1, std::memory_order_release);
				// Claim the event so the default handler does not terminate the
				// process immediately; the OS still enforces its grace window.
				return TRUE;
			default:
				return FALSE;
		}
	}
}

extern "C" bool crossbyte_lifecycle_install() {
	int expected = 0;
	if (!g_handlers_installed.compare_exchange_strong(expected, 1)) {
		return true;
	}

	if (SetConsoleCtrlHandler(crossbyte_console_ctrl_handler, TRUE)) {
		return true;
	}

	g_handlers_installed.store(0, std::memory_order_release);
	return false;
}

#else

#include <signal.h>

namespace {
	void crossbyte_signal_handler(int) {
		g_shutdown_requested.store(1, std::memory_order_release);
	}
}

extern "C" bool crossbyte_lifecycle_install() {
	int expected = 0;
	if (!g_handlers_installed.compare_exchange_strong(expected, 1)) {
		return true;
	}

	struct sigaction action;
	sigemptyset(&action.sa_mask);
	action.sa_handler = crossbyte_signal_handler;
	// SA_RESTART keeps interrupted syscalls transparent to the poll loop.
	action.sa_flags = SA_RESTART;

	bool ok = (sigaction(SIGINT, &action, nullptr) == 0);
	ok = (sigaction(SIGTERM, &action, nullptr) == 0) && ok;

	if (ok) {
		return true;
	}

	g_handlers_installed.store(0, std::memory_order_release);
	return false;
}

#endif

extern "C" void crossbyte_lifecycle_request_shutdown() {
	g_shutdown_requested.store(1, std::memory_order_release);
}

extern "C" bool crossbyte_lifecycle_is_shutdown_requested() {
	return g_shutdown_requested.load(std::memory_order_acquire) != 0;
}

extern "C" void crossbyte_lifecycle_reset() {
	g_shutdown_requested.store(0, std::memory_order_release);
}
