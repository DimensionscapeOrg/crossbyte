# UDP

`udp` is a tiny localhost datagram sample built on `DatagramSocket`.

It demonstrates:

- binding a UDP receiver
- sending a datagram to a local endpoint
- receiving `DatagramSocketDataEvent.DATA` through a host-driven CrossByte runtime

Useful commands from `samples/udp`:

```sh
haxe check.hxml
haxe cpp.hxml
..\..\export\udp\UDPSample.exe
```
