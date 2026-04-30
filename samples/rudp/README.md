# RUDP

`rudp` is a small localhost reliable datagram sample built on
`ReliableDatagramServerSocket` and `ReliableDatagramSocket`.

It demonstrates:

- accepting a reliable UDP session
- completing the handshake
- delivering a datagram reliably
- echoing a response back to the client

Useful commands from `samples/rudp`:

```sh
aedifex task sample-rudp-check ../..
aedifex task sample-rudp-cpp ../..
```

Raw HXML entrypoints:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\rudp\RUDPSample.exe
```
