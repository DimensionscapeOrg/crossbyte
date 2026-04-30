# SharedObject

`sharedobject` shows CrossByte's shared-memory IPC surface.

It supports three modes:

- `demo`: opens the same shared region twice, mutates it from both sides, and clears it
- `write`: writes a payload into a named shared region
- `read`: reads the current payload from a named shared region

Useful commands from `samples/sharedobject`:

```sh
aedifex task sample-sharedobject-check ../..
aedifex task sample-sharedobject-cpp ../..
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\sharedobject\SharedObjectSample.exe demo
..\..\export\sharedobject\SharedObjectSample.exe write crossbyte_sample_sharedobject "hello from cli" 7
..\..\export\sharedobject\SharedObjectSample.exe read crossbyte_sample_sharedobject
```
