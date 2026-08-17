# Windows Service Sample

`windows-service` runs an `HTTPServer` that drains its in-flight requests when
the Windows Service Control Manager stops it — and behaves the same way under
`Ctrl+C` when run from a console.

It is also the harness for verifying proposal 0014 by hand. Nothing in CI
installs a real service, so `StartServiceCtrlDispatcher` succeeding,
`ServiceMain` being invoked, and the status transitions as the SCM sees them
are only ever proven here.

Useful commands from `samples/windows-service`:

```sh
aedifex task sample-windows-service-check <project-root>
aedifex task sample-windows-service-cpp <project-root>
```

From `samples/windows-service`, `<project-root>` is `../..`.

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\windows-service\WindowsServiceSample.exe
..\..\export\windows-service\WindowsServiceSample.exe 9090
```

## Console run

```
..\..\export\windows-service\WindowsServiceSample.exe
```

Fetch `http://127.0.0.1:8080/`, then press `Ctrl+C`. The same shutdown callback
runs as under the SCM: the log records `stop requested; draining` and then
`drain complete`. The log is `service-sample.log`, written next to the
executable.

## Service run

Both commands need an elevated prompt. `binPath=` must be an absolute path, and
the space after `=` is required by `sc` — it is not a typo.

```
sc create CrossByteSample binPath= "C:\full\path\to\WindowsServiceSample.exe" start= demand
sc start CrossByteSample
sc query CrossByteSample
sc stop CrossByteSample
sc delete CrossByteSample
```

### What to check

The point of the exercise is that the stop is orderly rather than a kill:

1. After `sc start`, `sc query` reports `RUNNING`, and `service-sample.log`
   contains `started under the service control manager` with `service=true`.
   Seeing `started as a console process` instead means the SCM handshake did not
   happen and everything below is moot.
2. `http://127.0.0.1:8080/` serves the sample page while the service runs.
3. After `sc stop`, the log contains `stop requested; draining` followed by
   `drain complete; reporting service stopped`. **This is the observable that
   did not exist before proposal 0014** — the callback did not run at all, so
   neither line was ever written.
4. `sc query` reports `STOPPED`, and the Windows event log has no
   "terminated unexpectedly" entry for the service. That entry is what a
   process dying without reporting `SERVICE_STOPPED` produces, and its absence
   is the difference between a drain and a kill.

To watch the drain actually wait on something, hold a request open across the
stop — the log line reports the connection count it started draining with.

### If the service will not start

`sc start` failing with error 1053 ("did not respond in a timely fashion")
means the process did not reach `installServiceControl` inside the SCM's start
window. Run the executable from a console first: a crash on startup, a missing
DLL, or a bad working directory all present as 1053 and none of them are
service-control problems.

A service runs with the working directory set to `C:\Windows\System32`, not the
executable's folder, which is why the log path and document root here are both
resolved from `Sys.programPath()` rather than a relative path. Anything relative
would silently end up in the system directory, or fail to write there.
