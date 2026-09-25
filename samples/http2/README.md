# HTTP/2 Sample

`http2` serves HTTP/2 and fetches over it, on one localhost port.

The point of the sample is how little there is to it:

- The listener sets `HTTPServerConfig.http2Enabled` and then serves **both**
  versions. Each connection is served as whichever one it turns out to be
  speaking — over TLS that is settled by ALPN, and over cleartext by the
  connection preface, which an HTTP/1.1 client never sends. Run it with
  `serve` and point a browser at it, and it will be served HTTP/1.1 on the
  same port.
- The client sets `URLRequest.httpVersion` and nothing else. The bundled
  backend registers itself the first time a request asks for HTTP/2.

Two requests go out at once. They share a single connection and travel as
concurrent streams, which is the difference from HTTP/1.1 keep-alive: the
second request never waits for the first one's framing.

Without arguments it checks both bodies against what it served and exits: 0
when both arrived, 1 otherwise, which is how CI runs it. With `serve` it keeps
serving, on a port the system picks and prints, until the process is stopped.

Useful commands from `samples/http2`:

```sh
aedifex task sample-http2-check <project-root>
```

```sh
aedifex task sample-http2-cpp <project-root>
```

From `samples/http2`, `<project-root>` is `../..`.

Raw HXML entrypoints:

```sh
haxe check.hxml
```

```sh
haxe cpp.hxml
```

Then run `export/http2/Http2Sample`, or `export/http2/Http2Sample serve` to keep
it running.

## Cancelling

`URLLoader.close()` cancels a request that is already in flight. Over HTTP/2
that resets just that stream and leaves every other request on the shared
connection running; over HTTP/1.1 the connection is the only unit there is, so
it closes.
