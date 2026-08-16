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
