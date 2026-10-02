// CrossByte process-lifecycle native bridge.
//
// The signal/console handlers below run on OS-controlled threads (Windows) or
// in async-signal context (POSIX). They must only touch the atomic flag,
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
	// shorter one for a closed console, about five seconds, and it ends
	// the process then whatever this is.
	std::atomic<int> g_close_wait_ms{20000};

	// For the tests: whether a handler is inside its wait.
	std::atomic<int> g_handlers_holding{0};

	// For the tests: answers inServiceSession() in its place, 1 or 0, when
	// not -1.
	std::atomic<int> g_service_session_for_test{-1};

	// Latches the request, then holds the thread Windows is waiting on while
	// the runtime shuts down; the process exiting ends this thread with it.
	// Sleep touches nothing of the Haxe runtime, which this thread is no
	// part of.
	void holdWhileShuttingDown() {
		g_shutdown_requested.store(1, std::memory_order_release);
		g_handlers_holding.fetch_add(1, std::memory_order_acq_rel);
		int limit = g_close_wait_ms.load(std::memory_order_acquire);
		for (int waited = 0; waited < limit; waited += 10) {
			Sleep(10);
		}
		g_handlers_holding.fetch_sub(1, std::memory_order_acq_rel);
	}

	// Whether this process runs in session 0: services, and what they start,
	// where no one logs on.
	bool inServiceSession() {
		int forced = g_service_session_for_test.load(std::memory_order_acquire);
		if (forced >= 0) {
			return forced == 1;
		}
		DWORD session = 0;
		return ProcessIdToSessionId(GetCurrentProcessId(), &session) && session == 0;
	}

	BOOL WINAPI crossbyte_console_ctrl_handler(DWORD controlType) {
		switch (controlType) {
			case CTRL_C_EVENT:
			case CTRL_BREAK_EVENT:
				g_shutdown_requested.store(1, std::memory_order_release);
				// Claimed, so the default handler does not end the process: the
				// runtime sees the request at its next tick and shuts down.
				return TRUE;
			case CTRL_LOGOFF_EVENT:
				// Windows sends this to services when anyone logs off, someone
				// else, since no one logs on to session 0, and does not end
				// them. A service, or a process one started, shut down here,
				// so it stopped serving whenever a user signed out. Claimed and
				// let be.
				if (inServiceSession()) {
					return TRUE;
				}
				holdWhileShuttingDown();
				return TRUE;
			case CTRL_CLOSE_EVENT:
			case CTRL_SHUTDOWN_EVENT:
				// For these Windows ends the process as soon as the handler
				// returns, whatever it returns. This returned at once, so the
				// process was gone before the runtime's next tick saw the
				// request and onShutdown never ran: only Ctrl+C and Ctrl+Break
				// shut down cleanly. Held here instead while the runtime shuts
				// down.
				holdWhileShuttingDown();
				return TRUE;
			default:
				return FALSE;
		}
	}

	DWORD WINAPI crossbyte_console_event_thread(LPVOID parameter) {
		crossbyte_console_ctrl_handler(static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(parameter)));
		return 0;
	}

	// A process that loads user32.dll, a window, a GUI toolkit, a Shell
	// function that calls into it, is a Windows application to Windows, and
	// its console handler is not called for CTRL_LOGOFF_EVENT or
	// CTRL_SHUTDOWN_EVENT: it is told of a logoff or a shutdown through
	// WM_QUERYENDSESSION and WM_ENDSESSION, sent to its top-level windows.
	// Such a process got neither, and the session ended it without a
	// shutdown. One gets a hidden window of its own, as Windows documents, on
	// a thread of its own.
	//
	// user32 is reached through the module already loaded, never linked:
	// CrossByte loads none of it, and linking it would make every process a
	// Windows application and take the console's events from it.
	struct User32 {
		decltype(&RegisterClassExW) registerClassEx;
		decltype(&CreateWindowExW) createWindowEx;
		decltype(&DefWindowProcW) defWindowProc;
		decltype(&GetMessageW) getMessage;
		decltype(&DispatchMessageW) dispatchMessage;
		decltype(&SendMessageTimeoutW) sendMessageTimeout;
		decltype(&PostMessageW) postMessage;
	};

	User32 g_user32 = {};
	std::atomic<int> g_session_window_started{0};
	std::atomic<HWND> g_session_window{nullptr};

	bool loadUser32(HMODULE module) {
		g_user32.registerClassEx = reinterpret_cast<decltype(&RegisterClassExW)>(GetProcAddress(module, "RegisterClassExW"));
		g_user32.createWindowEx = reinterpret_cast<decltype(&CreateWindowExW)>(GetProcAddress(module, "CreateWindowExW"));
		g_user32.defWindowProc = reinterpret_cast<decltype(&DefWindowProcW)>(GetProcAddress(module, "DefWindowProcW"));
		g_user32.getMessage = reinterpret_cast<decltype(&GetMessageW)>(GetProcAddress(module, "GetMessageW"));
		g_user32.dispatchMessage = reinterpret_cast<decltype(&DispatchMessageW)>(GetProcAddress(module, "DispatchMessageW"));
		g_user32.sendMessageTimeout = reinterpret_cast<decltype(&SendMessageTimeoutW)>(GetProcAddress(module, "SendMessageTimeoutW"));
		g_user32.postMessage = reinterpret_cast<decltype(&PostMessageW)>(GetProcAddress(module, "PostMessageW"));
		return g_user32.registerClassEx != nullptr && g_user32.createWindowEx != nullptr && g_user32.defWindowProc != nullptr
			&& g_user32.getMessage != nullptr && g_user32.dispatchMessage != nullptr && g_user32.sendMessageTimeout != nullptr
			&& g_user32.postMessage != nullptr;
	}

	LRESULT CALLBACK crossbyte_session_window_proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
		switch (message) {
			case WM_QUERYENDSESSION:
				// The session may end; the shutdown runs once it does.
				return TRUE;
			case WM_ENDSESSION:
				// Ending: the process can be ended once this returns, as for a
				// closing console. Not when another application refused and the
				// session goes on.
				if (wParam) {
					holdWhileShuttingDown();
				}
				return 0;
			default:
				return g_user32.defWindowProc(window, message, wParam, lParam);
		}
	}

	DWORD WINAPI crossbyte_session_window_thread(LPVOID) {
		HINSTANCE instance = GetModuleHandleW(nullptr);
		WNDCLASSEXW windowClass = {};
		windowClass.cbSize = sizeof(windowClass);
		windowClass.lpfnWndProc = crossbyte_session_window_proc;
		windowClass.hInstance = instance;
		windowClass.lpszClassName = L"CrossByteSessionWindow";
		g_user32.registerClassEx(&windowClass);

		// Top-level, hidden: a message-only window is sent no broadcast, and
		// these are broadcasts.
		HWND window = g_user32.createWindowEx(0, L"CrossByteSessionWindow", L"CrossByte", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
		if (window == nullptr) {
			return 0;
		}
		g_session_window.store(window, std::memory_order_release);

		MSG message;
		while (g_user32.getMessage(&message, nullptr, 0, 0) > 0) {
			g_user32.dispatchMessage(&message);
		}
		return 0;
	}

	// The window, made once user32 is loaded: at install, or at a later
	// install once something has loaded it.
	void startSessionWindowIfUser32() {
		if (g_session_window_started.load(std::memory_order_acquire) != 0) {
			return;
		}
		HMODULE module = GetModuleHandleW(L"user32.dll");
		if (module == nullptr) {
			return;
		}
		int expected = 0;
		if (!g_session_window_started.compare_exchange_strong(expected, 1)) {
			return;
		}
		if (!loadUser32(module)) {
			return;
		}
		HANDLE thread = CreateThread(nullptr, 0, crossbyte_session_window_thread, nullptr, 0, nullptr);
		if (thread != nullptr) {
			CloseHandle(thread);
		}
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

extern "C" int crossbyte_lifecycle_holding() {
	return g_handlers_holding.load(std::memory_order_acquire);
}

extern "C" void crossbyte_lifecycle_force_service_session_for_test(int inServiceSession) {
	g_service_session_for_test.store(inServiceSession < 0 ? -1 : (inServiceSession != 0 ? 1 : 0), std::memory_order_release);
}

extern "C" bool crossbyte_lifecycle_load_user32_for_test() {
	return LoadLibraryW(L"user32.dll") != nullptr;
}

extern "C" bool crossbyte_lifecycle_session_window_ready() {
	return g_session_window.load(std::memory_order_acquire) != nullptr;
}

extern "C" int crossbyte_lifecycle_deliver_session_end(int closeWaitMs) {
	HWND window = g_session_window.load(std::memory_order_acquire);
	if (window == nullptr) {
		return -1;
	}
	g_close_wait_ms.store(closeWaitMs, std::memory_order_release);

	// As Windows sends them: the question, then the answer. The answer is
	// posted rather than sent, so the caller is not held with the window.
	DWORD_PTR agreed = 0;
	if (g_user32.sendMessageTimeout(window, WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF, SMTO_ABORTIFHUNG, 5000, &agreed) == 0) {
		return -1;
	}
	if (agreed == 0) {
		return 0;
	}
	return g_user32.postMessage(window, WM_ENDSESSION, TRUE, ENDSESSION_LOGOFF) ? 1 : -1;
}

extern "C" bool crossbyte_lifecycle_install() {
	int expected = 0;
	if (g_handlers_installed.compare_exchange_strong(expected, 1)) {
		if (!SetConsoleCtrlHandler(crossbyte_console_ctrl_handler, TRUE)) {
			g_handlers_installed.store(0, std::memory_order_release);
			return false;
		}
	}

	// On every call, for a process that loaded user32 after the first.
	startSessionWindowIfUser32();
	return true;
}

#else

#include <signal.h>

namespace {
	void crossbyte_signal_handler(int) {
		g_shutdown_requested.store(1, std::memory_order_release);
	}

	// What each signal did before install, for the tests to put back.
	struct sigaction g_previous_int;
	struct sigaction g_previous_term;
	struct sigaction g_previous_hup;
	bool g_hup_installed = false;

	// Whether `signal` takes its default action, not ignored, and not
	// handled by anything else. By the handler alone: sa_handler and
	// sa_sigaction share their storage, and SIG_DFL is the one value
	// neither kind of handler can have. SA_SIGINFO is no guide, as macOS
	// keeps it set across exec for a signal the parent handled with it
	// while putting the handler itself back to SIG_DFL; read as "handled",
	// SIGHUP went without a handler and still ended the process.
	bool takesDefaultAction(int signal) {
		struct sigaction current;
		if (sigaction(signal, nullptr, &current) != 0) {
			return false;
		}
		return current.sa_handler == SIG_DFL;
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

	bool ok = (sigaction(SIGINT, &action, &g_previous_int) == 0);
	ok = (sigaction(SIGTERM, &action, &g_previous_term) == 0) && ok;

	// SIGHUP: the terminal a server was started from going away, or a
	// session ending. Its default ended the process at once, with no
	// onShutdown and no drain; it shuts down as SIGTERM does now. Left
	// alone when it was ignored, nohup, which asks for the process to
	// outlive its terminal, or when something else handles it, a reload
	// say.
	g_hup_installed = takesDefaultAction(SIGHUP) && sigaction(SIGHUP, &action, &g_previous_hup) == 0;

	if (ok) {
		return true;
	}

	g_handlers_installed.store(0, std::memory_order_release);
	return false;
}

extern "C" bool crossbyte_lifecycle_raise_for_test(int signal) {
	return raise(signal) == 0;
}

extern "C" bool crossbyte_lifecycle_default_with_siginfo_for_test(int signal) {
	struct sigaction action;
	sigemptyset(&action.sa_mask);
	action.sa_handler = SIG_DFL;
	action.sa_flags = SA_SIGINFO;
	return sigaction(signal, &action, nullptr) == 0;
}

extern "C" bool crossbyte_lifecycle_handles_for_test(int signal) {
	struct sigaction current;
	if (sigaction(signal, nullptr, &current) != 0) {
		return false;
	}
	return current.sa_handler == crossbyte_signal_handler;
}

extern "C" bool crossbyte_lifecycle_ignore_for_test(int signal, bool ignored) {
	struct sigaction action;
	sigemptyset(&action.sa_mask);
	action.sa_handler = ignored ? SIG_IGN : SIG_DFL;
	action.sa_flags = 0;
	return sigaction(signal, &action, nullptr) == 0;
}

extern "C" void crossbyte_lifecycle_uninstall_for_test() {
	int expected = 1;
	if (!g_handlers_installed.compare_exchange_strong(expected, 0)) {
		return;
	}
	sigaction(SIGINT, &g_previous_int, nullptr);
	sigaction(SIGTERM, &g_previous_term, nullptr);
	if (g_hup_installed) {
		sigaction(SIGHUP, &g_previous_hup, nullptr);
		g_hup_installed = false;
	}
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
	g_service_session_for_test.store(-1, std::memory_order_release);
#endif
}
