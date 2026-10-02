#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Arms the platform shutdown-signal source: SetConsoleCtrlHandler on Windows,
// with a hidden window for logoff and shutdown once user32 is loaded;
// sigaction(SIGINT/SIGTERM, and SIGHUP while it takes its default action)
// elsewhere. Idempotent; returns true when armed.
bool crossbyte_lifecycle_install();

// Marks shutdown as requested. Shares the flag with the signal handlers so
// the programmatic and signal paths are indistinguishable to observers.
void crossbyte_lifecycle_request_shutdown();

// Returns whether shutdown has been requested by any source.
bool crossbyte_lifecycle_is_shutdown_requested();

// Clears the requested flag. Intended for tests only.
void crossbyte_lifecycle_reset();

#if defined(_WIN32)
// Tests only: runs the console control handler for `controlType` on a thread
// of its own, as Windows delivers one, holding a close for at most
// `closeWaitMs`.
bool crossbyte_lifecycle_deliver_console_event(int controlType, int closeWaitMs);

// Tests only: how many handlers -- console handlers and the session window --
// are holding a close, a logoff or a shutdown.
int crossbyte_lifecycle_holding();

// Tests only: 1 or 0 answers in place of whether this process runs in
// session 0, as a service does; -1 asks Windows again.
void crossbyte_lifecycle_force_service_session_for_test(int inServiceSession);

// Tests only: loads user32.dll, as a GUI toolkit or a Shell function would.
bool crossbyte_lifecycle_load_user32_for_test();

// Tests only: whether the hidden session window has been made.
bool crossbyte_lifecycle_session_window_ready();

// Tests only: sends the session window WM_QUERYENDSESSION, then posts
// WM_ENDSESSION for a logoff, holding it for at most `closeWaitMs`. 1 when
// both went, 0 when the window refused the first, -1 when there is no window.
int crossbyte_lifecycle_deliver_session_end(int closeWaitMs);
#else
// Tests only: raises `signal` in this process.
bool crossbyte_lifecycle_raise_for_test(int signal);

// Tests only: `signal` to its default action with SA_SIGINFO still set, as
// macOS leaves a signal the parent handled with it after exec.
bool crossbyte_lifecycle_default_with_siginfo_for_test(int signal);

// Tests only: whether `signal` is handled by install()'s handler now.
bool crossbyte_lifecycle_handles_for_test(int signal);

// Tests only: sets `signal` to be ignored, or to its default action.
bool crossbyte_lifecycle_ignore_for_test(int signal, bool ignored);

// Tests only: puts back what SIGINT, SIGTERM and SIGHUP did before install,
// so the next install starts again.
void crossbyte_lifecycle_uninstall_for_test();
#endif

#ifdef __cplusplus
}
#endif
