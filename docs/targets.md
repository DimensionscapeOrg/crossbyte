# Targets

CrossByte builds natively through hxcpp, and for the JVM, Node.js, HashLink, Neko and the Haxe interpreter. Native
builds have every feature. What a target cannot do, its class says at the member, usually through `isSupported` or
`isAvailable()`.

## Native (hxcpp)

Windows, Linux and macOS. Native builds need the `production` branch of the
[`dimensionscape/hxcpp`](https://github.com/dimensionscape/hxcpp) fork:

```sh
haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production
```

Only native builds have IPC (`LocalConnection`, `SharedChannel`, `SharedObject`), WebRTC (DTLS needs mbedTLS),
SQLite, PostgreSQL through libpq, and the libsodium, BLAKE3 and mbedTLS crypto. A native process can hold about 2 GB
of objects unless built with `-D HXCPP_GC_BIG_BLOCKS`; see [runtime.md](runtime.md#memory-and-the-native-collector).

## JVM

Each runtime is a thread, and they run at once. MySQL goes through Connector/J on the class path, without the TLS or
limit settings of the native client. Reliable UDP encryption uses CrossByte's own ChaCha20-Poly1305, since Java 8
has none. ALPN, and so HTTP/2 over TLS, works natively and on the jvm only.

## Node.js

Needs `hxnodejs`. Every runtime shares Node's one thread, so a server spread over runtimes is refused: run several
processes instead (Node's `cluster`). `Argon2id` needs Node 24.7 or later. There are no database clients, since a
blocking driver cannot run there. A socket keeps its buffers' storage when idle.

## The interpreter

Runtimes take turns rather than run at once, so a spread server is served correctly and no faster. There is no UDP
(`DatagramSocket.isSupported` is false), no secure random source, and no child processes: `NativeProcess` is not
supported, since the interpreter's process calls hold every thread while they wait.

## HashLink and Neko

Both build and run the test suite on Windows and Linux.

**HashLink 1.13 or later, and say so.** Haxe 4.3 assumes HashLink 1.12 unless told otherwise, and
`crossbyte.utils.Random` uses `haxe.atomic`, which does not compile for anything older: the build stops inside the
standard library with "Atomic operations require HL 1.13+". Pass the version you run on:

```sh
haxe -lib crossbyte -D hl-ver=1.13.0 -main Main --hl main.hl
```

**The `.hdll` files, next to `hl`.** HashLink resolves every native a program was compiled with when it loads, not
when one is called, so a missing library stops the program before `main`. On Windows it says so in a dialog box,
which nobody will click on a service or a build machine. Which ones a program needs depends on what it compiles in:

| library | needed by |
| --- | --- |
| `ssl.hdll` | anything that uses the network, TLS or not: every socket type reaches `sys.ssl` |
| `fmt.hdll` | `haxe.crypto.Md5` and `Sha1` (the WebSocket handshake, TURN credentials) and `haxe.zip` |
| `sqlite.hdll` | `SQLiteConnection` |
| `mysql.hdll` | `MySQLConnection` |

The HashLink release for Windows ships all four. A Linux build from source makes them with
`make libhl hl fmt ssl sqlite mysql`, given mbedTLS, zlib, libpng, libturbojpeg, libvorbis and SQLite's headers. A
library a program never calls can be skipped with `HL_DISABLED_LIBS=sqlite,mysql` (HashLink 1.14): its functions then
throw when called rather than stopping the load.

**What is not there.** Neither target has a secure random source, so `SecureRandom.isSupported` is false and
everything that needs one refuses, saying so: `BCrypt.hash`, PKCE, WebSocket clients, STUN, TURN, ICE and WebRTC.
Both are IPv4 only. IPC and the libsodium, BLAKE3 and mbedTLS crypto are native only, and ALPN (so HTTP/2 over TLS)
is native or jvm.

A datagram socket's buffers cannot be sized (`DatagramSocket.bufferSizeSupported` is false: they read 0, and
setting them throws), so on macOS neither target sends a datagram past 9,216 bytes, the send buffer it starts with.
A datagram refused for its size is named so only past 65,527 bytes, since both report every failed send alike.

On Linux, HashLink polls its sockets through `select`, which cannot watch a descriptor numbered 1024 or above, and
HashLink has no poll natives to move to: a server there fails its polling once that many descriptors are open. Neko
polls through its own natives and is not held to it.

Neko's threads run at once but contend for its allocator: a server spread over runtimes answered 1.4 times as many
requests on two runtimes as on one, and no more on four.

**Neko's numbers and clock.** An `Int` there is 31 bits, and `Array.sort` is a native merge sort that takes a
comparator's answer too large for one as "less", so a comparator written as a subtraction of large values sorts
wrongly there; answer -1, 0 or 1. On Windows, `haxe.Timer.stamp()` is the time of day to the millisecond, moving once
a system tick, so two readings a few microseconds apart are usually equal.
