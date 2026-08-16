# Proposal 0007 — Built-in metrics and a scrape endpoint

**Status:** Implemented on branch `main`

**Motivation:** Proposal 0005 added instruments and a registry, but
nothing published anything. Every service had to hand-roll its own
counters for the same three questions — how many requests, how slow, how
many connections — and there was no way to expose the result over HTTP
without writing a listener. The observability story existed but did not
work out of the box.

---

## What landed

### A public response API for middleware

`HTTPRequestHandler.respond(status, contentType, body, ?headers,
?statusMessage)`.

Middleware previously could only call `next()` or fail the request with a
status; there was no way to *answer* one. That blocked the metrics
endpoint, and equally blocks health checks, authentication replies, and
small API routes. Middleware that responds must not also call `next()` —
the request is complete, and continuing would attempt a second response
on the same connection.

This is the enabling change; the metrics endpoint is its first consumer.

### `MetricsEndpoint`

Middleware serving a registry in Prometheus text format:

```haxe
config.middleware.push(MetricsEndpoint.middleware(Metrics.shared));
```

Built as middleware so it composes with existing routing instead of
needing its own listener. Non-`GET`/`HEAD` requests get 405 rather than
being silently treated as scrapes, and a rendering failure returns 500
rather than propagating — a failing scrape must not take down the service
it observes.

The endpoint is unauthenticated by design: it is documented to be bound to
a private interface, placed behind a proxy rule, or preceded by an
authentication middleware when the port is public.

### `HTTPServer` instrumentation

Opt-in through `HTTPServerConfig.metrics` (a registry; `null` records
nothing) and `metricsPrefix` (default `http`, so several servers in one
process can be told apart):

| Series | Type | Notes |
|---|---|---|
| `http_requests_total{status}` | counter | Labelled by status **class** (`2xx`, `5xx`) |
| `http_request_seconds` | histogram | Accept to response |
| `http_active_connections` | gauge | Bound to the server's live counter |

Two decisions worth recording:

- **Status class, not status code.** Alerts are written against "5xx
  rate", and one series per exact code multiplies cardinality for no
  operational gain. Eight distinct codes collapse to four series.
- **Series are created at startup**, so a scrape before the first request
  reports zero rather than omitting the series. An absent series and a
  genuinely idle server are indistinguishable to a collector otherwise.

The connection gauge is *bound* to `__connections` rather than mirrored,
so it cannot drift from the server's own accounting.

## Testing

- `tests/crossbyte/metrics/MetricsEndpointTest.hx`: path validation,
  content type, the exact series shape a server publishes, gauge tracking
  its source, and status-class cardinality collapse.
- `tests/crossbyte/http/HTTPServerMetricsTest.hx` (cpp): a live server and
  a real socket request. Asserts a served request lands in the counter
  under its status class, the duration histogram exists, the connection
  gauge settles back to zero, the endpoint serves the registry (including
  the server's own series, since the scrape is itself a request), `POST`
  to the endpoint is rejected, and a server configured without a registry
  records nothing.

## Seams left open

| Growth item | Notes |
|---|---|
| **Route labels** | Requests are counted by status only. A route-template label (`/users/:id`, never the raw path) would sharpen diagnosis without exploding cardinality. |
| **Pool and socket gauges** | `ConnectionPool` and `Socket.outputBufferLength` are pollable but not auto-registered; per-connection buffer depth needs a cardinality-safe aggregate rather than one series per peer. |
| **`ServerWebSocket` instrumentation** | Not yet wired, pending its drain work. |
| **Endpoint auth** | Deliberately absent; composes with an authentication middleware placed ahead of it. |
