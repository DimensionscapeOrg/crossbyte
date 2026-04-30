# RPC Greeter

`rpc-greeter` is a small, contract-driven RPC sample.

It demonstrates:

- a shared contract interface
- generated command stubs via `@:rpcContract(...)`
- a handler that implements the shared contract directly
- one-way RPC calls
- typed `RPCResponse<T>` results

Useful commands from `samples/rpc-greeter`:

```sh
aedifex task sample-rpc-greeter-check ../..
aedifex task sample-rpc-greeter-cpp ../..
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
```

The sample uses an in-memory loopback `INetConnection` so it focuses on the RPC
surface itself. The same command/handler pattern can be bound to real
`NetConnection` transports in application code.
