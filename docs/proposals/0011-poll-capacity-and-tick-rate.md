# Proposal 0011 — Poll capacity and server tick rate

**Status:** Implemented

**Motivation:** Two runtime defaults were sized for a general-purpose
application loop rather than a network service: the poll backend started
at 64 sockets, and the loop ticked 12 times per second.

Investigating them corrected two assumptions I had been carrying — both
worth recording, because they change what the fix should be.

---

## Correction 1: 64 was never a ceiling

I had described `DEFAULT_MAX_SOCKETS = 64` as a limit to raise. It is not.
`NativeSocketRegistry.register()` calls `__grow()` when the set exceeds
capacity, expanding by 1.5×. A server has always been able to exceed 64
connections.

What 64 actually costs is **growth churn**. Each step disposes the poll
backend, allocates a replacement, and marks the registry dirty so every
socket is re-registered. Reaching a thousand connections walks
64 → 96 → 144 → 216 → 324 → 486 → 729 → 1094: roughly seven
rebuild cycles, all while the server is at its busiest.

## Correction 2: `FD_SETSIZE` does not apply here

The obvious worry with a large socket count on Windows is `select()`'s
fixed `FD_SETSIZE`, classically 64 — a suspiciously exact match for the
default. It does not apply. hxcpp's `Poll` allocates a right-sized
descriptor set with `malloc(FDSIZE(max))` and drives `fd_count` /
`fd_array` directly; on POSIX it allocates a `pollfd` array. The
`FD_SETSIZE` guard in hxcpp's socket layer belongs to the separate
`Socket.select` path, which this backend does not use.

So capacity is a tuning value, not a platform constraint.

## Correction 3: tick latency is specific to the `POLL` loop, and 12 is a deliberate default

The `POLL` loop calls `__socketRegistry.update(0)` — a zero timeout — then
waits out the remainder of the frame in 1 ms sleeps, so under *that* loop
a socket becoming readable just after the poll waits up to a tick interval
before it is serviced. The zero timeout is deliberate: the comment above
it records that letting poll own the frame wait starved CrossByte timers
with an idle Windows UDP socket registered.

Two things I initially got wrong about this.

First, it is not a property of the runtime, only of one supplied loop.
`MainLoopType.CUSTOM(loop)` lets an application provide its own, and
`pump(delta, socketTimeout)` takes a socket timeout — so a loop that wants
readiness-driven wakeups can block in poll and get them, with tick rate no
longer bounding I/O latency at all. The blocking configuration exists; the
`POLL` loop simply does not choose it.

Second, 12 ticks per second is a deliberate low-power threshold, not an
oversight inherited from application-loop defaults. An idle service costs
twelve wakeups a second instead of sixty. For a basic networked mechanism
that is the right trade, and tick-rate scheduling is a normal way to run a
server loop.

---

## What landed

- **`CrossByte.defaultSocketCapacity`** (default 1024, was effectively
  64). A starting allocation, documented as such, that a process can tune
  either way before creating runtimes. Non-positive values fall back to
  the historical default rather than producing a zero-sized backend.
- **`ServerApplication.defaultTicksPerSecond`** (default `0`, meaning
  inherit the runtime's 12). A documented seam for services whose latency
  bound *is* tick cadence, applied before `INIT` so a subclass can still
  override it. No timing changes for anyone who does not set it.

  This shipped briefly as `60`. That was wrong: it silently changed the
  cadence of every existing `ServerApplication`, and it treated a
  deliberate low-power default as a deficiency. Raising tick rate is a
  deployment decision, not something an entry point should assume.

Both are plain statics rather than constructor parameters: they need to
be settable before a runtime exists, and adding parameters would have
meant touching several constructors.

## Testing

`tests/crossbyte/core/SocketCapacityTest.hx`: the default is sized for
server workloads, capacity is configurable, non-positive values fall back
rather than producing a zero-sized backend, and the backend honours
requested capacities well past 64 — the assertion that would have failed
had `FD_SETSIZE` actually applied.

## Seams left open

| Growth item | Notes |
|---|---|
| **Readiness-driven waiting in the stock `POLL` loop** | Already reachable via `MainLoopType.CUSTOM` with a non-zero `pump` socket timeout; the open item is only whether `POLL` itself should offer it as an option. Doing so means solving the Windows UDP timer-starvation behaviour the zero timeout works around — needs a targeted reproduction first. |
| **Growth without full rebuild** | `__grow()` re-registers every socket. An incremental resize would make the starting capacity matter less. |
| **Capacity metrics** | Registry size and grow count are natural gauges, and would show whether a deployment's starting capacity is well chosen. |
| **Per-runtime capacity** | Currently process-wide at construction time; a child runtime carrying far more sockets than its siblings cannot be sized independently. |
