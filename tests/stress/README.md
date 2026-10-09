# Concurrency stress suite

Run with:

```
haxe ci/stress-tests.hxml
export/ci-stress-tests/StressMain    # .exe on Windows
```

Exits non-zero if any case fails. Runs in a second or two, and is part of
the Windows native CI job.

## Why this exists separately from the utest suites

The interpreter test suite is single-threaded, so a data race in shared
state passes every unit test and only appears under real thread
contention. Each case here pins a race of that kind:

| Case | What it guards |
|---|---|
| `MetricsStress` | Metric-name validation must not share static `EReg` instances. `EReg` carries mutable match state, so concurrent matches would corrupt each other, reject valid names, throw, and silently drop updates (1850 of 50000 in one run). |
| `FutureAllStress` | `Future.all` over inputs completed together on several threads resolves once they have all completed. Counted down outside the joined future's lock, two completing at once lost a decrement and the join never resolved, with every input complete: 1 to 31 of 4,000 joins in each of 20 runs, natively and on the jvm. |
| `TimerIdStress` | Two threads making timers at once must never give two timers one handle, or the second registration evicts the first: a timer that silently never fires. |
| `ConnectionPoolStress` | The pool ceiling, exclusive checkout, and capacity accounting across the error path. A pool that leaks one connection per failure deadlocks after `maxSize` failures. |
| `TaskPoolDrainStress` | `shutdown(drain = true)` runs every submitted job. Silently dropped work is near-impossible to diagnose from a call site. |
| `IdleTaskPoolGcStress` | `TaskPool` must not park idle workers on `Condition.wait()`, which on hxcpp never reaches a GC safepoint, so the next thread to allocate would block forever inside the collector. Any application holding an idle pool could deadlock. |
| `SocketBackpressureStress` | A bounded socket stops buffering for a peer that has stopped reading. Unbounded, a single stalled client buffers 22 MB and is never dropped. |
| `SocketBlockedWriteDrainStress` | A socket still blocked re-queues itself from inside the registry's writable-queue dispatch, and the queue must keep that re-queue rather than clear it after the walk, or the socket is never retried, stranding what it holds with no error and no close (4 MB to a slow peer would deliver 2.8 MB and hang). |
| `SocketDeferredFlushStress` | A blocked write schedules its retry on a timer. If the socket closes first, the retry must find nothing to do: it runs inside the tick dispatch, so a throw there would escape `pump()` and stop the loop for every other connection instead of failing one. |
| `WebSocketRetentionStress` | Both WebSocket write sites treat a momentarily full send buffer the same way, as a write to retry, rather than one discarding the bytes and the other closing the session with 1006. A peer that pauses keeps its messages and its connection. |
| `WebSocketBufferLimitStress` | The other side of the same boundary: retention is bounded. A session carrying `ServerWebSocket.maxOutputBufferSize` is closed rather than retaining frames for a peer that never drains. |

## Writing a case

Implement `StressCase` and add it to the list in `tests/StressMain.hx`.

Assert on **invariants that must hold under any interleaving** (no lost
updates, no duplicate ids, no exceeded ceiling, no leaked capacity), never
on timing or ordering. A case whose expected result depends on scheduling
is a flaky test, not a race detector.

### Make sure the case can actually fail

A stress case that cannot reproduce its bug is a rubber stamp. Verify a
new case by temporarily reverting the fix it guards and confirming it
fails; restore the fix and confirm it passes.

**Verify that your reverted build is actually reverted.** Putting a
pre-fix copy of one file on an earlier `-cp` and leaving `-cp src` after
it does *not* shadow the original: Haxe compiles `src` and ignores the
override entirely. A "pre-fix" run done that way silently tests the fixed
code and passes, which reads exactly like a case with no teeth.

Two ways to avoid it. Copy the whole `src` tree, replace the file in the
copy, and build with only that copy on the classpath (no `-cp src` at
all). Or prove the mechanism first: put a deliberate syntax error in the
override and confirm the build *fails*. If it compiles, the override is
being ignored.

Better still, run a **known-failing control** through the same pipeline.
If a case you have already seen fail against pre-fix code now passes,
the harness is lying to you, not the code.

Keep the measured region free of locks. A case that called `timer.stop()`
straight after each construction would take the timer's mutex inside the
loop, serialize the threads, and close the very window under test; this
is why `TimerIdStress` buffers its timers and stops them only after the
creation loop.

The lesson generalizes: **any synchronization inside the hot loop,
including the harness's own bookkeeping lock, can mask the race you are
hunting.** Record results into thread-local buffers, merging them once at
the end.

### Getting a usable stack out of a failing case

`StressMain` prints `haxe.CallStack.exceptionStack()` for a case that
throws, but a release build often truncates it to the runtime frames
(`__dispatchTick`, `__stepHost`, `pump`) with the actual culprit missing,
because the dispatch helpers are `inline` and leave no frame behind.

Rebuild the suite with **`-debug --no-inline`** to recover the full chain:
with inlining on, a stack can end at `pump`; with it off, it names the
whole path, such as `Socket.flush ← Socket.__tryFlush ← Timer.delay`.

Exceptions thrown from *timer callbacks* stay invisible even then, since
the throw unwinds through `Timer.onTick`. Wrapping the `timer.__update()`
loop in a temporary try/catch that prints and rethrows will name the
offending timer; remove it once diagnosed.

### A case that only fails in the full run is a finding, not a flake

These cases share one process and one runtime, so state one case leaves
behind is visible to the next. When a case passes alone and fails in the
suite, resist the urge to isolate it: run it with the preceding case
(`StressMain <name-fragment>` filters by class name) and find out what was
left behind. What one case leaves behind can be a real bug that crashes
the whole runtime loop rather than one connection.

### Deadlocks are a special case

A data race can be *observed* (a duplicate id, a lost update) and reported
as a failure. A deadlock cannot: every thread stops, including the one
that would print the verdict. `IdleTaskPoolGcStress` guards a
garbage-collector deadlock, so with its bug present the process wedges
rather than reporting `[FAIL]`.

That is an acceptable outcome (CI job timeouts turn it into a failure),
but it means such a case cannot be verified the usual way. Verify it by
building against the pre-fix code in a scratch export directory and
confirming the *process hangs*, then confirming it passes against current
code. Never leave the reverted source in the working tree: build, restore
immediately, and run the already-built binary.
