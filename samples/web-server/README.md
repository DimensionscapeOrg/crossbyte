# Simple Web Server Sample

`web-server` starts a localhost `HTTPServer` and serves a tiny document root.

- `demo` starts the server, fetches `/` with `URLLoader`, prints the response,
  and shuts down automatically.
- `serve` starts the server and keeps it running so you can point a browser at
  it manually.

Useful commands from `samples/web-server`:

```sh
aedifex task sample-web-server-check ../..
aedifex task sample-web-server-cpp ../..
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\web-server\SimpleWebServerSample.exe
..\..\export\web-server\SimpleWebServerSample.exe serve
```
