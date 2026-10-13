# Performance

What CrossByte costs, measured: the bytes an operation allocates, what a server holds for each connection, an RPC
call's latency, processor time and bytes on the wire beside gRPC's, and how an HTTP server scales over cores. Every
figure comes from one machine, over loopback, and is for comparing shapes of work there; another machine's numbers
will differ. Every one can be measured again with a program in this repository (see the end of the page).

## How it was measured

- **Machine.** AMD Ryzen 9 9950X (16 cores, 32 logical processors), 62 GB of memory, Windows 10 Pro (build 19045).
  Figures marked Linux ran in WSL 2 on the same machine (Ubuntu, 4 processors, GCC).
- **Builds.** Haxe 4.3.7. Natively, hxcpp from the [`dimensionscape/hxcpp`](https://github.com/dimensionscape/hxcpp)
  `production` branch with Visual Studio 2022 (17.14). The JVM: Oracle Java 8 (1.8.0_501) on Windows, Temurin 8
  (1.8.0_504) on Linux, and Temurin 17 (17.0.20.1) where a table says so. Node 24.14.1. Go 1.27.2.
- **Loopback.** Both ends of every connection on the same machine. Nothing here crossed a real network; where loss
  matters, the bench drops datagrams itself.
- **Interleaved.** What a table compares took turns within each repetition, three repetitions, and a table gives
  the median, with the range across the three in brackets where it shows one.
- **A shared machine.** Other work ran beside the measurements, using about a third of the machine's logical
  processors. That moves absolute rates between sittings; the rates one table compares were measured in one
  sitting.
- **Allocation.** Bytes per operation are read natively from hxcpp's allocation cursor and on the JVM from the
  thread's own count (`ThreadMXBean`), both through the suite's `AllocationMeter`.
- **Processor time.** In the gRPC comparison, from the cycles each process's threads ran (`QueryProcessCycleTime`),
  read the same way for every process. The user and kernel times Windows reports charge a whole clock tick to
  whichever thread is running when it lands, so they undercount a process that wakes often and briefly; the other
  figures that use them come from processes kept busy.

## Allocation per operation

`AllocationBudgetTest` runs each operation for real, both ends over loopback in one process, and reads the median of
three runs. It runs in the native and JVM suites and fails when an operation allocates more than its figure here,
plus about a quarter, so these hold for every build that passes the suite. Bytes per operation, both ends together;
natively Linux reads the same as Windows. The time is natively on Windows, both ends together, and for anything
over a socket mostly the system's loopback calls.

| Operation | Native | Time, native | JVM |
| --- | --- | --- | --- |
| an event dispatched to a listener | 0 | 14 ns | 0 |
| a timeout armed and fired | 0 | 99 ns | 0 |
| an interval timer firing and re-arming | 0 | 82 ns | 0 |
| a callback posted to the runtime and run | 0 | 83 ns | 0 |
| a runtime frame with nothing to do | 0 | 56 ns | 0 |
| a 100-byte message echoed over TCP | 0 | 16.1 us | 32 |
| a 100-byte datagram sent and received | 0 | 6.6 us | 16 |
| a 200-byte reliable UDP message, delivered and acknowledged | 0 | 15.3 us | 48 |
| the same, encrypted | 0 | 17.7 us | 48 |
| a 100-byte WebSocket text message echoed | 112 | 16.9 us | 280 |
| a line written to a streamed HTTP response | 0 | 8.2 us | 16 |
| an HTTP/1.1 GET on a kept-alive connection | 152 | 17.8 us | 240 |
| the same over TLS | 152 | 19.9 us | 6,968 |
| an HTTP/1.1 POST of 4 KB | 4,608 | 19.3 us | 4,648 |
| an HTTP/2 GET, cleartext | 592 | 17.9 us | 496 |
| an RPC call answered through a receiver, in memory | 0 | 137 ns | 0 |
| the same over TCP | 0 | 16.4 us | 32 |
| the same over reliable UDP | 0 | 14.7 us | 32 |
| the same over WebSocket with TLS | 0 | 18.7 us | 6,208 |
| an RPC call answered through a future, in memory | 152 | 169 ns | 96 |
| the same over TCP | 152 | 16.5 us | 128 |
| a one-way RPC call | 0 | 67 ns | 0 |

What is left natively is what the API hands to code that may keep it: the `String` a WebSocket listener asks for
(reading `data` instead allocates nothing), an HTTP request's own fields, the `RPCResponse` a call made with a
future returns, and a POST's body.

The JVM column is the largest of Oracle 8 on Windows, Temurin 8 on Linux and a run of the whole suite. Where it
reads 16 to 48 bytes for a message, that is the JDK's own selector on Windows boxing the descriptor of each socket it
finds ready; on Oracle 8 the class run alone reads 0 there. TLS on the JVM is the JDK's engine. On Java 17, the class
run alone:

| Operation | Temurin 17, Windows | Temurin 17, Linux |
| --- | --- | --- |
| a 100-byte message echoed over TCP | 32 | 0 |
| a 100-byte datagram sent and received | 16 | 0 |
| a 200-byte reliable UDP message, in the clear or encrypted | 32 | 0 |
| an RPC call through a receiver, over TCP or reliable UDP | 32 | 0 |
| an RPC call through a future, over TCP | 128 | 96 |
| a line written to a streamed HTTP response | 16 | 0 |
| an HTTP/1.1 GET on a kept-alive connection | 168 | 136 |
| a 100-byte WebSocket text message echoed | 179 | 157 |

## What a server holds for a connection

The heap after a full collection with 1,000 connections open, less the heap before any connected, over 1,000, in
the server's process; the clients ran in a process of their own. Each connection has one listener for what arrives,
as an application's would.

| Connection | Native | JVM (Oracle 8) |
| --- | --- | --- |
| a TCP connection, idle | 1,260 B | 1,602 B |
| the same, 12 s after a 16 KB message each way | 1,460 B | 1,741 B |
| a WebSocket session, idle | 4,046 B | 3,501 B |
| the same, 75 s after a 16 KB message each way | 4,600 B | 3,689 B |
| a reliable UDP session, idle | 2,817 B | 1,791 B |
| the same, encrypted | 4,696 B | 3,113 B |

A busy connection keeps its buffers' storage, so a message read or written allocates nothing. A quiet TCP connection
lets that storage go at its runtime's next sweep (every 5 s), and a WebSocket session once a whole heartbeat
interval (30 s unless set) has passed with nothing heard or sent: 40 s after its message a session still held 70 KB.

## RPC beside gRPC

Unary calls between two processes, client and server each its own system's: a small call (an `Int` each way; a
protobuf `int32` for gRPC) and a call of 4 KB each way, with one connection and one call in flight, and with 8
connections and 32 calls in flight on each. CrossByte's calls are answered through receivers, and each end is one
runtime, so one thread. grpc-go 1.84.0 runs as Go does by default, on all 32 logical processors, and again with
`GOMAXPROCS=1` on both ends; grpc-js 1.14.6 on Node, each connection a channel of its own. Each cell is a five-second
window after two seconds' warm-up. Processor time is each process's, read from outside at the start and end of the
window, over the calls answered in it. Bytes on the wire are TCP payload (no IP or TCP headers) counted by a proxy,
everything the connections carried over the calls made.

