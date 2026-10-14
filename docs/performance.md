# Performance

What CrossByte costs, measured: the bytes an operation allocates, what a server holds for each connection, an RPC
call's latency, processor time and bytes on the wire beside gRPC's, replicated game state beside Yggdrasil's codec and
protobuf, and how an HTTP server scales over cores. Every
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
- **On the wire** a small call and its answer are 31 to 32 bytes over TCP and 39 to 40 over WebSocket (the byte
  between them is the request id, a varuint, which takes a third byte from a session's 16,384th call); gRPC's are
  76 with grpc-go when many calls share a connection, 166 one call at a time, and 90 to 92 with grpc-js.

## Maps beside gRPC

The same benches, the same way (2026-10-13), with a map each way: CrossByte's `Map<String, Int>` and
`Map<String, String>` against protobuf's `map<string, int32>` and `map<string, string>`, of 8 entries and of 256. The
keys are `"key0"` up, the values their number, or `"value"` and their number. Each server answers with the map that
arrived, so it reads a map and writes one again, and each client sends one map made once and reads the map that comes
back. CrossByte writes a map's entries in the order of their keys, which it sorts each time; grpc-go and grpc-js write
them in their maps' own order, with no sort.

| System | Map | Connections x in flight | Calls/s | p50 | p99 | Server CPU a call | Client CPU a call | Bytes a call, out + back |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CrossByte, native, TCP | `String` to `Int`, 8 | 1 x 1 | 14,683 (13,384-15,189) | 52 us | 143 us | 37 us | 37 us | 84 + 84 |
| CrossByte, native, TCP | `String` to `Int`, 8 | 8 x 32 | 958,614 (842,527-1,034,266) | 181 us | 1,910 us | 0.88 us | 0.91 us | 85 + 85 |
| CrossByte, native, TCP | `String` to `Int`, 256 | 1 x 1 | 7,504 (7,144-8,152) | 106 us | 1,419 us | 66 us | 67 us | 2,719 + 2,719 |
| CrossByte, native, TCP | `String` to `Int`, 256 | 8 x 32 | 41,641 (37,951-44,187) | 6,022 us | 12,285 us | 23 us | 25 us | 2,729 + 2,728 |
| CrossByte, native, TCP | `String` to `String`, 8 | 1 x 1 | 13,943 (13,029-15,084) | 54 us | 196 us | 39 us | 39 us | 108 + 108 |
| CrossByte, native, TCP | `String` to `String`, 8 | 8 x 32 | 637,211 (576,675-771,900) | 291 us | 2,151 us | 1.2 us | 1.3 us | 109 + 109 |
| CrossByte, native, TCP | `String` to `String`, 256 | 1 x 1 | 6,977 (6,718-7,652) | 110 us | 1,447 us | 70 us | 72 us | 3,890 + 3,890 |
| CrossByte, native, TCP | `String` to `String`, 256 | 8 x 32 | 33,567 (32,086-37,585) | 7,341 us | 15,275 us | 29 us | 31 us | 3,906 + 3,905 |
| CrossByte, Node, TCP | `String` to `Int`, 8 | 1 x 1 | 10,122 (9,733-10,983) | 92 us | 164 us | 59 us | 61 us | 84 + 84 |
| CrossByte, Node, TCP | `String` to `Int`, 8 | 8 x 32 | 429,561 (405,455-492,741) | 559 us | 974 us | 2.2 us | 2.3 us | 85 + 85 |
| CrossByte, Node, TCP | `String` to `Int`, 256 | 1 x 1 | 4,758 (4,494-5,062) | 200 us | 334 us | 118 us | 125 us | 2,720 + 2,720 |
| CrossByte, Node, TCP | `String` to `Int`, 256 | 8 x 32 | 17,857 (17,072-20,578) | 13,835 us | 19,372 us | 52 us | 57 us | 2,737 + 2,737 |
| CrossByte, Node, TCP | `String` to `String`, 8 | 1 x 1 | 9,915 (9,735-10,679) | 96 us | 167 us | 61 us | 63 us | 108 + 108 |
| CrossByte, Node, TCP | `String` to `String`, 8 | 8 x 32 | 343,760 (325,315-384,890) | 696 us | 1,187 us | 2.8 us | 2.9 us | 109 + 109 |
| CrossByte, Node, TCP | `String` to `String`, 256 | 1 x 1 | 3,959 (3,736-4,137) | 244 us | 408 us | 143 us | 148 us | 3,890 + 3,890 |
| CrossByte, Node, TCP | `String` to `String`, 256 | 8 x 32 | 14,168 (11,580-14,292) | 17,897 us | 24,569 us | 68 us | 72 us | 3,925 + 3,924 |
| grpc-go | `string` to `int32`, 8 | 1 x 1 | 3,185 (2,038-3,423) | 124 us | 9,128 us | 160 us | 162 us | 157 + 163 |
| grpc-go | `string` to `int32`, 8 | 8 x 32 | 173,291 (156,185-192,210) | 1,211 us | 4,301 us | 43 us | 51 us | 112 + 118 |
| grpc-go | `string` to `int32`, 256 | 1 x 1 | 3,459 (3,142-3,817) | 253 us | 655 us | 335 us | 357 us | 3,167 + 3,173 |
| grpc-go | `string` to `int32`, 256 | 8 x 32 | 28,606 (28,229-31,653) | 8,268 us | 23,152 us | 316 us | 291 us | 3,124 + 3,130 |
| grpc-go | `string` to `string`, 8 | 1 x 1 | 2,737 (2,548-2,778) | 122 us | 9,128 us | 159 us | 160 us | 205 + 211 |
| grpc-go | `string` to `string`, 8 | 8 x 32 | 174,236 (167,308-182,473) | 1,211 us | 4,134 us | 46 us | 52 us | 160 + 166 |
| grpc-go | `string` to `string`, 256 | 1 x 1 | 3,017 (3,010-3,377) | 280 us | 768 us | 386 us | 400 us | 4,977 + 4,983 |
| grpc-go | `string` to `string`, 256 | 8 x 32 | 27,911 (24,816-29,164) | 8,433 us | 25,060 us | 360 us | 322 us | 4,934 + 4,940 |
| grpc-go, `GOMAXPROCS=1` | `string` to `int32`, 8 | 1 x 1 | 7,640 (7,598-7,880) | 127 us | 221 us | 78 us | 77 us | 157 + 163 |
| grpc-go, `GOMAXPROCS=1` | `string` to `int32`, 8 | 8 x 32 | 73,940 (73,029-82,582) | 3,325 us | 7,056 us | 10 us | 13 us | 112 + 118 |
| grpc-go, `GOMAXPROCS=1` | `string` to `int32`, 256 | 1 x 1 | 3,771 (3,682-3,885) | 248 us | 582 us | 148 us | 148 us | 3,167 + 3,173 |
| grpc-go, `GOMAXPROCS=1` | `string` to `int32`, 256 | 8 x 32 | 9,610 (9,071-10,207) | 25,060 us | 57,570 us | 94 us | 105 us | 3,122 + 3,128 |
| grpc-go, `GOMAXPROCS=1` | `string` to `string`, 8 | 1 x 1 | 7,828 (7,551-8,078) | 122 us | 225 us | 76 us | 75 us | 205 + 211 |
| grpc-go, `GOMAXPROCS=1` | `string` to `string`, 8 | 8 x 32 | 75,370 (63,304-81,221) | 3,260 us | 6,918 us | 9.7 us | 12 us | 160 + 166 |
| grpc-go, `GOMAXPROCS=1` | `string` to `string`, 256 | 1 x 1 | 3,507 (3,303-3,665) | 264 us | 618 us | 159 us | 158 us | 4,977 + 4,983 |
| grpc-go, `GOMAXPROCS=1` | `string` to `string`, 256 | 8 x 32 | 8,793 (7,320-9,245) | 27,669 us | 67,452 us | 106 us | 115 us | 4,932 + 4,938 |
| grpc-js, Node | `string` to `int32`, 8 | 1 x 1 | 3,685 (3,616-3,785) | 253 us | 441 us | 157 us | 209 us | 127 + 119 |
| grpc-js, Node | `string` to `int32`, 8 | 8 x 32 | 20,830 (19,914-23,452) | 10,695 us | 20,969 us | 33 us | 68 us | 128 + 120 |
| grpc-js, Node | `string` to `int32`, 256 | 1 x 1 | 2,106 (1,962-2,156) | 450 us | 768 us | 265 us | 345 us | 3,139 + 3,131 |
| grpc-js, Node | `string` to `int32`, 256 | 8 x 32 | 6,829 (6,056-7,417) | 36,508 us | 55,334 us | 147 us | 185 us | 3,154 + 3,145 |
| grpc-js, Node | `string` to `string`, 8 | 1 x 1 | 3,733 (3,600-3,899) | 253 us | 441 us | 154 us | 213 us | 175 + 167 |
| grpc-js, Node | `string` to `string`, 8 | 8 x 32 | 22,597 (19,369-23,855) | 10,078 us | 19,760 us | 32 us | 63 us | 176 + 168 |
| grpc-js, Node | `string` to `string`, 256 | 1 x 1 | 2,021 (1,915-2,135) | 468 us | 738 us | 275 us | 366 us | 4,950 + 4,942 |
| grpc-js, Node | `string` to `string`, 256 | 8 x 32 | 5,923 (5,199-6,281) | 43,631 us | 63,562 us | 187 us | 224 us | 4,972 + 4,961 |

Reading it:

- **Bytes on the wire.** A map of 8 `String` to `Int` entries and its answer took 168 to 170 bytes over TCP, where
  grpc-go took 229 to 230 with calls sharing a connection (320 one at a time) and grpc-js 246 to 247; of 256 entries, 5,439 to
  5,458 against 6,250 to 6,340 and 6,270 to 6,299. `String` to `String`: 216 to 218 against 325 to 416 and 342 to
  344 for 8 entries, and 7,779 to 7,850 against 9,870 to 9,960 and 9,892 to 9,933 for 256. An entry is its key's
  length, its UTF-8 and its value (an `Int` four bytes); protobuf's carries a tag and a length for the entry and a
  tag for each of its key and value too.
- **Processor time a call,** many calls in flight: natively the server spent 0.88 us on a call of 8 `String` to
  `Int` entries and 23 us on one of 256, against grpc-go's 10 and 94 us on one thread (43 and 316 us on all 32) and
  grpc-js's 33 and 147 us; with `String` values 1.2 and 29 us against 9.7 and 106 (46 and 360) and 32 and 187. On
  Node, CrossByte's server spent 2.2 and 52 us, and 2.8 and 68 us. One call at a time, where a process's time
  includes what it spends between calls, natively 37 to 70 us against grpc-go's 76 to 159 on one thread and
  grpc-js's 154 to 275; on Node 59 to 143 us.
- **Allocation.** Natively a call of 8 `String` to `Int` entries and its answer, both ends in one process, allocates
  1,776 bytes, on the JVM 1,760: each side's map as it is read, with its keys, and each side's sorted copy of the
  keys it writes; no value is boxed natively. Of 256 entries, 63,648 bytes on the JVM (natively too many for the
  allocation meter to read by its method); `AllocationBudgetTest` holds both.
- **Sorting** is what the canonical order costs. In `tests/bench`, natively the keys of a map of 256 are copied and
  sorted in 11 us, and a call of 256 entries and its answer, both ends in one process, takes 43 us, two sorts of it
  (each side sorts what it writes): half; on the JVM 5.8 us of 29. A map of 8 is sorted in 81 ns, and its call and
  answer take 0.87 us natively.

## Replication beside Yggdrasil's codec and protobuf

Stellar's hot messages (2026-10-14), per observer: what a game server sends each player every tick, and what the
player sends back. Driven by Stellar's own simulation (`stellar-shared`) with bots: 17 ships, each the observer of
the other 16, at 30 Hz, 1,740 ticks measured after 60 warm ones, the same recorded ticks for every system. Each
message carries the observer's own ship (13 fields at full precision) and the 16 other ships (8 fields), patched
against the tick its client acknowledged two before. The bots turn most ticks and thrust most of the time, so most
ships change five or six of their eight fields against that base.

- **CrossByte, typed, A:** `matchState(tick:VarUInt, base:VarUInt, own:RPCPatch<OwnShip>, others:RPCMapPatch<OtherShip>)`,
  the other ships with today's field types (`Float32` positions, velocities and heat, `UInt16` aim, `UInt8`
  controls, `Bool`).
