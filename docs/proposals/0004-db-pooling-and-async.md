# Proposal 0004 — Connection pooling and an async database facade

**Status:** Implemented on branch `main`

**Motivation:** Every CrossByte database driver is synchronous. Calling one
from a tick handler blocks the runtime loop for the duration of the query —
the single easiest way to make a CrossByte server stutter under load — and
there was no pooling, so each unit of work either reopened a connection or
shared one unsafely across threads.

Both problems were previously "discipline the application must supply."
This turns them into framework guarantees.

---

## What landed

Two new files; nothing existing is modified.

### `crossbyte.db.ConnectionPool<T>`

A fixed-ceiling pool, deliberately **parameterized on the connection type**
rather than built on a shared driver interface. The four drivers
(`SQLiteConnection`, `PostgresConnection`, `MySQLConnection`,
`MongoConnection`) have no common base, and inventing one would have meant
touching all of them — a breaking change for an rc. A factory-based generic
pool works with all four, and with any future driver, additively.

- Lazy creation up to `maxSize`, reuse thereafter.
- `acquire(?timeout)` blocks while saturated and throws on timeout rather
  than growing without bound.
- `withConnection(body)` returns the connection even when `body` throws.
  This is the important one: a pool that leaks a connection per error path
  deadlocks after `maxSize` failures.
- Optional `validate` retires connections that no longer work — how a pool
  survives a database restart or an idle-timeout disconnect — and
  `discard()` lets a caller retire one it knows is broken.
- `close()` closes idle connections and retires checked-out ones as they
  come back.
- Double release, foreign release, and factory failure cannot corrupt the
  accounting or permanently consume capacity.

Locking is a mutex on the threaded targets and compiles out elsewhere.
Validation and connection opening run **outside** the lock, so a slow
server cannot stall every other caller.

### `crossbyte.db.AsyncDatabase<T>`

Pairs a pool with a `TaskPool`:

```haxe
var db = AsyncDatabase.of(pool);           // workers sized to pool.maxSize

db.submit(c -> c.query("SELECT count(*) FROM users"))
    .onComplete(result -> Logger.info("counted"))
    .onError(error -> Logger.error('query failed: $error'));
```

`submit` runs the body on a worker thread holding a pooled connection and
returns a `Task<R>`. Because `Task` already queues cross-thread completions
onto the runtime that created it, callbacks arrive on the runtime thread
and may touch runtime state directly — while the body may not. That
division is the whole point of the facade.

`transaction(begin, commit, rollback, body)` provides the usual
commit-or-rollback scope. Transaction control is passed as callbacks
precisely because the drivers do not share an interface; a rollback failure
does not mask the original error.

`shutdown(drain = true)` stops the workers and closes the pool.

## Testing

- `tests/crossbyte/db/ConnectionPoolTest.hx` (44 assertions, all targets):
  lazy creation and reuse, ceiling enforcement and acquire timeout,
  connection returned on the throwing path, unhealthy-connection
  replacement, `discard`, close semantics for idle and checked-out
  connections, double/foreign release, factory failure not consuming
  capacity, null-factory rejection, option validation. Uses a fake
  connection type, so no database server is required.
- A native multi-threaded stress harness drives 640 jobs through 16 workers
  against a 4-connection pool, asserting the ceiling is never exceeded, no
  connection is ever issued to two callers at once, and no capacity leaks.
  Single-threaded interp cannot prove any of that.

## Seams left open

| Growth item | Notes |
|---|---|
| **Idle eviction / min-size** | Connections are never retired for being merely idle, so a burst leaves `maxSize` connections open. A max-idle-time sweep and a warm minimum are the usual next step. |
| **Fair queueing** | Waiters poll on a 1 ms slice rather than queueing, so acquisition order is not FIFO under contention. Fine at current scale; a condition-variable queue would make it fair and cheaper. |
| **Driver-level convenience** | `AsyncDatabase` is generic. Thin per-driver helpers (`AsyncPostgres.query(sql, params)`) would remove the closure boilerplate for the common case. |
| **Health-check scheduling** | `validate` runs on acquire. A background sweep would catch dead connections before a request pays for the round trip. |
| **Metrics** | `size`/`available`/`inUse` are pollable but not published; they are natural inputs to the metrics service. |
