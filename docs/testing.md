# Testing, benchmarks and load tests

CrossByte's test suite uses [utest](https://lib.haxe.org/p/utest), and runs on every target. The commands below
run from the repository root. A checkout needs CrossByte registered as a development haxelib for native builds
(`haxelib dev crossbyte .`), since its native externs find their build files through `${haxelib:crossbyte}`.

## The suites

| Target | Build | Run |
| --- | --- | --- |
| interpreter | `haxe ci/interp-tests.hxml` | (runs as it builds) |
| native, Windows | `haxe ci/native-tests.hxml` | `export/ci-native-tests/NativeSmokeMain.exe` |
| native, Linux and macOS | `haxe ci/posix-native-tests.hxml` | `export/ci-posix-native/NativeSmokeMain` |
| jvm | `haxe ci/jvm-tests.hxml` | `java -jar export/jvm/CrossByteTests.jar` |
| Node | `haxe ci/js-tests.hxml` | `node export/js-tests/tests.js` |
| neko | `haxe ci/neko-tests.hxml` | `neko export/neko/CrossByteTests.n` |
| HashLink | `haxe ci/hl-tests.hxml` | `hl export/hl/CrossByteTests.hl` |
| browser | `haxe ci/browser-tests.hxml` | `node ci/browser/run.js` (needs puppeteer) |

The same are tasks for the `aedifex` runner, which `Aedifex.hx` describes:

```sh
aedifex task interp-tests .
aedifex task native-tests .
aedifex tasks -json .
```

Building any suite with `-D crossbyte_check_events` runs it with every arrival's event checked for being kept past
its listener (see Build defines in the README). A native build with `-D gc_bisect` reads `CB_ONLY`, a comma-separated
list of substrings matched against test class names, and `CB_METHOD`, a regular expression over method names, so one
class or method runs without a rebuild.

The database suites (`ci/mysql-tests.hxml`, `ci/postgres-tests.hxml`, `ci/mongo-tests.hxml`) need a real server,
and the interop harnesses under `ci/interop`, `ci/relay` and `ci/rudp-interop` need Node and a native build of their
peer.

## Documentation examples

```sh
node ci/doc-examples.js
```

type-checks the fenced Haxe examples in the README, the guides under `docs/`, and the doc comments of the classes it
lists. Each file's examples form one module, in order, so a later example can use what an earlier one declared. An
example that starts with a comment such as `// Given session:RPCSession<ChatCommands>.` gets those as parameters,
so it can assume a receiver without setting it up.

## Benchmarks

`tests/bench` covers the paths that run once per unit of real work (per datagram, per connectivity check, per event),
where a regression is multiplied by traffic. Build and run it natively:

```sh
haxe ci/bench.hxml
./export/bench/BenchMain.exe
```

It reports the best of several samples per case. The numbers compare shapes of code on one machine in one sitting,
and are not comparable across machines. CI runs it so it keeps compiling, and ignores the numbers.

## Allocation budgets

`tests/crossbyte/AllocationBudgetTest.hx` measures how many bytes each common operation allocates (an HTTP/1.1,
HTTP/2 and TLS request, a WebSocket and a TCP echo, a reliable and a plain datagram, an RPC call, an event, a timer,
a post and an idle frame) and fails when one passes its budget: what it measured when the budget was set, plus about
a quarter. It runs in the native and jvm suites, the two targets with an allocation counter; `AllocationMeter` says
how each is read.

A failure names the operation, what it allocated in each of three runs, its budget and the figure the budget was set
from. Natively the runs read the same to the byte, so a failure that repeats when the class runs alone
(`-D gc_bisect`, `CB_ONLY=AllocationBudget`) is a path allocating more. To rebaseline after a deliberate change, run
the class alone with `CB_ALLOC_REPORT=1` set, which prints every figure, natively on Windows and Linux and on the jvm;
then set the measured figures, the budgets and the date at the top of the class.

## Load and churn

`tests/load` runs CrossByte the way a server and a game server run it: for minutes, at scale, with the clients in
other processes. It reports what the server costs, and whether what it holds comes back down once the clients have
gone. Build it natively for the machine you are on, then run a scenario:

```sh
haxe ci/load.hxml
./export/load/LoadMain game  --clients 1000 --hz 60 --seconds 600
./export/load/LoadMain churn --plan 50:300,200:300,1000:300,0:120
./export/load/LoadMain idle  --clients 10000 --seconds 120
```

- `game`: a reliable UDP game server ticking at `--hz`, sending every client a 100 to 400 byte snapshot each tick
  (sequenced, every fourth reliable) and taking an input from each every tick. Reports processor time per tick, tick
  time, input-to-acknowledgement latency, lost snapshots and retransmissions, and memory per session. At 1,000
  clients and 60 Hz no session held anything waiting while the server kept its tick, and none more than 18 KB when it
  was starved of processor time.
- `churn`: HTTP/1.1 keep-alive, HTTP/2 and WebSocket clients, half over TLS, connecting, doing a few requests and
  leaving, at each concurrency of `--plan` (`concurrency:seconds,...`; end with a `0:` phase to watch memory come
  back). Its default clients are `tests/load/churn-client.js`, which need Node 18 or later, whose TLS connections
  resume their sessions as browsers' do. `--client native` uses CrossByte's own clients instead, which do not resume,
  and speak HTTP/2 in clear only.
- `idle`: that many WebSocket connections held open and quiet: memory per connection, and what holding them costs
  of a core.

Each prints `LOAD {json}` lines (a window every `--report` seconds, then a summary) and exits 0 when every client saw
what it should have. Useful options:

- `--cpus 2-5 --client-cpus 6-15` keeps the server and its clients on separate processors; a server sharing a core
  with its own clients measures far more processor time a tick;
- `game --world-mb 1024` holds that much live world data, to see the collector's pauses;
- `churn --ops 1000:1000 --think 0 --kinds h1 --tls-share 0` measures one runtime's throughput for one protocol
  rather than its churn.

On Linux, raise the descriptor limit before a large idle run (`ulimit -n 65536`). To run on crossbyte-libuv's
backend, build with that library as its README says (`-lib crossbyte-libuv -D crossbyte_libuv_native`, plus
`LIBUV_INCLUDE`, `LIBUV_LIB` and `LIBUV_STATIC` on Windows) and pass `--libuv`. `ci/load-jvm.hxml` builds the game
server for the jvm; give it `--bots` with the native executable, so only the server is the jvm's.

CI runs none of this: the numbers are for reading, not gating.