- **CrossByte, typed, B:** the same with the other ships quantized (`@:quantize(-8192, 8192, 16)` positions,
  `(-1024, 1024, 16)` velocities, `(0, ShipRules.MAX_ENGINE_HEAT, 10)` heat, `@:range(0, 63)` controls).
- **Yggdrasil's codec today:** each ship's payload encoded once a tick (`ShipStateCodec`), each observer's snapshot
  made of them and its own ship's, its delta against the acknowledged tick's snapshot computed and encoded
  (`DeltaCompute`, `DeltaCodec`), sent as `spaceDelta(spaceId:Int, delta:Bytes)`; the client decodes it, applies it
  (`DeltaApply`) and decodes each changed ship.
- **protobuf:** the same patches as proto3 `optional` fields, the other ships in a `map<int32, ShipPatch>`
  (`tests/perf/replication/replication.proto`), made and marshalled, then unmarshalled and applied into the client's
  frames, with grpc-go's runtime (`google.golang.org/protobuf` 1.36.12) and grpc-js's (protobufjs 7.6.6, as
  `@grpc/proto-loader` uses it). On a gRPC stream each message also takes a 5-byte prefix and a 9-byte HTTP/2 DATA
  frame header.

Made is the observer's message diffed and written into a connection that keeps it (for CrossByte the whole call:
frame, stub and session); read is that message handed to its client's session, dispatched, and applied into the
client's ring of frames. Both ends ran in one process; one thread. For protobuf, the codec and the diffs and
applies alone, with no transport.

