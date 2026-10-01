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
	// The longest the handler holds a closing console, a logoff or a
	// shutdown for the runtime to shut down in. Windows' own limit is the
	// shorter one for a closed console -- about five seconds -- and it ends
	// the process then whatever this is.
	std::atomic<int> g_close_wait_ms{20000};

	// For the tests: whether a handler is inside its wait.
	std::atomic<int> g_handlers_holding{0};

	BOOL WINAPI crossbyte_console_ctrl_handler(DWORD controlType) {
		switch (controlType) {
			case CTRL_C_EVENT:
			case CTRL_BREAK_EVENT:
				g_shutdown_requested.store(1, std::memory_order_release);
				// Claimed, so the default handler does not end the process: the
				// runtime sees the request at its next tick and shuts down.
				return TRUE;
			case CTRL_CLOSE_EVENT:
			case CTRL_LOGOFF_EVENT:
			case CTRL_SHUTDOWN_EVENT: {
				g_shutdown_requested.store(1, std::memory_order_release);
				// For these Windows ends the process as soon as the handler
				// returns, whatever it returns. This returned at once, so the
				// process was gone before the runtime's next tick saw the
				// request and onShutdown never ran: only Ctrl+C and Ctrl+Break
				// shut down cleanly. Held here instead while the runtime shuts
				// down; the process exiting ends this thread with it. Sleep
				// touches nothing of the Haxe runtime, which this thread is no
				// part of.
				g_handlers_holding.fetch_add(1, std::memory_order_acq_rel);
				int limit = g_close_wait_ms.load(std::memory_order_acquire);
				for (int waited = 0; waited < limit; waited += 10) {
					Sleep(10);
				}
				g_handlers_holding.fetch_sub(1, std::memory_order_acq_rel);
				return TRUE;
			}
			default:
				return FALSE;
		}
	}

	DWORD WINAPI crossbyte_console_event_thread(LPVOID parameter) {
		crossbyte_console_ctrl_handler(static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(parameter)));
		return 0;
	}
}

extern "C" bool crossbyte_lifecycle_deliver_console_event(int controlType, int closeWaitMs) {
	g_close_wait_ms.store(closeWaitMs, std::memory_order_release);
	// On a thread of its own, as Windows delivers one.
	HANDLE thread = CreateThread(nullptr, 0, crossbyte_console_event_thread,
		reinterpret_cast<LPVOID>(static_cast<ULONG_PTR>(controlType)), 0, nullptr);
	if (thread == nullptr) {
		return false;
	}
	CloseHandle(thread);
	return true;
}

extern "C" int crossbyte_lifecycle_console_handlers_holding() {
	return g_handlers_holding.load(std::memory_order_acquire);
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
#if defined(_WIN32)
	g_close_wait_ms.store(20000, std::memory_order_release);
#endif
}
