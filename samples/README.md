# CrossByte samples

Small programs, each in a folder of its own, that build natively. Several check what they did and exit 0 only when it
worked; CI builds every sample and runs those.

| Sample | What it shows |
| --- | --- |
| [`simple-application`](simple-application/README.md) | the smallest application: `Application`, `init`, `TickEvent` and a clean shutdown |
| [`socket-chat`](socket-chat/README.md) | a TCP chat server and console client on `ServerSocket` and `Socket` |
| [`web-server`](web-server/README.md) | an `HTTPServer` serving a small document root, fetching itself with `URLLoader` |
| [`http2`](http2/README.md) | one `HTTPServer` port serving HTTP/1.1 and HTTP/2, and two requests sharing one HTTP/2 connection |
| [`multicore`](multicore/README.md) | an `HTTPServer` spread over four runtimes, and middleware that is safe on all of them |
| `websocket-echo` | a `ServerWebSocket` and a `WebSocket` client echoing a message |
| [`udp`](udp/README.md) | sending and receiving datagrams with `DatagramSocket` |
| [`rudp`](rudp/README.md) | a reliable UDP session admitted on a ticket, and a message echoed over it |
| [`rpc-greeter`](rpc-greeter/README.md) | a contract-driven RPC pair: one-way calls, typed responses, a structure with an enum and compact numbers |
| [`arena`](arena/README.md) | an authoritative game server and sixteen bots built from the game-server primitives, checking every snapshot |
| [`localconnection`](localconnection/README.md) | `LocalConnection`, the low-level local named-pipe transport |
| [`sharedchannel`](sharedchannel/README.md) | `SharedChannel`, local message passing between processes |
| [`sharedobject`](sharedobject/README.md) | `SharedObject`, shared memory between processes |
| [`worker`](worker/README.md) | `crossbyte.sys.Worker` progress and completion events |
| [`windows-service`](windows-service/README.md) | an `HTTPServer` that drains its requests when the Windows service manager stops it |

`websocket-echo` needs a native target, since a `WebSocket` client needs a secure random source for its handshake
keys.

## Building a sample

From the repository root, with the `aedifex` task runner:

```sh
aedifex task sample-<name>-check .
aedifex task sample-<name>-cpp .
```

`-check` type-checks the sample and `-cpp` builds it. `socket-chat` has `sample-socket-chat-server-cpp` and
`sample-socket-chat-client-cpp` in place of `-cpp`.

Or from the sample's folder, with Haxe alone:

```sh
haxe check.hxml
haxe cpp.hxml
```

The executable lands in `export/<name>/` under the repository root (`export/socket-chat-server/` and
`export/socket-chat-client/` for the chat).