A small call:

| System | Connections x in flight | Calls/s | p50 | p99 | Server CPU a call | Client CPU a call | Bytes a call, out + back |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CrossByte, native, TCP | 1 x 1 | 16,142 (15,941-16,253) | 47 us | 119 us | 34 us | 34 us | 15 + 15 |
| CrossByte, native, TCP | 8 x 32 | 2,214,471 (2,126,828-2,217,802) | 92 us | 1,391 us | 0.32 us | 0.37 us | 16 + 16 |
| CrossByte, native, WebSocket | 1 x 1 | 14,859 (14,810-14,941) | 51 us | 148 us | 36 us | 36 us | 21 + 17 |
| CrossByte, native, WebSocket | 8 x 32 | 1,320,261 (1,301,966-1,344,619) | 158 us | 1,696 us | 0.54 us | 0.62 us | 22 + 18 |
| CrossByte, Node, TCP | 1 x 1 | 12,637 (12,637-12,833) | 74 us | 134 us | 48 us | 50 us | 15 + 15 |
| CrossByte, Node, TCP | 8 x 32 | 1,736,619 (1,696,266-1,828,247) | 137 us | 303 us | 0.49 us | 0.58 us | 16 + 16 |
| grpc-go | 1 x 1 | 5,222 (4,707-5,349) | 106 us | 424 us | 133 us | 134 us | 80 + 86 |
| grpc-go | 8 x 32 | 242,337 (239,952-246,783) | 918 us | 2,894 us | 33 us | 40 us | 35 + 41 |
| grpc-go, `GOMAXPROCS=1` | 1 x 1 | 8,879 (8,818-8,905) | 106 us | 188 us | 68 us | 66 us | 80 + 86 |
| grpc-go, `GOMAXPROCS=1` | 8 x 32 | 120,689 (118,518-121,331) | 1,948 us | 4,844 us | 6.3 us | 7.5 us | 34 + 40 |
| grpc-js, Node | 1 x 1 | 4,186 (4,073-4,258) | 225 us | 400 us | 137 us | 188 us | 48 + 42 |
| grpc-js, Node | 8 x 32 | 25,165 (24,389-26,392) | 8,949 us | 18,255 us | 28 us | 55 us | 49 + 43 |

