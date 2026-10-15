# Targets

CrossByte builds natively through hxcpp, and for the JVM, Node.js, HashLink, Neko and the Haxe interpreter; some of
its classes build for PHP. Native builds have every feature. What a target cannot do, its class says at the member,
usually through `isSupported`.

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

A TCP, UDP or reliable UDP message allocates nothing on a runtime's side, under Java 8 and from Java 11, but for one
thing in the JDK: its selector boxes the descriptor of each socket it finds ready once the number is past 127, as a
busy server's all are, 16 bytes each time. HotSpot's `-XX:AutoBoxCacheMax=65536` keeps those boxes made once.

On Windows, from Java 16, a connect to a loopback address that Windows refuses fails at once: nothing listening, or
a listener whose queue is full. Natively and on Java 8, Windows tries such a connect again for two seconds, so one to
a local server too busy to accept usually gets in once it catches up; from Java 16 it gets an `ioError` instead.

## Node.js

Needs `hxnodejs`. Every runtime shares Node's one thread, so a server spread over runtimes is refused: run several
processes instead (Node's `cluster`). `Argon2id` needs Node 24.7 or later. There are no database clients, since a
blocking driver cannot run there. A socket keeps its buffers' storage when idle.

## Browsers

A plain `--js` build, without `hxnodejs`, runs in a page. Make the application with `Application`, as on any other
target; the runtime runs on the page's own event loop. A page connects and cannot listen: a `Socket` is the page's
WebSocket, so `NetConnection` takes `ws://` and `wss://` (and `tcp://`, the same thing), and its server is a
`ServerWebSocket` or a `NetHost` made from a `ws://` or `wss://` URI. RPC, timers and events work as
elsewhere. Files, UDP, reliable UDP, IPC, threads and databases are not there.

## PHP

Some classes are built for PHP code to use, and these are tested on PHP 8 (`ci/php-tests.hxml`): SQLite through
PHP's `sqlite3` extension (`open()` only; see [data.md](data.md#sqlite)), `BCrypt` through PHP's own
`password_hash` and `password_verify`, `SecureRandom`, HMAC-SHA256, JWTs (`JWT`, `JWKSet`), and `Ed25519`, EdDSA
tokens (`JWTSigner.EdDSA`) and `Argon2id` through PHP's sodium extension, and the key/value store in memory
and in SQLite (`MemoryKVStore`, `SQLiteKVStore`; see [data.md](data.md#a-keyvalue-store)). PostgreSQL goes through PDO. SQLite needs
`extension=sqlite3` in `php.ini`, and Ed25519 and Argon2id `extension=sodium`. PHP has no threads, so nothing that
needs one is there.

RPC is there too, without sockets: contracts and handlers build as anywhere, the codec (`RPCCodecs`, `RPCPatch`,
`RPCMapPatch`) writes and reads the same bytes as every other target (and `KVCodecs.rpc` keeps a structure in the
key/value store in them), and a session runs over an `INetConnection`
that is not a socket, such as one of your own carrying frames however the application does. There are no sockets:
`NetConnection` and `NetHost` cannot open TCP, WebSocket or UDP, and `ServerSocket.isSupported` and
`DatagramSocket.isSupported` are false.

**An `Int` is 64 bits.** On PHP a Haxe `Int` is PHP's own integer, which does not wrap where a 32-bit one does:
`0x7FFFFFFF + 1` is 2147483648 there. CrossByte's hashes, random numbers, `ByteArray`, `BitWriter` and `BitReader`,
and RPC wrap where a 32-bit `Int` would, so they give the numbers and bytes every target does; arithmetic of your own
does not.

## The interpreter

Runtimes take turns rather than run at once, so a spread server is served correctly and no faster. There is no UDP
(`DatagramSocket.isSupported` is false), no secure random source, and no child processes: `NativeProcess` is not
supported, since the interpreter's process calls hold every thread while they wait.

**A `Float` that holds an `Int`.** The interpreter and Neko keep a `Float` given an `Int` (`var total:Float = 0`, or
an `Int` passed for a `Float` argument) an `Int` at run time, and add two of them in 32 bits: two billion plus two
billion is -294,967,296. Only a number written as a class field's initialiser (`var sent:Float = 0;`) is converted.
Start a total from a float literal (`0.0`). `+ 0.0` and `* 1.0` convert only a value typed `Int`: on a `Float` the compiler drops them, so convert
one with `/ 1`.

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

**Very wide RPC structures, on neko.** Neko's loader limits the stack one function may use, and refuses the whole
program when one function exceeds it, before `main` runs. The readers RPC generates for an `RPCStruct` grow with its
fields, more with each optional one: a structure of forty fields, twenty of them optional, is past the limit. Split
one that wide into nested structures. Every other target takes it.

**Half a surrogate pair, on HashLink.** A string can hold half of a surrogate pair on its own (a string cut in the
middle of an emoji does). A `ByteArray` writes one as U+FFFD, as every target does, and so do HTTP text responses,
which go through one. Everything else that turns text into UTF-8 there (WebSocket and data channel text, RPC string
values, JWTs, `FileStream`'s text writes, an HTTP client's text body) uses HashLink's own encoder, which takes the
character after a lone half into it, so that character is lost; only a lone half at the very end of a string is
caught. Finding them first would cost every string a pass, half again the time a long one takes to encode, so on
HashLink keep text that could hold one well formed before it reaches those: pair it, or replace the lone half with
U+FFFD.

**A listener kept as another function type, on HashLink.** A function passed where another function type is wanted
is wrapped there, and a function wrapped twice is not the one wrapped once. So a listener added as it was made and
removed through a copy kept as another type is not found, and stays: a lambda whose body returns a value (`e ->
count++`) added directly, then removed through a `Map<String, Event->Void>` or a field typed `Event->Void` that holds
it. Give the listener the type it is kept as where it is made (`var listener:Event->Void = e -> count++;`), add and
remove the same variable, or remove it by the `Subscription` that `on` answers with.

Neko's threads run at once but contend for its allocator: a server spread over runtimes answered 1.4 times as many
requests on two runtimes as on one, and no more on four.

**Neko's numbers and clock.** An `Int` there is 31 bits, and `Array.sort` is a native merge sort that takes a
comparator's answer too large for one as "less", so a comparator written as a subtraction of large values sorts
wrongly there; answer -1, 0 or 1. On Windows, `haxe.Timer.stamp()` is the time of day to the millisecond, moving once
a system tick, so two readings a few microseconds apart are usually equal.
