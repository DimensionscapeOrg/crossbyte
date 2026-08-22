# Proposal 0014 — Windows service control

**Status:** Implemented

**Motivation:** Proposal 0001 added `ProcessLifecycle` and proposal 0003
gave it something worth calling — `HTTPServer.drain()`,
`ServerSocket.stopAccepting()`, `ServerWebSocket.drain()`. None of it
runs on the deployment target.

`ProcessLifecycle.installDefaultHandlers()` arms
`SetConsoleCtrlHandler` on Windows. A process started by the Service
Control Manager has no console and is sent none of the `CTRL_*` events:
the SCM signals a service through `RegisterServiceCtrlHandlerEx` and
`SERVICE_CONTROL_STOP`. So on a Windows Server deployment — the stated
target — `sc stop`, a service restart, or an upgrade would run no
shutdown callback at all. The drain would be skipped, the SCM would wait
out its timeout, and the process would be terminated with every
in-flight request severed.

This is the failure shape worth naming: correct in the configuration
that gets tested, silently inert in the one that ships. The console
handler works perfectly in development, so nothing about a local run
reveals it.

---

## What landed

All additions; no existing signature or behavior changed.
`installDefaultHandlers()` and everything built on it behave exactly as
before.

### `ProcessLifecycle.installServiceControl(serviceName, connectTimeoutMs = 5000)`

Adds the SCM as a second signal source feeding the same latch the
console handler and `requestShutdown()` already set, so the Haxe side
observes one shutdown request and cannot tell the sources apart. Also
calls `installDefaultHandlers()`, so a server main needs one call to
cover both service and console operation.

Returns `true` only when the process really was started by the SCM. A
console run returns `false` and is fully functional — that is the
expected answer in development, not a failure. `isService` exposes the
same fact.

### Status reporting

The SCM has to be told what is happening or it assumes the service hung:

- The control handler reports `SERVICE_STOP_PENDING` the moment a stop
  arrives, before any Haxe code notices — the SCM's clock starts when it
  sends the control, not when the application gets round to reacting.
- `poll()` reports `SERVICE_STOPPED` after the shutdown callbacks have
  run and the runtime has been torn down. Last, deliberately: the SCM
  may terminate the process as soon as it sees that.
- `reportServiceStopPending(waitHintMs)` extends the default 30-second
  hint for a drain that needs longer.
- `deferServiceStop` + `reportServiceStopped()` hand the final report to
  the application. This is required for an asynchronous drain:
  `HTTPServer.drain(timeout, onComplete)` returns immediately, so
  `poll()` reporting the service stopped would tell the SCM the drain had
  finished while connections were still being served.

All four are no-ops off the SCM, so a server written for service
deployment runs unmodified from a console.

### Composed usage

```haxe
ProcessLifecycle.deferServiceStop = true;
ProcessLifecycle.onShutdown(() -> {
	ProcessLifecycle.reportServiceStopPending(60000);
	server.drain(45, () -> ProcessLifecycle.reportServiceStopped());
});
ProcessLifecycle.installServiceControl("KnownfolkBackend");
```

## Threading

`StartServiceCtrlDispatcher` does not return until the service stops,
and `ServiceMain` is invoked on a thread Windows creates. Neither is
somewhere Haxe code can run: hxcpp's collector knows nothing about an
SCM-created thread, and attaching one is exactly the class of mistake
that produces crashes nobody can reproduce.

So the dispatcher runs on its own native thread and never touches the
Haxe runtime. `ServiceMain` registers the handler, reports `RUNNING`,
and parks on an event until the application reports it has stopped. The
control handler — on yet another OS thread — only calls `SetServiceStatus`
and latches the existing atomic. Every line of Haxe still runs on the
threads hxcpp created, which is the same discipline the console and
signal handlers in `NativeLifecycle` already follow.

The attach handshake is polled from Haxe rather than waited on in
native code, for the same reason: a Haxe thread parked inside a Win32
wait is a thread the collector cannot see stop, which would block
collection for every other thread.

## Testing

Four cases in `ProcessLifecycleTest`, all of which run in CI:

- A console run settles as `NOT_A_SERVICE` rather than hanging or
  claiming to be a service — asserted on the specific state, not merely
  on `installServiceControl` returning `false`, because `false` also
  covers a handshake that failed and only one of those is correct.
- The four status-reporting calls are safe no-ops off the SCM.
- `SERVICE_CONTROL_STOP` latches the request and `poll()` then dispatches
  the callbacks in order. The test drives the real control handler rather
  than a copy of it, so it covers the path the SCM takes. This is the
  case that did not exist before: a service stop reached no callback.
- `deferServiceStop` is cleared by the test reset, since left set it
  would silently suppress the stop report for every later shutdown.

**What CI cannot cover, and what it means.** No test here installs a
real service, so `StartServiceCtrlDispatcher` succeeding, `ServiceMain`
being invoked, and `SetServiceStatus` transitions as the SCM sees them
are all unverified by the suite. CI covers the wiring and the console
path; it does not prove the Windows Server behaviour. That needs a
manual check on a Windows host, which is recorded here rather than
assumed:

```
sc create CrossByteTest binPath= "C:\path\to\server.exe"
sc start CrossByteTest
sc stop CrossByteTest          # callbacks must run; state must reach STOPPED
sc delete CrossByteTest
```

The service reaching `STOPPED` rather than "terminated unexpectedly" in
the Windows event log is the observable that distinguishes this working
from the process merely dying quietly.

## Seams left open

- `SERVICE_ACCEPT_PRESHUTDOWN` is not requested. It grants a longer
  window at system shutdown, but is documented as not to be combined
  with `SERVICE_ACCEPT_SHUTDOWN`, and `STOP` is the control that matters
  day to day since it is what a restart or an upgrade sends. Worth
  revisiting for a deployment where system-shutdown drain time is the
  binding constraint.
- No service installer. `sc create` and the various wrappers already do
  this, and baking an installer into the runtime would commit CrossByte
  to a deployment opinion it does not otherwise hold.
- POSIX targets report `UNAVAILABLE` and keep using `SIGINT`/`SIGTERM`,
  which is what systemd sends; no equivalent work is needed there.
