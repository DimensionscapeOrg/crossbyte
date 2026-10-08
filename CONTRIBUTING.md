# Contributing to CrossByte

## Setting up

1. Native builds need the `production` branch of the hxcpp fork:
   `haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production`.
2. Register your checkout as the `crossbyte` haxelib: `haxelib dev crossbyte .`. The native externs include their
   build files through `${haxelib:crossbyte}`, so `-cp src` alone does not build natively.
3. Install the libraries the suites use, at the versions in `ci/haxelibs.txt`: utest, hxjava (for the jvm),
   hxnodejs (for Node) and dox (for the API docs).
4. Optionally, `haxelib install aedifex` for the task runner. `Aedifex.hx` describes the library and its tasks, and
   `haxelib.json` is generated from it: run `aedifex haxelib sync .` after changing it.

## A change is done when

- **It is tested.** A fix comes with a test that fails without it. A new feature tests its edges and its refusals,
  not only the path that works. [docs/testing.md](docs/testing.md) lists the suites; run the ones for the targets the
  change touches, and the native suite for anything below the API.
- **It is documented**:
  - at each new or changed member: what it does, its default, what a peer can cost, and what differs per target;
  - in the README or the guide under `docs/` a user would read;
  - in `CHANGELOG.md`, under Added, Changed or Fixed, and under Upgrading when existing code must change.
- **Its examples compile.** `node ci/doc-examples.js` type-checks the fenced Haxe examples in the README, in
  `docs/`, and in the doc comments of the classes it lists, and must report 0 failures. Add a new guide to its list.
- **Every `ci/*.hxml` still type-checks.** Some builds only run in CI (the browser build, the database suites, the
  interop peers), so a change can break one that no local suite builds.

Where a well-known stack (TCP, QUIC, DTLS, browsers, major libraries) has settled a design question, follow it and
name it in the docs. A design that measurably does better is welcome; show the measurement against that baseline.

## Continuous integration

CI covers:

- the portable suite on the interpreter, the jvm, Node and a headless browser; the interpreter, jvm and Node runs
  again with `-D crossbyte_check_events`;
- the native suite on Windows, Linux and macOS (macOS with `-D crossbyte_check_events`), the crypto and system
  suites, and the concurrency stress suite;
- the whole suite on HashLink and Neko, on Windows and Linux;
- the MySQL, PostgreSQL and MongoDB suites against real servers;
- browser interop against headless Chrome, TURN relay interop against an independent server, and reliable UDP
  interop between native, jvm and Node ends;
- the native samples, built and run;
- builds that only check the API: hxcpp audit builds, `-D precision_tick` and `-D timer_burst_catchup`;
- the extensions' own suites (`crossbyte-libuv`, `crossbyte-brotli`, `crossbyte-lz4`);
- the generated API documentation, published as the run's `crossbyte-api-docs` artifact.

`RELEASING.md` covers how CI installs its libraries, and how a release is made.
