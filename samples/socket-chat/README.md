# Socket Chat

`socket-chat` is a small TCP chat example built on CrossByte's `ServerSocket`
and `Socket` APIs.

It includes:

- `SocketChatServerSample` - a broadcast chat server
- `SocketChatClientSample` - a console client

Useful commands from `samples/socket-chat`:

```sh
haxe check.hxml
haxe server-cpp.hxml
haxe client-cpp.hxml
```

Server defaults to `127.0.0.1:19090` and accepts optional command-line
arguments:

```sh
../../export/socket-chat-server/SocketChatServerSample 127.0.0.1 19090
```

Client accepts `host`, `port`, and an optional nickname:

```sh
../../export/socket-chat-client/SocketChatClientSample 127.0.0.1 19090 alice
```

Client commands:

- `/nick <name>` to rename yourself
- `/who` to list connected users
- `/quit` to disconnect

Server console commands:

- `/clients` to list connected users
- `/say <message>` to broadcast a server message
- `/quit` to stop the server
