# LocalConnection

`localconnection` shows CrossByte's local named-pipe IPC surface.

The sample is built as a tiny `HostApplication` so the worker-backed IPC path
has a real CrossByte runtime to dispatch back onto.

It supports three modes:

- `demo`: starts a receiver and sender in one process and verifies delivery
- `listen`: listens on a named local connection and prints received messages
- `send`: sends a message to a listener by name

Useful commands from `samples/localconnection`:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\localconnection\LocalConnectionSample.exe demo
..\..\export\localconnection\LocalConnectionSample.exe listen
..\..\export\localconnection\LocalConnectionSample.exe send crossbyte_sample_localconnection "hello from cli" 7
```
