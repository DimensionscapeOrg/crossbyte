# CrossByte Samples

## WebSocket Echo

`websocket-echo` starts a localhost `ServerWebSocket`, connects a `WebSocket`
client, sends a message, and echoes the payload back through the public
socket-style API.

From the repository root:

```sh
aedifex task sample-websocket-echo-check <project-root>
aedifex task sample-websocket-echo-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

The runtime sample needs a native target because `WebSocket` uses
`SecureRandom` for client handshake keys.

## Socket Chat

`socket-chat` is a small TCP chat sample with a broadcast server and a console
client built directly on `ServerSocket` and `Socket`.

From the repository root:

```sh
aedifex task sample-socket-chat-check <project-root>
aedifex task sample-socket-chat-server-cpp <project-root>
aedifex task sample-socket-chat-client-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe server-cpp.hxml
haxe client-cpp.hxml
```

## RPC Greeter

`rpc-greeter` is a tiny contract-driven RPC sample that uses an in-memory
loopback connection to show the `RPCCommands` / `RPCHandler` model clearly.

From the repository root:

```sh
aedifex task sample-rpc-greeter-check <project-root>
aedifex task sample-rpc-greeter-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## LocalConnection

`localconnection` demonstrates CrossByte's low-level local named-pipe transport with
`demo`, `listen`, and `send` modes.

From the repository root:

```sh
aedifex task sample-localconnection-check <project-root>
aedifex task sample-localconnection-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## SharedChannel

`sharedchannel` demonstrates CrossByte's higher-level local message IPC API
with `demo`, `listen`, and `send` modes.

From the repository root:

```sh
aedifex task sample-sharedchannel-check <project-root>
aedifex task sample-sharedchannel-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## SharedObject

`sharedobject` demonstrates CrossByte's shared-memory IPC API with `demo`,
`write`, and `read` modes.

From the repository root:

```sh
aedifex task sample-sharedobject-check <project-root>
aedifex task sample-sharedobject-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## Simple Application

`simple-application` demonstrates the smallest primordial CrossByte app shape
with `Application`, `init`, `tick`, and clean shutdown.

From the repository root:

```sh
aedifex task sample-simple-application-check <project-root>
aedifex task sample-simple-application-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## UDP

`udp` demonstrates localhost datagram send/receive with `DatagramSocket`.

From the repository root:

```sh
aedifex task sample-udp-check <project-root>
aedifex task sample-udp-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## RUDP

`rudp` demonstrates localhost reliable datagram handshake and echo with
`ReliableDatagramServerSocket` and `ReliableDatagramSocket`.

From the repository root:

```sh
aedifex task sample-rudp-check <project-root>
aedifex task sample-rudp-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## Web Server

`web-server` starts a localhost `HTTPServer`, serves a tiny doc root, and can
either fetch itself in `demo` mode or stay up in `serve` mode.

From the repository root:

```sh
aedifex task sample-web-server-check <project-root>
aedifex task sample-web-server-cpp <project-root>
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

## Worker

`worker` demonstrates `crossbyte.sys.Worker` progress and completion events in
the smallest host-driven shape.

From the repository root:

```sh
aedifex task sample-worker-check <project-root>
aedifex task sample-worker-cpp <project-root>
```

In these examples, `<project-root>` is usually `.` when you are already in the
repository root.

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```