4 KB each way:

| System | Connections x in flight | Calls/s | p50 | p99 | Server CPU a call | Client CPU a call | Bytes past the payload, out + back |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CrossByte, native, TCP | 1 x 1 | 14,986 (14,711-15,003) | 51 us | 146 us | 36 us | 36 us | 14 + 14 |
| CrossByte, native, TCP | 8 x 32 | 481,189 (479,245-488,784) | 408 us | 2,282 us | 1.7 us | 1.8 us | 18 + 18 |
| CrossByte, native, WebSocket | 1 x 1 | 12,494 (12,343-12,780) | 61 us | 225 us | 42 us | 42 us | 22 + 18 |
| CrossByte, native, WebSocket | 8 x 32 | 171,289 (170,927-173,473) | 1,260 us | 3,819 us | 5.0 us | 5.2 us | 26 + 22 |
| CrossByte, Node, TCP | 1 x 1 | 10,133 (10,075-10,295) | 87 us | 188 us | 63 us | 65 us | 14 + 14 |
| CrossByte, Node, TCP | 8 x 32 | 125,849 (123,716-126,884) | 1,872 us | 5,243 us | 9.2 us | 9.2 us | 20 + 20 |
| grpc-go | 1 x 1 | 5,558 (5,352-5,681) | 106 us | 362 us | 136 us | 135 us | 80 + 86 |
| grpc-go | 8 x 32 | 175,698 (174,402-179,706) | 1,260 us | 4,053 us | 46 us | 54 us | 35 + 41 |
| grpc-go, `GOMAXPROCS=1` | 1 x 1 | 8,465 (8,394-8,495) | 110 us | 208 us | 71 us | 70 us | 80 + 86 |
| grpc-go, `GOMAXPROCS=1` | 8 x 32 | 52,354 (52,163-55,593) | 4,844 us | 10,485 us | 17 us | 19 us | 35 + 41 |
| grpc-js, Node | 1 x 1 | 3,830 (3,802-3,976) | 248 us | 450 us | 151 us | 208 us | 51 + 44 |
| grpc-js, Node | 8 x 32 | 20,348 (19,928-20,441) | 11,127 us | 23,615 us | 45 us | 72 us | 57 + 48 |

Reading it:

