#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Arms the platform shutdown-signal source: SetConsoleCtrlHandler on Windows,
// sigaction(SIGINT/SIGTERM) elsewhere. Idempotent; returns true when armed.
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

// Tests only: how many console control handlers are holding a close.
int crossbyte_lifecycle_console_handlers_holding();
#endif

#ifdef __cplusplus
}
#endif
