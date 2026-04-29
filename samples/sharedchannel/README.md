# SharedChannel

`sharedchannel` shows CrossByte's higher-level local message IPC surface.

The sample is built as a tiny `HostApplication` so the worker-backed IPC path
has a real CrossByte runtime to dispatch back onto.

It supports three modes:

- `demo`: starts a receiver and sender in one process and verifies delivery
- `listen`: listens on a named shared channel and prints received messages
- `send`: sends a message to a listener by name

Useful commands from `samples/sharedchannel`:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\sharedchannel\SharedChannelSample.exe demo
..\..\export\sharedchannel\SharedChannelSample.exe listen
..\..\export\sharedchannel\SharedChannelSample.exe send crossbyte_sample_sharedchannel "hello from cli" 7
```
