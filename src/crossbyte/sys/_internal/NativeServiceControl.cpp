// CrossByte Windows Service Control Manager bridge.
//
// A process started by the SCM has no console, so it never receives the CTRL_*
// events NativeLifecycle installs a handler for: a service stopped with
// `sc stop` would run no shutdown callback and be killed on the SCM's timeout,
// with in-flight connections severed. This file supplies the missing source.
//
// Everything here stays on threads Windows or this file created, and touches
// only Win32 and atomics -- never the Haxe runtime, which hxcpp's collector
// knows nothing about on an SCM-created thread. The control handler latches the
// same flag as the console handler and the programmatic path, so the Haxe side
// observes one shutdown signal and cannot tell the sources apart.

#include "NativeServiceControl.h"
#include "NativeLifecycle.h"

#include <atomic>

namespace {
	// Settles once and stays settled: whether this process was started by the
	// SCM is a property of the process, not something to be reset between runs.
	std::atomic<int> g_attach_state{CROSSBYTE_SERVICE_PENDING};
}

#if defined(_WIN32)

#include <Windows.h>
#include <string>

namespace {
	// The SCM's default patience before it treats a non-responding service as
	// hung. A drain longer than this has to extend it via report_stop_pending.
	const DWORD kStopWaitHintMs = 30000;
	const DWORD kStartWaitHintMs = 10000;

	std::atomic<int> g_attach_started{0};

	std::string g_service_name;
	// Atomic, and published only after the SERVICE_STATUS fields it guards are
	// filled in: the SCM may call the control handler the instant registration
	// returns, and a handler that reported a half-initialised status would tell
	// the SCM the service accepts no controls at all.
	std::atomic<SERVICE_STATUS_HANDLE> g_status_handle{nullptr};
	SERVICE_STATUS g_status = {};
	HANDLE g_settled_event = nullptr;
	HANDLE g_stop_event = nullptr;
	CRITICAL_SECTION g_status_lock;
	bool g_status_lock_ready = false;

	void report_status(DWORD state, DWORD waitHintMs, DWORD exitCode) {
		SERVICE_STATUS_HANDLE handle = g_status_handle.load(std::memory_order_acquire);

		if (handle == nullptr || !g_status_lock_ready) {
			return;
		}

		EnterCriticalSection(&g_status_lock);
		g_status.dwCurrentState = state;
		g_status.dwWin32ExitCode = exitCode;
		g_status.dwWaitHint = waitHintMs;
		// A checkpoint that keeps moving is what tells the SCM a slow stop is
		// still making progress rather than wedged.
		if (state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING) {
			g_status.dwCheckPoint++;
		} else {
			g_status.dwCheckPoint = 0;
		}
		SetServiceStatus(handle, &g_status);
		LeaveCriticalSection(&g_status_lock);
	}

	// Answering an interrogation means re-sending what is already held, without
	// reading it outside the lock that writes it.
	void report_current_status() {
		SERVICE_STATUS_HANDLE handle = g_status_handle.load(std::memory_order_acquire);

		if (handle == nullptr || !g_status_lock_ready) {
			return;
		}

		EnterCriticalSection(&g_status_lock);
		SetServiceStatus(handle, &g_status);
		LeaveCriticalSection(&g_status_lock);
	}

	DWORD WINAPI control_handler(DWORD control, DWORD, LPVOID, LPVOID) {
		switch (control) {
			case SERVICE_CONTROL_STOP:
			case SERVICE_CONTROL_SHUTDOWN:
				// Acknowledge first: the SCM starts its clock when it sends the
				// control, not when the application gets round to noticing.
				report_status(SERVICE_STOP_PENDING, kStopWaitHintMs, NO_ERROR);
				crossbyte_lifecycle_request_shutdown();
				return NO_ERROR;
			case SERVICE_CONTROL_INTERROGATE:
				report_current_status();
				return NO_ERROR;
			default:
				return ERROR_CALL_NOT_IMPLEMENTED;
		}
	}

