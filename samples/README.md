# CrossByte Samples

## WebSocket Echo

`websocket-echo` starts a localhost `ServerWebSocket`, connects a `WebSocket`
client, sends a message, and echoes the payload back through the public
socket-style API.

Useful commands from `samples/websocket-echo`:

```sh
haxe check.hxml
haxe cpp.hxml
```

The runtime sample needs a native target because `WebSocket` uses
`SecureRandom` for client handshake keys.

## Socket Chat

`socket-chat` is a small TCP chat sample with a broadcast server and a console
client built directly on `ServerSocket` and `Socket`.

Useful commands from `samples/socket-chat`:

```sh
haxe check.hxml
haxe server-cpp.hxml
haxe client-cpp.hxml
```

## RPC Greeter

`rpc-greeter` is a tiny contract-driven RPC sample that uses an in-memory
loopback connection to show the `RPCCommands` / `RPCHandler` model clearly.

Useful commands from `samples/rpc-greeter`:

```sh
haxe check.hxml
haxe cpp.hxml
```

## LocalConnection

`localconnection` demonstrates CrossByte's local named-pipe IPC API with
`demo`, `listen`, and `send` modes.

Useful commands from `samples/localconnection`:

```sh
haxe check.hxml
haxe cpp.hxml
```

## SharedObject

`sharedobject` demonstrates CrossByte's shared-memory IPC API with `demo`,
`write`, and `read` modes.

Useful commands from `samples/sharedobject`:

```sh
haxe check.hxml
haxe cpp.hxml
```

## Simple Application

`simple-application` demonstrates the smallest primordial CrossByte app shape
with `Application`, `init`, `tick`, and clean shutdown.

Useful commands from `samples/simple-application`:

```sh
haxe check.hxml
haxe cpp.hxml
```

## UDP

`udp` demonstrates localhost datagram send/receive with `DatagramSocket`.

Useful commands from `samples/udp`:

```sh
haxe check.hxml
haxe cpp.hxml
```

## RUDP

`rudp` demonstrates localhost reliable datagram handshake and echo with
`ReliableDatagramServerSocket` and `ReliableDatagramSocket`.

Useful commands from `samples/rudp`:

```sh
haxe check.hxml
haxe cpp.hxml
```
