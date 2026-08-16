# Proposal 0005 — Metrics

**Status:** Implemented on branch `main`

**Motivation:** A server that cannot be observed cannot be operated. There
was no way to answer "how many requests, how slow, how many connections in
use" without a service inventing its own counters. Proposals 0003 and 0004
both ended with pollable state (`activeConnections`, `pendingHandshakeCount`,
pool `size`/`available`/`inUse`) and nowhere to publish it.

---

## What landed

A new `crossbyte.metrics` package. Nothing existing is modified.

### The three instrument types

- **`Counter`** — a monotonic total (requests served, bytes sent).
  `inc()` rejects negative amounts: a counter that can decrease would
  corrupt every rate a collector derives from it, and the value dropping is
  how a collector detects a process restart.
- **`Gauge`** — a value that rises and falls (active connections, queue
  depth). May hold its own value, or be **bound** to a provider function
  and sampled on read. Binding suits values another component already
  tracks, since a bound gauge cannot drift out of sync with its source:

  ```haxe
  Metrics.shared.gaugeFn("db_pool_in_use", () -> pool.inUse());
  ```

  A provider that throws yields `0` rather than propagating — scraping
  metrics must never be able to fail a request path.
- **`Histogram`** — a distribution in cumulative buckets, which is what
  supports a latency objective ("99% under 500 ms") that an average hides.
  Bucket count is fixed up front, so cost stays constant however many
  observations arrive. `time(body)` records the duration of `body`
  **including when it throws**, so failing paths still contribute to the
  latency picture.

### `Metrics` registry

Get-or-create by name plus labels, so components fetch metrics where they
need them rather than threading handles through constructors.
`Metrics.shared` is the process-wide instance; services wanting isolation
(tests especially) construct their own.

Names and labels are validated against the Prometheus grammar at creation.
Rejecting early means a metric cannot exist that an exporter would later
have to mangle or drop.

Series keys are built with separator characters the validators reject, so
no two distinct name/label combinations can collide into one series — a
subtle failure that naive concatenation produces (`"ab"{c=d}` versus
`"a"{bc=d}`).

### Export

`toPrometheus()` renders the standard text exposition format: one
`HELP`/`TYPE` header per metric name even across many labelled series,
label values escaped, and labels sorted so output is byte-stable across
scrapes. Serve it from a status endpoint with content type
`text/plain; version=0.0.4`.

### Cardinality and privacy

Documented on the registry, because it is the mistake that bites hardest:
every distinct label combination is a separate series retained for the
process lifetime. Labels must describe **categories** — route template,
status class, outcome — never user identifiers, tokens, or paths
containing identifiers. Doing otherwise grows memory without bound and
converts an operational metric into a per-user behavior record. For
Knownfolk this is not merely advice; §19.2 of its spec requires aggregate
metrics only.

## Testing

- `tests/crossbyte/metrics/MetricsTest.hx` (61 assertions, all targets):
  counter accumulation and negative rejection, gauge rise/fall, bound-gauge
  sampling and write-immunity, failing provider, cumulative buckets, bucket
  sorting and duplicate rejection, `time()` recording on the throwing path,
  instance identity, label-distinct series, key-collision resistance, name
  and label validation, Prometheus shape for all three types, escaping,
  one-header-per-name, label-order stability, and `clear()`.
- A native stress harness drives 2,000 jobs across 16 threads performing
  50,000 increments and observations, asserting no updates are lost and
  concurrent get-or-create converges on one instance per name rather than
  racing into duplicates.

## Seams left open

| Growth item | Notes |
|---|---|
| **Built-in instrumentation** | `HTTPServer`, `ConnectionPool`, and `RateLimiter` expose pollable state but do not self-register gauges. Wiring them in is a small follow-up; kept separate so this change stays additive and services choose their own metric names. |
| **A metrics endpoint** | No built-in HTTP handler yet; `toPrometheus()` is a string a service serves however it likes. A ready-made middleware would remove the boilerplate. |
| **Summaries / quantiles** | Histograms cover the common case. Client-side quantiles need a streaming estimator. |
| **Exemplars and OpenMetrics** | The newer format adds trace linking; the current output is the widely-supported 0.0.4 text format. |
| **Push exporters** | Only pull-based scraping is supported. StatsD or OTLP push would be separate exporters over the same registry. |
