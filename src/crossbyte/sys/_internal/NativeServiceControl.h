#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Attach states reported by crossbyte_service_attach_state().
#define CROSSBYTE_SERVICE_PENDING 0
#define CROSSBYTE_SERVICE_ATTACHED 1
#define CROSSBYTE_SERVICE_NOT_A_SERVICE 2
#define CROSSBYTE_SERVICE_UNAVAILABLE 3

// Starts the Service Control Manager handshake on a dedicated native thread and
// returns immediately, because StartServiceCtrlDispatcher does not return until
// the service stops. Poll crossbyte_service_attach_state() for the outcome
// rather than blocking a Haxe thread in native code.
//
// Idempotent: a second call while a handshake is in flight or settled is
// ignored. Returns false when the handshake could not be started at all.
bool crossbyte_service_attach(const char *serviceName);

// CROSSBYTE_SERVICE_PENDING until the dispatcher has either been handed a
// ServiceMain by the SCM or failed to connect to one.
int crossbyte_service_attach_state();

// Tells the SCM the stop is still in progress and to wait another waitHintMs
// before assuming the process has hung. Safe no-op when not attached.
void crossbyte_service_report_stop_pending(int waitHintMs);

// Reports SERVICE_STOPPED and releases the dispatcher thread. The SCM may kill
// the process as soon as it sees this, so it belongs after teardown, not
// before. Safe no-op when not attached.
void crossbyte_service_report_stopped(int exitCode);

// Test hook: drives the real control handler with SERVICE_CONTROL_STOP so the
// wiring can be exercised without an installed service.
void crossbyte_service_simulate_stop();

#ifdef __cplusplus
}
#endif