- **One call at a time,** a small call took 47 us (p50) natively over TCP, where grpc-go took 106 us and grpc-js
  225 us. The server spent 34 us of processor time a call, grpc-go 68 us on one thread and 133 us on all 32, and
  grpc-js 137 us. With one call in flight, a process's processor time over the window includes what it spends
  between calls, not only the calls.
- **With 8 x 32 in flight,** CrossByte's one runtime answered 2.2 million small calls a second at 0.32 us of the
  server's processor time a call. grpc-go answered 242,000 a second at 33 us a call on all 32 logical processors,
  and 121,000 at 6.3 us with `GOMAXPROCS=1`; grpc-js 25,000 at 28 us. With 4 KB each way: 481,000 a second at 1.7 us
  against grpc-go's 176,000 at 46 us (52,000 at 17 us on one thread) and grpc-js's 20,000 at 45 us. There grpc-go's
  two processes used about 18 of the machine's 32 logical processors between them, beside the other work on it, so
  its rate is bounded by what was left; processor time a call is the figure to compare.
- **On the wire** a small call and its answer are 31 to 32 bytes over TCP and 39 to 40 over WebSocket; gRPC's are
  76 with grpc-go when many calls share a connection, 166 one call at a time, and 90 to 92 with grpc-js.

## RPC over local IPC

The same small call, one at a time, natively on Windows between two processes over `local://`: 90 us (p50) and
1.3 ms (p99), 8,662 calls a second, against 47 us and 0.14 ms over TCP on the same machine.

## HTTP

Allocation and time per request are in the first table. One `HTTPServer` spread over runtimes (`runtimeCount`),
answering small GETs from 256 kept-alive connections with one request in flight on each, the server held to 8
logical processors and the clients, in a process of their own, to 24 others:

| Runtimes | HTTP/1.1 requests/s | HTTP/2 requests/s | The server's processor use |
| --- | --- | --- | --- |
| one (not spread) | 152,442 (137,968-156,016) | 134,618 (127,918-142,626) | 0.95 to 1.0 cores |
| 2 | 277,369 (276,383-279,593) | 239,137 (237,281-247,208) | 1.9 to 2.0 cores |
| 4 | 488,060 (444,399-521,766) | 431,963 (389,094-479,986) | 3.5 to 3.9 cores |

A server on one runtime pays nothing for the feature.

## Reliable UDP

