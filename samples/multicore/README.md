# Multicore Sample

`multicore` starts a localhost `HTTPServer` spread over four runtimes with
`HTTPServerConfig.runtimeCount`, so it serves its connections on four
threads at once.

- run without arguments, it fetches from itself, sixteen requests at once,
  prints which runtime answered how many, drains the server and exits: 0 when
  every request was answered and more than one runtime answered them, after
  an `OK` line; otherwise 1, after a `FAIL` line per failed check, with the
  reason on stderr;
- `serve [runtimes]` serves on port 8080 until the process exits.

The middleware shows the rule a spread server's code follows: what it only
reads once built can be shared, and what several runtimes change needs a
lock. See "Using more than one core" in [docs/runtime.md](../../docs/runtime.md).

Useful commands from `samples/multicore`:

```sh
aedifex task sample-multicore-check <project-root>
aedifex task sample-multicore-cpp <project-root>
```

From `samples/multicore`, `<project-root>` is `../..`.

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\multicore\MulticoreSample.exe
..\..\export\multicore\MulticoreSample.exe serve 8
```