	void WINAPI service_main(DWORD, LPSTR *) {
		SERVICE_STATUS_HANDLE handle = RegisterServiceCtrlHandlerExA(g_service_name.c_str(), control_handler, nullptr);

		if (handle == nullptr) {
			g_attach_state.store(CROSSBYTE_SERVICE_UNAVAILABLE, std::memory_order_release);
			SetEvent(g_settled_event);
			return;
		}

		g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
		// SHUTDOWN rather than PRESHUTDOWN: the two are documented as not to be
		// combined, and STOP is the control that matters day to day, since it is
		// what a restart or an upgrade sends.
		g_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
		g_status.dwServiceSpecificExitCode = 0;
		g_status.dwCurrentState = SERVICE_START_PENDING;

		// Published last, so the control handler cannot observe the handle
		// before the status it is about to report.
		g_status_handle.store(handle, std::memory_order_release);

		report_status(SERVICE_START_PENDING, kStartWaitHintMs, NO_ERROR);

		// Published before RUNNING, so a stop arriving immediately afterwards
		// finds the application already treating itself as a service.
		g_attach_state.store(CROSSBYTE_SERVICE_ATTACHED, std::memory_order_release);
		report_status(SERVICE_RUNNING, 0, NO_ERROR);
		SetEvent(g_settled_event);

		// Park until the application reports it has finished stopping. The
		// service counts as running for exactly as long as this waits, and no
		// Haxe code ever runs on this thread.
		WaitForSingleObject(g_stop_event, INFINITE);
	}

	DWORD WINAPI dispatcher_thread(LPVOID) {
		SERVICE_TABLE_ENTRYA table[] = {
			{const_cast<LPSTR>(g_service_name.c_str()), service_main},
			{nullptr, nullptr},
		};

		if (!StartServiceCtrlDispatcherA(table)) {
			// ERROR_FAILED_SERVICE_CONTROLLER_CONNECT is the documented answer
			// for "this process was not started by the SCM": an ordinary console
			// run, not a failure, and the common case during development.
			DWORD error = GetLastError();
			g_attach_state.store(error == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT ? CROSSBYTE_SERVICE_NOT_A_SERVICE
																				  : CROSSBYTE_SERVICE_UNAVAILABLE,
				std::memory_order_release);
			SetEvent(g_settled_event);
		}

		return 0;
	}
}

extern "C" bool crossbyte_service_attach(const char *serviceName) {
	int expected = 0;
	if (!g_attach_started.compare_exchange_strong(expected, 1)) {
		return true;
	}

	g_service_name = (serviceName == nullptr || serviceName[0] == '\0') ? "CrossByte" : serviceName;

	if (!g_status_lock_ready) {
		InitializeCriticalSection(&g_status_lock);
		g_status_lock_ready = true;
	}

	g_settled_event = CreateEventA(nullptr, TRUE, FALSE, nullptr);
	g_stop_event = CreateEventA(nullptr, TRUE, FALSE, nullptr);

	if (g_settled_event == nullptr || g_stop_event == nullptr) {
		g_attach_state.store(CROSSBYTE_SERVICE_UNAVAILABLE, std::memory_order_release);
		return false;
	}

	HANDLE thread = CreateThread(nullptr, 0, dispatcher_thread, nullptr, 0, nullptr);

	if (thread == nullptr) {
		g_attach_state.store(CROSSBYTE_SERVICE_UNAVAILABLE, std::memory_order_release);
		return false;
	}

	CloseHandle(thread);
	return true;
}

extern "C" void crossbyte_service_report_stop_pending(int waitHintMs) {
	if (g_attach_state.load(std::memory_order_acquire) != CROSSBYTE_SERVICE_ATTACHED) {
		return;
	}

	report_status(SERVICE_STOP_PENDING, waitHintMs > 0 ? (DWORD)waitHintMs : kStopWaitHintMs, NO_ERROR);
}

extern "C" void crossbyte_service_report_stopped(int exitCode) {
	if (g_attach_state.load(std::memory_order_acquire) != CROSSBYTE_SERVICE_ATTACHED) {
		return;
	}

	report_status(SERVICE_STOPPED, 0, (DWORD)exitCode);

	if (g_stop_event != nullptr) {
		SetEvent(g_stop_event);
	}
}

extern "C" void crossbyte_service_simulate_stop() {
	// Drives the real handler rather than a copy of it, so a test covers the
	// path the SCM takes. report_status is inert without a status handle.
	control_handler(SERVICE_CONTROL_STOP, 0, nullptr, nullptr);
}

#else

extern "C" bool crossbyte_service_attach(const char *) {
	// No Service Control Manager to attach to. Settled immediately so callers
	// never wait on a handshake that cannot happen.
	g_attach_state.store(CROSSBYTE_SERVICE_UNAVAILABLE, std::memory_order_release);
	return false;
}

extern "C" void crossbyte_service_report_stop_pending(int) {}

extern "C" void crossbyte_service_report_stopped(int) {}

extern "C" void crossbyte_service_simulate_stop() {
	crossbyte_lifecycle_request_shutdown();
}

#endif

extern "C" int crossbyte_service_attach_state() {
	return g_attach_state.load(std::memory_order_acquire);
}