| System | Target | Bytes a message | On the wire | Made | Read | Allocated a message, both ends |
| --- | --- | --- | --- | --- | --- | --- |
| CrossByte, A | native | 437 | 446 over TCP | 0.82 us (0.81-0.83) | 0.82 us (0.80-0.82) | 0 |
| CrossByte, A | JVM | 437 | 446 | 0.70 us (0.67-0.74) | 0.66 us (0.62-0.72) | 0 |
| CrossByte, A | Node | 437 | 446 | 0.90 us (0.86-0.96) | 0.90 us (0.88-0.95) | not read |
| CrossByte, B | native | 276 | 285 | 1.21 us (1.21-1.23) | 1.01 us (1.01-1.02) | 0 |
| CrossByte, B | JVM | 276 | 285 | 0.93 us (0.92-0.99) | 0.67 us (0.67-0.70) | 0 |
| CrossByte, B | Node | 276 | 285 | 1.25 us (1.18-1.44) | 1.00 us (0.99-1.01) | not read |
| Yggdrasil's codec | native | 546 | 555 | 5.59 us (5.58-5.64) | 6.27 us (6.09-6.34) | too much for the meter |
| Yggdrasil's codec | JVM | 546 | 555 | 3.89 us (3.77-3.97) | 2.30 us (2.25-2.32) | 18,783 B |
| Yggdrasil's codec | Node | 546 | 555 | 17.5 us (17.0-18.1) | 24.3 us (24.0-24.8) | not read |
| protobuf, grpc-go's runtime | Go | 613 | 627 on a gRPC stream | 3.68 us (3.45-3.78) | 3.45 us (3.37-3.59) | 7,291 B |
| protobuf, grpc-js's runtime | Node | 613 | 627 | 9.77 us (9.52-9.99) | 5.43 us (5.33-5.60) | not read |

