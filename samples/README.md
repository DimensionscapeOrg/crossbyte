# CrossByte Samples

## WebSocket Echo

`websocket-echo` starts a localhost `ServerWebSocket`, connects a `WebSocket`
client, sends a message, and echoes the payload back through the public
socket-style API.

From the repository root:

```sh
aedifex task sample-websocket-echo-check .
aedifex task sample-websocket-echo-cpp .
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
aedifex task sample-socket-chat-check .
aedifex task sample-socket-chat-server-cpp .
aedifex task sample-socket-chat-client-cpp .
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
aedifex task sample-rpc-greeter-check .
aedifex task sample-rpc-greeter-cpp .
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
aedifex task sample-localconnection-check .
aedifex task sample-localconnection-cpp .
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
aedifex task sample-sharedchannel-check .
aedifex task sample-sharedchannel-cpp .
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
aedifex task sample-sharedobject-check .
aedifex task sample-sharedobject-cpp .
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
aedifex task sample-simple-application-check .
aedifex task sample-simple-application-cpp .
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
aedifex task sample-udp-check .
aedifex task sample-udp-cpp .
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
aedifex task sample-rudp-check .
aedifex task sample-rudp-cpp .
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
aedifex task sample-web-server-check .
aedifex task sample-web-server-cpp .
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
aedifex task sample-worker-check .
aedifex task sample-worker-cpp .
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```
