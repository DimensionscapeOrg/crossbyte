# LocalConnection

`localconnection` shows CrossByte's low-level local named-pipe transport.

The sample is built as a tiny `HostApplication` so the worker-backed IPC path
has a real CrossByte runtime to dispatch back onto.

It supports three modes:

- `demo`: starts a listener and client in one process and verifies byte delivery
- `listen`: listens on a named local transport and prints received frames
- `send`: connects to a listener by name and writes one payload

Useful commands from `samples/localconnection`:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\localconnection\LocalConnectionSample.exe demo
..\..\export\localconnection\LocalConnectionSample.exe listen
..\..\export\localconnection\LocalConnectionSample.exe send crossbyte_sample_localconnection "hello from cli" 7
```