The design's shapes, bytes alone (`ReplicationBench --shapes`, `protogo --shapes`): the other ship with 3 of its 8
fields changed (`aimSteps`, `x`, `y`), the own ship with 10 of its 13, and a tick of both:

| Shape | CrossByte A | CrossByte B | Yggdrasil's codec | protobuf |
| --- | --- | --- | --- | --- |
| another ship, 3 of 8 changed, as a map entry | 12 | 8 | 28 | 20 |
| the own ship, 10 of 13 changed | 68 | 68 | 82 | 79 |
| a tick: the own ship and 16 others of 3 changed, arguments | 271 | 207 | 548 | 409 |
| the same on the wire | 280 over TCP | 216 | 557 | 423 on a gRPC stream |
| one input (seq 1,000) | 5 | 5 | 11 | 9 |
| the last four inputs (ack 36,000, newest 1,000) | 26 | 17 | 44 (four calls) | 51 |

Inputs over the recorded ticks, each a one-way call made and read (for protobuf, marshalled and unmarshalled): one
input natively 112 ns (A) and 109 ns (B), the last four 134 and 124 ns, against Yggdrasil's 228 ns for one and
912 ns for four calls; grpc-go's runtime 49 and 447 ns, grpc-js's 228 and 733 ns, codec alone.