- **A game tick's traffic.** 200 sessions in one process, each round the server sending every session a reliable
  and a sequenced message and every client sending a reliable input: about 0.9 us of user time a datagram natively
  (the median of each run's best sample: 898 ns, 872 to 964), about 2.2 ms of kernel time a round, and nothing
  allocated. Encrypted: 2.2 us (1,953 to 2,201 ns), nothing allocated.
- **One message to many sessions.** 1 KB, reliable, to 1,000 sessions, each losing 1% of what it receives and of
  what it sends:

  | | Held per message until every peer has it | The call, per session | Allocated a round, whole process |
  | --- | --- | --- | --- |
  | native, `send` to each | 1.4 MB | 739 to 742 ns | 0 |
  | native, `broadcast(PreparedDatagram)` | 0.25 MB | 485 to 488 ns | 0 |
  | JVM, `send` to each | 1.2 MB | 557 to 584 ns | 96 KB |
  | JVM, `broadcast(PreparedDatagram)` | 0.11 MB | 388 to 430 ns | 97 KB |

  Either way the round took 175 ms until everything was acknowledged, the time loss recovery takes at 1% each way.

## What is not measured

- macOS, and Linux beyond the figures marked so.
- HashLink and Neko: their suites run, their speed was not measured.
- A real network: every figure is over loopback, without its latency, loss or bandwidth limits, except where a bench
  drops datagrams itself.
- gRPC over TLS, streaming gRPC calls, grpc-go on Linux, and gRPC in any other language.
- Other servers and libraries: no HTTP server (nginx, Go's `net/http`, Node's `http`), WebSocket library (`ws`,
  uWebSockets) or reliable UDP library (ENet, KCP, GameNetworkingSockets) was run beside CrossByte's.
- TLS handshakes a second, and WebRTC throughput and latency.
- Java 17 beyond the allocation table.

## Running them again

From the repository root, natively, with CrossByte registered as a development haxelib (see
[testing.md](testing.md)). Each program documents its arguments at the top.

**Allocation per operation.** The budget class alone, printing every figure, natively and on the JVM:

```sh
haxe ci/native-tests.hxml -D gc_bisect
CB_ONLY=AllocationBudget CB_ALLOC_REPORT=1 ./export/ci-native-tests/NativeSmokeMain.exe
haxe ci/jvm-tests.hxml -D gc_bisect
CB_ONLY=AllocationBudget CB_ALLOC_REPORT=1 java -jar export/jvm/CrossByteTests.jar
```

On Linux natively, `ci/posix-native-tests.hxml` and `export/ci-posix-native/NativeSmokeMain`.

**What a server holds for a connection.** `tests/perf/realtime/IdleMemory.hx`:

```sh
haxe -cp src -cp tests/perf/realtime -D HXCPP_M64 --macro "crossbyte._internal.macro.HostPlatform.define()" --macro "crossbyte._internal.macro.StdOverrides.use()" -main IdleMemory --cpp export/perf-rt/idle
./export/perf-rt/idle/IdleMemory server --transport tcp --count 1000
./export/perf-rt/idle/IdleMemory server --transport ws --count 1000 --message 16384 --quiet 75
./export/perf-rt/idle/IdleMemory server --transport rudp --count 1000 --encrypt
```

For a JVM server, build the same main with `--jvm` and give it the native clients with `--bots`.

**RPC beside gRPC.** `tests/perf/rpc`: CrossByte's `RpcCallBench`, the grpc-go and grpc-js benches, and `run.js`,
which runs every cell and prints the tables. It needs Go 1.25 or later, and grpc-js installed in a folder of its own:

```sh
haxe tests/perf/rpc/rpc-bench.hxml
cd tests/perf/rpc/grpc-go && go build -o ../../../../export/rpc-bench/grpcbench.exe . && cd ../../../..
npm install --prefix ../grpc-node @grpc/grpc-js@1.14.6 @grpc/proto-loader@0.8.1
node tests/perf/rpc/run.js --grpc-node ../grpc-node --systems crossbyte,crossbyte-ws,crossbyte-node,grpc-go,grpc-go-1,grpc-js
```

(Off Windows, name it `grpcbench`, without `.exe`.) Every cell is kept in `export/rpc-bench/results.jsonl`, and
`node tests/perf/rpc/run.js --summary <file>` prints a file's tables again. `grpc-go/benchpb` is generated from
`bench.proto` by `protoc` with `protoc-gen-go` and `protoc-gen-go-grpc`; it needs regenerating only if the proto
changes. Local IPC is `RpcCallBench` on its own:
`export/rpc-bench/native/RpcCallBench server --transport local --port 7`, then the same with `client --transport local
--port 7 --kind int`.

**HTTP over cores.** `tests/scaling`: `ScalingServer <port> <runtimes>` and `ScalingLoad <port> <connections>
<seconds> <h1|h2>`, pinned apart (on Windows `start /affinity FF` for the server, `start /affinity FFFFFF00` for the
load; on Linux `taskset`):

```sh
haxe --cwd tests/scaling scaling.hxml
```

**Reliable UDP.** `tests/perf/realtime/RudpPump.hx` (`sessions=200 rounds=3000 samples=3`, and `encrypt=1`) and
`RudpFanout.hx` (`mode=send` or `mode=prepared`), built as `IdleMemory` is above with their own `-main`.

The multicore sample (`samples/multicore`) shows a server spread over four runtimes answering from all of them, and
`tests/bench` and `tests/load` (see [testing.md](testing.md)) measure the hot paths and long runs at scale.
