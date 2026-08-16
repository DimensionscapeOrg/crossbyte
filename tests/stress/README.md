# Concurrency stress suite

Run with:

```
haxe ci/stress-tests.hxml
export/ci-stress-tests/StressMain    # .exe on Windows
```

Exits non-zero if any case fails. Runs in about half a second, and is part
of the Windows native CI job.

## Why this exists separately from the utest suites

The interpreter test suite is single-threaded, so a data race in shared
state passes every unit test and only appears under real thread
contention. Every case here corresponds to a bug that actually reached the
repository and was found this way:

| Case | Bug it caught |
|---|---|
| `MetricsStress` | Metric-name validation used shared static `EReg` instances. `EReg` carries mutable match state, so concurrent matches corrupted each other, spuriously rejected valid names, threw, and silently dropped 1850 of 50000 updates. |
| `TimerIdStress` | `haxe.Timer` allocated its id from a static counter outside the lock guarding the timer map. Two threads could take the same id, and the second registration evicted the first — a timer that silently never fires. |
| `ConnectionPoolStress` | Guards the pool ceiling, exclusive checkout, and capacity accounting across the error path. A pool that leaks one connection per failure deadlocks after `maxSize` failures. |
| `TaskPoolDrainStress` | Guards that `shutdown(drain = true)` runs every submitted job. Silently dropped work is near-impossible to diagnose from a call site. |
| `IdleTaskPoolGcStress` | `TaskPool` parked idle workers on `Condition.wait()`, which on hxcpp never reaches a GC safepoint, so the next thread to allocate blocked forever inside the collector. Any application holding an idle pool could deadlock — the suite merely made it certain. |
| `SocketBackpressureStress` | Guards that a bounded socket stops buffering for a peer that has stopped reading. Unbounded, a single stalled client buffered 22 MB and was never dropped. |
| `SocketBlockedWriteDrainStress` | The registry drained its writable queue with `forEach` and then cleared it, but a socket still blocked re-queues itself from inside that dispatch — so the clear threw the re-queue away and the socket was never retried again, stranding whatever it held with no error and no close. 4 MB to a slow peer delivered 2.8 MB and hung; it now completes in 3 ms. |
| `SocketDeferredFlushStress` | A blocked write schedules its retry on a timer. If the socket closed first, the retry flushed a released socket and threw — from inside the tick dispatch, so it escaped `pump()` and stopped the loop for every other connection instead of failing one. |
| `WebSocketRetentionStress` | The WebSocket write path treated a momentarily full send buffer as two different things in two places: one site discarded the bytes and only traced, the other closed the session with 1006. A peer that paused therefore lost either messages or its connection. |
| `WebSocketBufferLimitStress` | The other side of the same boundary: retention must be bounded. Guards that a session carrying `ServerWebSocket.maxOutputBufferSize` is closed rather than retaining frames for a peer that never drains. |

## Writing a case

Implement `StressCase` and add it to the list in `tests/StressMain.hx`.

Assert on **invariants that must hold under any interleaving** — no lost
updates, no duplicate ids, no exceeded ceiling, no leaked capacity — never
on timing or ordering. A case whose expected result depends on scheduling
is a flaky test, not a race detector.

### Make sure the case can actually fail

A stress case that cannot reproduce its bug is a rubber stamp. Verify a
new case by temporarily reverting the fix it guards and confirming it
fails; restore the fix and confirm it passes.

**Verify that your reverted build is actually reverted.** Putting a
pre-fix copy of one file on an earlier `-cp` and leaving `-cp src` after
it does *not* shadow the original — Haxe compiled `src` and ignored the
override entirely. Every "pre-fix" run done that way silently tested the
fixed code and passed, which reads exactly like a case with no teeth, and
led to a published claim that a test did not catch a bug when the
experiment had never tested the buggy code at all.

Two ways to avoid it. Copy the whole `src` tree, replace the file in the
copy, and build with only that copy on the classpath — no `-cp src` at
all. Or prove the mechanism first: put a deliberate syntax error in the
override and confirm the build *fails*. If it compiles, the override is
being ignored.

Better still, run a **known-failing control** through the same pipeline.
If a case you have already seen fail against pre-fix code now passes,
the harness is lying to you, not the code.

`TimerIdStress` is the cautionary example. Its first version called
`timer.stop()` immediately after each construction — but `stop()` takes
the same mutex, which serialized the threads and closed the very window
under test. With the bug reintroduced it still reported zero duplicates
across three runs. Buffering the timers and stopping them only after the
creation loop exposed the race immediately: about 90–105 duplicate ids per
run, every run.

The lesson generalizes: **any synchronization inside the hot loop —
including the harness's own bookkeeping lock — can mask the race you are
hunting.** Keep the measured region free of locks and record results into
thread-local buffers, merging them once at the end.

### Getting a usable stack out of a failing case

`StressMain` prints `haxe.CallStack.exceptionStack()` for a case that
throws, but a release build often truncates it to the runtime frames —
`__dispatchTick`, `__stepHost`, `pump` — with the actual culprit missing,
because the dispatch helpers are `inline` and leave no frame behind.

Rebuild the suite with **`-debug --no-inline`** to recover the full chain.
That is what identified `SocketDeferredFlushStress`'s bug: with inlining
on, the stack ended at `pump`; with it off, it named
`Socket.flush ← Socket.__tryFlush ← Timer.delay`, which was the whole
answer.

Exceptions thrown from *timer callbacks* stay invisible even then, since
the throw unwinds through `Timer.onTick`. Wrapping the `timer.__update()`
loop in a temporary try/catch that prints and rethrows will name the
offending timer; remove it once diagnosed.

### A case that only fails in the full run is a finding, not a flake

These cases share one process and one runtime, so state one case leaves
behind is visible to the next. When a case passes alone and fails in the
suite, resist the urge to isolate it — run it with the preceding case
(`StressMain <name-fragment>` filters by class name) and find out what was
left behind.

`WebSocketRetentionStress` did exactly this, and the leftover was a real
bug that crashed the whole runtime loop rather than one connection.

### Deadlocks are a special case

A data race can be *observed* (a duplicate id, a lost update) and reported
as a failure. A deadlock cannot: every thread stops, including the one
that would print the verdict. `IdleTaskPoolGcStress` guards a
garbage-collector deadlock, so with its bug present the process wedges
rather than reporting `[FAIL]`.

That is an acceptable outcome — CI job timeouts turn it into a failure —
but it means such a case cannot be verified the usual way. Verify it by
building against the pre-fix code in a scratch export directory and
confirming the *process hangs*, then confirming it passes against current
code. Never leave the reverted source in the working tree: build, restore
immediately, and run the already-built binary.