Reading it:

- **Bytes.** Over the bots' ticks, B is 51% of Yggdrasil's codec and 45% of protobuf's, A 80% and 71%; on the
  design's tick (3 of 8 fields changed) B is 39% of Yggdrasil's and 51% of protobuf's. A changed field costs a mask bit
  and its value, where Yggdrasil sends every changed ship's whole 24-byte payload in a 4-byte entry, and protobuf a
  tag for each field and a tag and a length for each entry and its value. An id close to the one before costs a byte.
- **Processor time.** CrossByte makes a message in 0.82 us natively (B 1.21) and reads it in 0.82 us (1.01), 4.6 to
  7.6 times less than Yggdrasil's codec and 3 to 4.5 times less than grpc-go's runtime, which allocate 18.8 KB (JVM)
  and 7.3 KB a message where CrossByte allocates nothing. Quantizing costs B about 0.4 us a message to make and
  0.2 us to read, natively: each changed field's step, for the comparison and for the bits.
- **Allocation.** Nothing at either end once the patches, their pools and the client's frames have grown, natively
  and on the JVM (`AllocationBudgetTest`, "a tick of patches"). Natively a client frame's `IntMap` makes a node for a
  key it did not hold, 56 bytes: a tick with one entity entering and one leaving the view allocates 64 bytes.

**Two sections, or one bit stream.** The design writes a structure's bits in a section of whole bytes and its other
fields after, where Quake 3, Source and Unreal write one bit stream. Written by hand as one stream with `BitWriter`
(every changed field in bits, `aimSteps` among them, padded once), B's other ships take 204.5 bytes a message against
213.3, 4% fewer, and cost 1.37 us to write and 1.61 us to read natively against 0.44 and 0.91 us (on the JVM 0.74
and 1.07 against 0.25 and 0.56; Node 1.23 and 1.51 against 0.59 and 0.84). Two sections stay; a field that should be
in the bits takes `@:range` or `@:quantize`.

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

The map calls are kinds of their own, `--kinds intmap8,intmap256,strmap8,strmap256` (the default is `small,4KB`):

```sh
node tests/perf/rpc/run.js --grpc-node ../grpc-node --systems crossbyte,crossbyte-node,grpc-go,grpc-go-1,grpc-js --kinds intmap8,intmap256,strmap8,strmap256
```

(Off Windows, name it `grpcbench`, without `.exe`.) Every cell is kept in `export/rpc-bench/results.jsonl`, and
`node tests/perf/rpc/run.js --summary <file>` prints a file's tables again. `grpc-go/benchpb` is generated from
`bench.proto` by `protoc` with `protoc-gen-go` and `protoc-gen-go-grpc`; it needs regenerating only if the proto
changes. Local IPC is `RpcCallBench` on its own:
`export/rpc-bench/native/RpcCallBench server --transport local --port 7`, then the same with `client --transport local
--port 7 --kind int`.

**Replication.** `tests/perf/replication`: `ReplicationBench` (natively, on the JVM and on Node; it needs Yggdrasil
and `stellar-shared` registered as development haxelibs), the protobuf benches (`proto-go` with Go 1.25 or later,
`proto-js` with the protobufjs grpc-js installs), and `run.js`, which records the ticks once, runs every cell and
prints the medians:

```sh
haxe tests/perf/replication/replication.hxml
cd tests/perf/replication/proto-go && go build -o ../../../../export/replication/protogo.exe . && cd ../../../..
node tests/perf/replication/run.js --grpc-node ../grpc-node
./export/replication/native/ReplicationBench.exe --shapes
./export/replication/protogo.exe --shapes
```

`proto-go/replicationpb` is generated from `replication.proto` by `protoc` with `protoc-gen-go`.

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
