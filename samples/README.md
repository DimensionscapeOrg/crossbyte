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
