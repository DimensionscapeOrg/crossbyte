/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package sys.net;

#if (cpp || hxcpp)

import haxe.io.Bytes;
import haxe.io.Error;

import cpp.NativeSocket;
import cpp.NativeString;
import cpp.Pointer;
import crossbyte._internal.net.NativeSocketAddress;

private class SocketInput extends haxe.io.Input {
	var __s:Dynamic;

	public function new(s:Dynamic) {
		__s = s;
	}

	public override function readByte() {
		return try {
			NativeSocket.socket_recv_char(__s);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else if (__s == null)
				throw Custom(e);
			else
				throw new haxe.io.Eof();
		}
	}

	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		var r;
		if (__s == null)
			throw "Invalid handle";
		try {
			r = NativeSocket.socket_recv(__s, buf.getData(), pos, len);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
		if (r == 0)
			throw new haxe.io.Eof();
		return r;
	}

	public override function close() {
		super.close();
		if (__s != null)
			NativeSocket.socket_close(__s);
	}
}

private class SocketOutput extends haxe.io.Output {
	var __s:Dynamic;

	public function new(s:Dynamic) {
		__s = s;
	}

	public override function writeByte(c:Int) {
		if (__s == null)
			throw "Invalid handle";
		try {
			NativeSocket.socket_send_char(__s, c);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		return try {
			NativeSocket.socket_send(__s, buf.getData(), pos, len);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else if (e == "EOF")
				throw new haxe.io.Eof();
			else
				throw Custom(e);
		}
	}

	public override function close() {
		super.close();
		if (__s != null)
			NativeSocket.socket_close(__s);
	}
}

@:coreApi
class Socket {
	private var __s:Dynamic;

	// Keep state so it can be restored if we recreate the socket for ipv6 in
	// connect() or bind().
	private var __timeout:Float = 0.0;
	private var __blocking:Bool = true;
	private var __fastSend:Bool = false;

	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public function new():Void {
		init();
	}

	@:noCompletion function __createSocket(ipv6:Bool):Dynamic {
		return ipv6 ? NativeSocket.socket_new_ip(false, true) : NativeSocket.socket_new(false);
	}

	private function init():Void {
		if (__s == null)
			__s = __createSocket(false);

		// Restore current settings after potential recreate.
		input = new SocketInput(__s);
		output = new SocketOutput(__s);

		setTimeout(__timeout);
		setBlocking(__blocking);
		setFastSend(__fastSend);
	}

	public function close():Void {
		var socket = __s;
		__s = null;
		if (socket != null) {
			NativeSocket.socket_close(socket);
		}
		untyped {
			var input:SocketInput = cast input;
			var output:SocketOutput = cast output;
			input.__s = null;
			output.__s = null;
		}
		input.close();
		output.close();
	}

	public function read():String {
		var bytes:haxe.io.BytesData = NativeSocket.socket_read(__s);
		if (bytes == null)
			return "";
		var arr:Array<cpp.Char> = cast bytes;
		return NativeString.fromPointer(Pointer.ofArray(arr));
	}

	public function write(content:String):Void {
		NativeSocket.socket_write(__s, haxe.io.Bytes.ofString(content).getData());
	}

	public function connect(host:Host, port:Int):Void {
		try {
			if (host.ip == 0 && host.host != "0.0.0.0") {
				var ipv6:haxe.io.BytesData = Reflect.field(host, "ipv6");
				if (ipv6 != null) {
					close();
					__s = __createSocket(true);
					init();
					NativeSocket.socket_connect_ipv6(__s, ipv6, port);
				} else
					throw "Unresolved host";
			} else
				NativeSocket.socket_connect(__s, host.ip, port);
		} catch (s:String) {
			if (s == "Invalid socket handle")
				throw "Failed to connect on " + host.toString() + ":" + port;
			else if (s == "Blocking") {
				// Non-blocking connect in progress.
			} else
				cpp.Lib.rethrow(s);
		}
	}

	public function listen(connections:Int):Void {
		NativeSocket.socket_listen(__s, connections);
	}

	public function shutdown(read:Bool, write:Bool):Void {
		NativeSocket.socket_shutdown(__s, read, write);
	}

	public function bind(host:Host, port:Int):Void {
		if (host.ip == 0 && host.host != "0.0.0.0") {
			var ipv6:haxe.io.BytesData = Reflect.field(host, "ipv6");
			if (ipv6 != null) {
				close();
				__s = __createSocket(true);
				init();
				NativeSocket.socket_bind_ipv6(__s, ipv6, port);
			} else
				throw "Unresolved host";
		} else
			NativeSocket.socket_bind(__s, host.ip, port);
	}

	public function accept():Socket {
		var c = NativeSocketAddress.accept(__s);
		var s = Type.createEmptyInstance(Socket);
		s.__s = c;
		s.input = new SocketInput(c);
		s.output = new SocketOutput(c);
		return s;
	}

	public function peer():{host:Host, port:Int} {
		var a:Dynamic = NativeSocketAddress.peerInfo(__s);
		if (a == null) {
			return null;
		}
		return {host: __hostFromNativeAddress(a), port: a[1]};
	}

	public function host():{host:Host, port:Int} {
		var a:Dynamic = NativeSocketAddress.hostInfo(__s);
		if (a == null) {
			return null;
		}
		return {host: __hostFromNativeAddress(a), port: a[1]};
	}

	public function setTimeout(timeout:Float):Void {
		__timeout = timeout;
		NativeSocket.socket_set_timeout(__s, timeout);
	}

	public function waitForRead():Void {
		select([this], null, null, null);
	}

	public function setBlocking(b:Bool):Void {
		__blocking = b;
		NativeSocket.socket_set_blocking(__s, b);
	}

	public function setFastSend(b:Bool):Void {
		__fastSend = b;
		NativeSocket.socket_set_fast_send(__s, b);
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var neko_array = NativeSocket.socket_select(read, write, others, timeout);
		if (neko_array == null)
			throw "Select error";
		return @:fixed {
			read: neko_array[0], write: neko_array[1], others: neko_array[2]
		};
	}

	private static function __hostFromNativeAddress(address:Dynamic):Host {
		var host:Host = Type.createEmptyInstance(Host);

		if (address.length > 2) {
			var bytes = Bytes.alloc(16);
			for (i in 0...16) {
				bytes.set(i, address[2 + i]);
			}
			var ipv6 = bytes.getData();
			untyped host.ip = 0;
			untyped host.ipv6 = ipv6;
			untyped host.host = NativeSocket.host_to_string_ipv6(ipv6);
		} else {
			var ip:Int = address[0];
			untyped host.ip = ip;
			untyped host.ipv6 = null;
			untyped host.host = NativeSocket.host_to_string(ip);
		}

		return host;
	}
}

#elseif eval

import haxe.io.Error;
import eval.vm.NativeSocket;

private class SocketOutput extends haxe.io.Output {
	var socket:NativeSocket;

	public function new(socket:NativeSocket) {
		this.socket = socket;
	}

	public override function writeByte(c:Int) {
		try {
			socket.sendChar(c);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else if (e == "EOF")
				throw new haxe.io.Eof();
			else
				throw Custom(e);
		}
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int) {
		return try {
			socket.send(buf, pos, len);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
	}

	public override function close() {
		super.close();
		socket.close();
	}
}

private class SocketInput extends haxe.io.Input {
	var socket:NativeSocket;
	var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);

	public function new(socket:NativeSocket) {
		this.socket = socket;
	}

	/**
		Through `readBytes`, which knows the end of the stream when it sees it.
		`receiveChar` answers 0 there, a byte like any other, so a reader
		waiting for a delimiter at the end of a connection read zeros for ever.
	**/
	public override function readByte() {
		readBytes(one, 0, 1);
		return one.get(0);
	}

	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int) {
		var r;
		try {
			r = socket.receive(buf, pos, len);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
		if (r == 0)
			throw new haxe.io.Eof();
		return r;
	}

	public override function close() {
		super.close();
		socket.close();
	}
}

class Socket {
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public var socket:NativeSocket;

	public function new() {
		init(new NativeSocket());
	}

	private function init(socket:NativeSocket):Void {
		this.socket = socket;
		input = new SocketInput(socket);
		output = new SocketOutput(socket);
	}

	public function close():Void {
		socket.close();
	}

	public function read():String {
		return input.readAll().toString();
	}

	public function write(content:String):Void {
		output.writeString(content);
	}

	public function connect(host:Host, port:Int):Void {
		if (host.ip == 0 && host.host != "0.0.0.0") {
			throw "Unresolved host";
		}
		socket.connect(host.ip, port);
	}

	public function listen(connections:Int):Void {
		socket.listen(connections);
	}

	public function shutdown(read:Bool, write:Bool):Void {
		socket.shutdown(read, write);
	}

	public function bind(host:Host, port:Int):Void {
		if (host.ip == 0 && host.host != "0.0.0.0") {
			throw "Unresolved host";
		}
		socket.bind(host.ip, port);
	}

	public function accept():Socket {
		var nativeSocket = socket.accept();
		var socket:Socket = Type.createEmptyInstance(Socket);
		socket.init(nativeSocket);
		return socket;
	}

	@:access(sys.net.Host.init)
	public function peer():{host:Host, port:Int} {
		var info = socket.peer();
		var host:Host = Type.createEmptyInstance(Host);
		host.init(info.ip);
		return {host: host, port: info.port};
	}

	@:access(sys.net.Host.init)
	public function host():{host:Host, port:Int} {
		var info = socket.host();
		var host:Host = Type.createEmptyInstance(Host);
		host.init(info.ip);
		return {host: host, port: info.port};
	}

	public function setTimeout(timeout:Float):Void {
		socket.setTimeout(timeout);
	}

	public function waitForRead():Void {
		select([this], null, null, -1);
	}

	/**
		A deliberate no-op, not an unfinished one: Haxe 4.3.7's eval target has
		no way to change a socket's blocking mode. `eval.vm.NativeSocket`
		exposes no set-blocking primitive and no file-descriptor accessor, and
		while `eval.luv` has `Stream.setBlocking`, nothing can construct a luv
		handle from an existing NativeSocket (`eval.luv.Tcp` has no from-fd
		constructor; `eval.luv.OsSocket` is an opaque abstract), so there is
		nowhere to forward the flag. Do not "fix" this by throwing either:
		crossbyte.net.Socket calls `setBlocking(false)` before every connect,
		so a throw here would break every interp connection.

		`setTimeout` is not a substitute, and this was measured rather than
		assumed: the timeout does reach the recv and SO_RCVTIMEO expires on
		schedule, but eval raises the expiry as an OCaml
		`Unix.Unix_error(ETIMEDOUT, "recv")` that no Haxe catch intercepts,
		not `haxe.Exception`, not `Dynamic`, not the catch inside SocketInput
		below, and the interpreter aborts outright. Bounding a read that way
		converts a stall into an uncatchable process death.

		What the no-op costs the eval/interp target, and what interp test
		results therefore do NOT cover: `connect()` blocks the whole runtime
		thread for the duration of the TCP handshake; reads block instead of
		raising `Blocked`, so read loops must gate on a zero-timeout `select`
		rather than drain until a Blocked error; and the write-side
		backpressure machinery (Blocked -> flushFull -> writable queue) never
		engages, because a blocking send just waits.
	**/
	public function setBlocking(b:Bool):Void {}

	public function setFastSend(b:Bool):Void {
		socket.setFastSend(b);
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		return NativeSocket.select(read, write, others, timeout);
	}
}

#elseif (java || jvm)

import haxe.io.Error;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;

@:access(sys.net.Socket)
private class SocketInput extends haxe.io.Input {
	var channel:SocketChannel;

	/** Seconds a blocking read waits for data before giving up; 0 waits for ever. **/
	public var timeout:Float = 0.0;

	public function new(channel:SocketChannel) {
		this.channel = channel;
	}

	function __awaitReadable():Void {
		Socket.__awaitReadable(channel, timeout);
	}

	public override function readByte():Int {
		__awaitReadable();
		var buf = ByteBuffer.allocate(1);
		var n:Int = try {
			channel.read(buf);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (n == 0)
			throw Blocked;
		if (n < 0)
			throw new haxe.io.Eof();
		buf.flip();
		return (cast(buf.get(), Int)) & 0xFF;
	}

	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (channel == null)
			throw "Invalid handle";

		// Wrapped, not allocated. This used to allocate a buffer the size of the
		// read and then copy every byte out of it into the caller's, on every
		// read, sixty-four kilobytes of each per chunk on the framework's own
		// read path. The write side beside this has always wrapped; the two are
		// now the same shape.
		__awaitReadable();
		var bb = ByteBuffer.wrap(buf.getData(), pos, len);
		var n:Int = try {
			channel.read(bb);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (n == 0)
			throw Blocked;
		if (n < 0)
			throw new haxe.io.Eof();
		return n;
	}

	public override function close():Void {
		super.close();
		if (channel != null) {
			try
				channel.close()
			catch (e:Dynamic) {}
		}
	}
}

private class SocketOutput extends haxe.io.Output {
	var channel:SocketChannel;

	public function new(channel:SocketChannel) {
		this.channel = channel;
	}

	public override function writeByte(c:Int):Void {
		if (channel == null)
			throw "Invalid handle";
		var buf = ByteBuffer.allocate(1);
		buf.put(c & 0xFF);
		buf.flip();
		var n:Int = try {
			channel.write(buf);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (n == 0)
			throw Blocked;
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (channel == null)
			throw "Invalid handle";
		var bb = ByteBuffer.wrap(buf.getData(), pos, len);
		var n:Int = try {
			channel.write(bb);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (n == 0)
			throw Blocked;
		return n;
	}

	public override function close():Void {
		super.close();
		if (channel != null) {
			try
				channel.close()
			catch (e:Dynamic) {}
		}
	}
}

class Socket {
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	// Holds either a SocketChannel (TCP) or a DatagramChannel (UDP) so that
	// UdpSocket can reuse the registry/select() machinery. TCP-only members
	// access it through __sock().
	private var channel:java.nio.channels.SelectableChannel;
	private var serverChannel:ServerSocketChannel;
	private var __timeout:Float = 0.0;

	// What setBlocking was last asked for, so a channel opened later starts
	// that way. Before bind() there is no server channel to configure, so the
	// call had nowhere to land and was silently dropped, and bind() then
	// opened one hardcoded to blocking. A caller that did the natural thing,
	// setBlocking(false) before bind(), got a blocking listener anyway, and the
	// first accept() on an idle port blocked the thread that was polling it.
	// For ServerWebSocket that thread is the runtime's, so the whole instance
	// stopped. ServerSocket escaped it only by selecting before it accepts.
	private var __blocking:Bool = true;

	public function new():Void {
		var ch = SocketChannel.open();
		ch.configureBlocking(true);
		this.channel = ch;
	}

	// The channel as a SocketChannel for TCP operations. UDP never calls these.
	private inline function __sock():SocketChannel
		return cast channel;

	private function __init(channel:SocketChannel):Void {
		this.channel = channel;
		var input = new SocketInput(channel);
		input.timeout = __timeout;
		this.input = input;
		this.output = new SocketOutput(channel);
	}

	public function close():Void {
		var key:SelectionKey = __selectKey;
		__selectKey = null;
		__selectArmed = -1;

		try {
			if (channel != null)
				channel.close();
		} catch (e:Dynamic) {}
		try {
			if (serverChannel != null)
				serverChannel.close();
		} catch (e:Dynamic) {}
		if (input != null)
			input.close();
		if (output != null)
			output.close();

		if (key != null) {
			__letGo(key.selector());
		}
	}

	/**
		Has `selector` let go of a channel just closed, now.

		Closing a channel registered with a selector only cancels its key; on
		Windows the socket itself is not closed until every selector it was
		registered with has let it go, which a selector does at its next select.
		`select` keeps what it watches registered between calls, so until the
		runtime's next pump a closed datagram socket kept its address, a closed
		connection's peer waited for its FIN, and a closed listener its port,
		the case that found this rebound a port it had just closed, and was
		refused. The selector of the thread closing it is told at once; another
		thread's is woken, and lets go on the select it returns from.
	**/
	@:noCompletion private static function __letGo(selector:Selector):Void {
		var state:Null<SelectState> = cast __states.get();
		try {
			if (state != null && state.main == selector) {
				selector.selectNow();
			} else {
				selector.wakeup();
			}
		} catch (_:Dynamic) {}
	}

	public function read():String {
		return input.readAll().toString();
	}

	public function write(content:String):Void {
		output.writeString(content);
	}

	/**
		Connects, or on a non-blocking socket starts connecting.

		A non-blocking connect returns while the connection is still being made,
		as it does natively, and `select` finishes it: the socket is reported
		writable once it is up, and a refusal is reported in the exception set
		(or as writable, POSIX's way, to a caller that did not ask for that set).
		This used to spin on `finishConnect()` until the connection came up, on
		whichever thread called it, for `crossbyte.net.Socket` and the wss
		client, the runtime's. Against a listener whose queue was full that was
		two seconds of the runtime doing nothing else; against a host that never
		answers, the system's whole SYN-retry time, 21 s on Windows and two
		minutes on Linux.

		A blocking connect is bounded by `setTimeout`, as reads are: it was
		bounded only by the system, so an https request to a host that never
		answered waited out the SYN retries whatever its timeout said.
	**/
	public function connect(host:Host, port:Int):Void {
		var addr = new InetSocketAddress(host.wrapped, port);
		var sc = __sock();

		if (!sc.isBlocking()) {
			// False while the connection is still being made; select finishes it.
			sc.connect(addr);
		} else if (__timeout > 0) {
			// The adaptor's timed connect: it polls for the connection for at
			// most this long, and closes the channel if it does not come.
			var millis:Float = Math.ceil(__timeout * 1000);
			sc.socket().connect(addr, millis > 0x7FFFFFFF ? 0x7FFFFFFF : Std.int(millis));
		} else {
			sc.connect(addr);
		}

		var input = new SocketInput(sc);
		input.timeout = __timeout;
		this.input = input;
		this.output = new SocketOutput(sc);
	}

	public function listen(connections:Int):Void {
		if (serverChannel == null)
			throw "You must bind the Socket to an address!";
		// java.nio has no listen() of its own: the queue length is given to
		// bind(), which has already run by the time this is called, with the
		// longest queue the system allows. A shorter one asked for here cannot
		// be applied after the fact.
	}

	public function shutdown(read:Bool, write:Bool):Void {
		try {
			var sc = __sock();
			if (read)
				sc.shutdownInput();
			if (write)
				sc.shutdownOutput();
		} catch (e:Dynamic)
			throw e;
	}

	public function bind(host:Host, port:Int):Void {
		try {
			if (serverChannel == null) {
				serverChannel = ServerSocketChannel.open();
				serverChannel.configureBlocking(__blocking);
			}
			var addr = new InetSocketAddress(host.wrapped, port);
			// The queue length has to be named here, because java.nio takes it
			// at bind() and a server binds before it says how long a queue it
			// wants. Left out, NIO asks for 50, and a burst of 51 connections
			// found the queue full and was refused by the kernel. The largest
			// value is the system's maximum, what listen(0) means, since the
			// system clamps it to its own limit.
			serverChannel.bind(cast addr, 0x7FFFFFFF);
		} catch (e:Dynamic)
			throw e;
	}

	public function accept():Socket {
		var c:SocketChannel = try {
			serverChannel.accept();
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (c == null)
			throw Blocked;
		c.configureBlocking(true);
		var s:Socket = Type.createEmptyInstance(Socket);
		s.__init(c);
		return s;
	}

	public function peer():{host:Host, port:Int} {
		var addr:Dynamic = try {
			__sock().getRemoteAddress();
		} catch (e:Dynamic) {
			return null;
		}
		if (addr == null)
			return null;
		var isa:InetSocketAddress = cast addr;
		// Build a fully-populated Host from the IP string; `new Host(null); wrapped=...`
		// leaves the host/ip fields stale (empty on the jvm target).
		var h = new Host(isa.getAddress().getHostAddress());
		return {host: h, port: isa.getPort()};
	}

	public function host():{host:Host, port:Int} {
		var addr:Dynamic = try {
			// For a bound server socket the client channel is unbound (null);
			// report the server channel's local address (incl. an OS-assigned port).
			// NetworkChannel.getLocalAddress works for both SocketChannel (TCP)
			// and DatagramChannel (UDP), so this is correct for UdpSocket too.
			(serverChannel != null) ? (cast serverChannel : java.nio.channels.NetworkChannel).getLocalAddress() : (cast channel : java.nio.channels.NetworkChannel).getLocalAddress();
		} catch (e:Dynamic) {
			return null;
		}
		if (addr == null)
			return null;
		var isa:InetSocketAddress = cast addr;
		// Build a fully-populated Host from the IP string; `new Host(null); wrapped=...`
		// leaves the host/ip fields stale (empty on the jvm target).
		var h = new Host(isa.getAddress().getHostAddress());
		return {host: h, port: isa.getPort()};
	}

	public function setTimeout(timeout:Float):Void {
		// A blocking channel read ignores SO_TIMEOUT; the input waits on a
		// selector for this long before each blocking read instead.
		__timeout = timeout;
		var reader:Null<SocketInput> = Std.downcast(input, SocketInput);
		if (reader != null) {
			reader.timeout = timeout;
		}
	}

	public function waitForRead():Void {
		try {
			if (serverChannel != null) {
				__waitOn(serverChannel, SelectionKey.OP_ACCEPT, -1);
			} else {
				__waitOn(channel, SelectionKey.OP_READ, -1);
			}
		} catch (_:Dynamic) {}
	}

	public function setBlocking(b:Bool):Void {
		__blocking = b;

		// A channel still registered with a selector cannot be made blocking,
		// and select keeps the non-blocking sockets it is asked about
		// registered from one call to the next: that registration goes first.
		if (b) {
			__dropSelectKeys();
		}

		if (channel != null)
			channel.configureBlocking(b);
		if (serverChannel != null)
			serverChannel.configureBlocking(b);
	}

	// TCP_NODELAY asked for while a connect was in progress, applied once it
	// is up: Windows refuses the option on a connecting socket (WSAEINVAL),
	// and crossbyte.net.Socket asks for it straight after connect().
	@:noCompletion private var __fastSendPending:Bool = false;
	@:noCompletion private var __fastSend:Bool = false;

	public function setFastSend(b:Bool):Void {
		if (!Std.isOfType(channel, SocketChannel)) {
			// A datagram channel: there is no Nagle to turn off.
			return;
		}
		var sc = __sock();
		if (sc.isConnectionPending()) {
			__fastSend = b;
			__fastSendPending = true;
			return;
		}
		sc.setOption(java.net.StandardSocketOptions.TCP_NODELAY, b);
	}

	/** What waited for a connect in progress to finish. **/
	@:noCompletion private function __onConnected():Void {
		if (__fastSendPending) {
			__fastSendPending = false;
			try {
				__sock().setOption(java.net.StandardSocketOptions.TCP_NODELAY, __fastSend);
			} catch (_:Dynamic) {}
		}
	}

	/**
		What `select` keeps from one call to the next, one set per thread: each
		runtime ticks on its own thread, and a `Selector` is not safe to use
		from several at once.

		The selectors are opened once and kept. They used to be opened and
		closed on every call, and on Windows a `Selector` builds its wakeup pipe
		out of a loopback socket pair, so each open cost two sockets and each
		close left them in TIME_WAIT for the best part of a minute: a runtime at
		sixty ticks a second worked through the whole ephemeral range in a
		couple of minutes, and everything socket-shaped then failed at once.

		The sockets asked about stay registered between calls too. Each call
		used to register every socket it was handed, check every pair of them
		for duplicates, and cancel every key again before returning, and
		`SocketRegistry` makes that call on every pump, with every socket it
		holds: 0.55 ms for 1,000 idle sockets, 7.7 ms for 4,000, and on
		Windows, past 1,023, a selector helper thread started and stopped on
		every call. Now a call changes only what differs from the last one: a
		socket asked about for the first time is registered, one asked about
		differently has its interest changed, and one no longer asked about
		stops being watched the first time it turns up ready.
	**/
	@:noCompletion private static var __states:JThreadLocal = new JThreadLocal();

	// Which thread's select last asked about this socket, in which of its
	// calls, and for what; see select.
	@:noCompletion private var __selectState:SelectState = null;
	@:noCompletion private var __selectPass:Int = 0;
	@:noCompletion private var __selectOps:Int = 0;
	// The key this socket is registered under in the selector that last
	// watched it, and what it was last asked about when that key was set up;
	// -1 when the key has to be looked at again.
	@:noCompletion private var __selectKey:SelectionKey = null;
	@:noCompletion private var __selectArmed:Int = -1;
	// A registration made for one call only, a look at one socket, or at a
	// blocking one, and whether the channel was blocking before it.
	@:noCompletion private var __lookKey:SelectionKey = null;
	@:noCompletion private var __lookRestore:Bool = false;

	@:noCompletion private static function __state():SelectState {
		var existing:Dynamic = __states.get();

		if (existing == null) {
			existing = new SelectState();
			__states.set(existing);
		}

		return cast existing;
	}

	/**
		A blocking NIO channel has no read timeout, SO_TIMEOUT reaches only
		the stream API, never `channel.read`, so `setTimeout` was stored and
		never read, and a read with nothing coming waited for ever: the HTTP
		client's idle limit did nothing here. Waiting for readability first
		gives the timeout the other targets honour. The TLS socket calls this
		too, before it reads ciphertext.
	**/
	@:noCompletion private static function __awaitReadable(channel:SocketChannel, timeout:Float):Void {
		if (timeout <= 0 || channel == null || !channel.isBlocking()) {
			return;
		}

		if (!__waitOn(channel, SelectionKey.OP_READ, timeout)) {
			throw Custom("Timeout");
		}
	}

	/**
		Waits for `ops` on `ch` for at most `timeout` seconds, or for ever when
		it is negative, and leaves the channel as blocking as it found it.

		On the thread's wait selector, which never holds more than the one
		wait in progress. `select`'s selectors keep what they watch registered
		between calls, and a socket of theirs turning ready would end this
		wait for a socket that is not.

		@return Whether the channel became ready.
	**/
	@:noCompletion private static function __waitOn(ch:java.nio.channels.SelectableChannel, ops:Int, timeout:Float):Bool {
		var selector = __state().waitSelector();
		var blocking:Bool = ch.isBlocking();
		var ready:Int = 0;
		var failure:Dynamic = null;
		var key:SelectionKey = null;

		try {
			if (blocking) {
				ch.configureBlocking(false);
			}
			key = ch.register(selector, ops);
			if (timeout < 0) {
				ready = selector.select();
			} else {
				// 0 would mean no limit to select; the shortest real wait is 1 ms.
				var millis:Float = Math.ceil(timeout * 1000);
				ready = selector.select(haxe.Int64.fromFloat(millis < 1 ? 1 : millis));
			}
		} catch (e:Dynamic) {
			failure = e;
		}

		try {
			if (key != null) {
				key.cancel();
			}
			// Released now rather than at the next wait, which may be for
			// this same channel and would otherwise find it still registered.
			selector.selectNow();
			selector.selectedKeys().clear();
		} catch (_:Dynamic) {}

		if (blocking) {
			try {
				ch.configureBlocking(true);
			} catch (e:Dynamic) {
				if (failure == null) {
					failure = e;
				}
			}
		}

		if (failure != null) {
			throw Custom(failure);
		}
		return ready > 0;
	}

	/**
		Gives up the registrations this thread's selects hold for this socket,
		so it can be made blocking. Registrations on other threads' selectors
		are theirs: a socket is selected by the runtime that owns it.
	**/
	@:noCompletion private function __dropSelectKeys():Void {
		if (__selectKey != null) {
			try {
				__selectKey.cancel();
			} catch (_:Dynamic) {}
			__selectKey = null;
		}
		__selectArmed = -1;

		var state:Null<SelectState> = cast __states.get();
		if (state == null) {
			return;
		}

		for (ch in [channel, cast serverChannel]) {
			if (ch == null) {
				continue;
			}
			for (selector in [state.main, state.probe]) {
				if (selector == null) {
					continue;
				}
				var key = ch.keyFor(selector);
				if (key != null) {
					key.cancel();
				}
			}
		}
	}

	/**
		Not an NIO operation: marks a socket asked about in the exception set,
		which NIO has no set for. Only a connect in progress has anything to
		report there, its refusal.
	**/
	@:noCompletion private static inline var OP_EXCEPT:Int = 1 << 30;

	/**
		The NIO interest for what a socket was asked about. A connect still in
		progress is neither writable nor refused until it settles, and that is
		what OP_CONNECT reports: asked about as either, it is watched for that.
	**/
	@:noCompletion private static function __interestFor(s:Socket, asked:Int):Int {
		var ops:Int = asked & ~OP_EXCEPT;

		if (s.serverChannel == null && Std.isOfType(s.channel, SocketChannel)) {
			var sc:SocketChannel = cast s.channel;
			if (sc.isConnectionPending() && (asked & (SelectionKey.OP_WRITE | OP_EXCEPT)) != 0) {
				ops = (ops & ~SelectionKey.OP_WRITE) | SelectionKey.OP_CONNECT;
			}
		}

		return ops;
	}

	/**
		Finishes a connect `select` found settled, and files the socket where
		native reports it: writable once it is up; refused, in the exception
		set if it was asked about there, Windows' way, and otherwise as
		writable, POSIX's, for the first read or write to report the failure.
	**/
	@:noCompletion private static function __settleConnect(s:Socket, write:Array<Socket>, others:Array<Socket>):Void {
		var sc:SocketChannel = cast s.channel;
		var refused:Bool = false;
		// What it is watched for changes with the connect settled.
		s.__selectArmed = -1;
		var done:Bool = try {
			sc.finishConnect();
		} catch (_:Dynamic) {
			// NIO has closed the channel; the socket's next use says so.
			refused = true;
			false;
		}

		if (done) {
			s.__onConnected();
			if ((s.__selectOps & SelectionKey.OP_WRITE) != 0) {
				write.push(s);
			}
		} else if (refused) {
			if ((s.__selectOps & OP_EXCEPT) != 0) {
				others.push(s);
			} else if ((s.__selectOps & SelectionKey.OP_WRITE) != 0) {
				write.push(s);
			}
		}
	}

	/**
		Which sockets are ready, of those asked about.

		Each socket is registered with this thread's selector the first time
		it is asked about and stays registered; later calls change only what
		differs (see `__states`). A socket asked about in an earlier call and
		not in this one is not reported, and the first time it turns up ready
		it stops being watched, so it cannot end a wait it is no part of.

		A look at a single socket without waiting, a listener asked whether a
		connection is waiting, a connect asked whether it is up, runs on a
		selector of its own, so that it costs one socket rather than every
		socket the thread's runtime watches, and is registered for the call
		only (see `__look`).

		A blocking socket is looked at and not kept: made non-blocking for the
		call and blocking again after, as native `select` leaves it. It used to
		be left non-blocking, which a blocking reader then met as a read that
		answered "would block" at once.
	**/
	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var resRead:Array<Socket> = [];
		var resWrite:Array<Socket> = [];
		var resOthers:Array<Socket> = [];

		var state = __state();
		// Never 0, which a socket no call has asked about yet reads as.
		var pass:Int = ++state.pass;
		if (pass == 0) {
			pass = ++state.pass;
		}
		var asked = state.asked;
		asked.resize(0);

		// Each socket once, with everything it was asked about: a socket in
		// both lists is one registration. This was a pairwise search, O(n^2)
		// in the sockets asked about.
		if (read != null) {
			for (s in read) {
				__ask(state, pass, s, s.serverChannel != null ? SelectionKey.OP_ACCEPT : SelectionKey.OP_READ);
			}
		}
		if (write != null) {
			for (s in write) {
				__ask(state, pass, s, SelectionKey.OP_WRITE);
			}
		}
		if (others != null) {
			for (s in others) {
				__ask(state, pass, s, OP_EXCEPT);
			}
		}

		var polling:Bool = timeout == null || timeout <= 0;
		var look:Bool = polling && asked.length == 1;
		var selector:Selector = look ? state.probeSelector() : state.mainSelector();
		var transients = state.transients;
		transients.resize(0);

		for (s in asked) {
			try {
				if (look) {
					__look(s, selector, transients);
				} else {
					__watch(s, selector, transients);
				}
			} catch (_:Dynamic) {
				// Closed, or failing: not watched, and so not reported. One
				// socket like that used to abandon the whole call, and every
				// other socket in it went unreported with it.
			}
		}

		var selected = selector.selectedKeys();
		var wait:Float = polling ? 0.0 : timeout;
		var deadline:Float = polling ? 0.0 : haxe.Timer.stamp() + timeout;

		try {
			while (true) {
				// Whatever an earlier select operation left there is not this
				// call's answer.
				if (!selected.isEmpty()) {
					selected.clear();
				}

				if (polling) {
					selector.selectNow();
				} else {
					// select(0) waits for ever; the shortest real wait is 1 ms.
					var millis:Int = Std.int(wait * 1000);
					selector.select(haxe.Int64.ofInt(millis < 1 ? 1 : millis));
				}

				var strays:Int = 0;
				if (!selected.isEmpty()) {
					var it = selected.iterator();
					while (it.hasNext()) {
						var key:SelectionKey = it.next();
						var s:Socket = cast key.attachment();

						if (s == null || s.__selectState != state || s.__selectPass != pass) {
							// Watched for an earlier call and not asked about in
							// this one: not reported, and not watched again until
							// it is asked about.
							try {
								key.interestOps(0);
							} catch (_:Dynamic) {}
							if (s != null) {
								s.__selectArmed = -1;
							}
							strays++;
							continue;
						}

						var ready:Int = try {
							key.readyOps();
						} catch (_:Dynamic) {
							0;
						}
						if ((ready & SelectionKey.OP_CONNECT) != 0)
							__settleConnect(s, resWrite, resOthers);
						if ((ready & (SelectionKey.OP_READ | SelectionKey.OP_ACCEPT)) != 0)
							resRead.push(s);
						if ((ready & SelectionKey.OP_WRITE) != 0)
							resWrite.push(s);
					}
					selected.clear();
				}

				// Woken only by sockets nobody asked about, which are not
				// watched now: the wait goes on for what is left of it, since
				// an empty answer before the timeout reads as the timeout.
				if (polling || strays == 0 || resRead.length + resWrite.length + resOthers.length > 0) {
					break;
				}
				wait = deadline - haxe.Timer.stamp();
				if (wait < 0.001) {
					break;
				}
			}
		} catch (_:Dynamic) {
			// Whatever was collected is the answer.
		}

		if (transients.length > 0) {
			for (s in transients) {
				__unwatch(s);
			}
			// Released now, so the next call can register them again.
			try {
				selector.selectNow();
				selected.clear();
			} catch (_:Dynamic) {}
		}

		return {read: resRead, write: resWrite, others: resOthers};
	}

	/** Records that `s` is asked about for `ops` in this call. **/
	@:noCompletion private static inline function __ask(state:SelectState, pass:Int, s:Socket, ops:Int):Void {
		if (s.__selectState != state || s.__selectPass != pass) {
			s.__selectState = state;
			s.__selectPass = pass;
			s.__selectOps = ops;
			state.asked.push(s);
		} else {
			s.__selectOps |= ops;
		}
	}

	/**
		Has `selector` watch `s` for what it was asked about in this call.

		Nothing to do in the steady state, asked about the same as last time,
		on the same selector, which is where every socket a runtime holds
		spends its life.
	**/
	@:noCompletion private static function __watch(s:Socket, selector:Selector, transients:Array<Socket>):Void {
		var ch:java.nio.channels.SelectableChannel = s.serverChannel != null ? cast s.serverChannel : s.channel;
		if (ch == null) {
			return;
		}

		var key:SelectionKey = s.__selectKey;
		if (key != null && key.selector() == selector && s.__selectArmed == s.__selectOps && key.isValid()) {
			return;
		}

		if (ch.isBlocking()) {
			// Looked at, not kept; see select.
			__look(s, selector, transients);
			return;
		}

		var ops:Int = __interestFor(s, s.__selectOps);

		if (key == null || key.selector() != selector) {
			key = ch.keyFor(selector);
		}

		if (key != null && key.isValid()) {
			if (key.interestOps() != ops) {
				key.interestOps(ops);
			}
		} else if (ops != 0) {
			key = __register(ch, selector, ops, s);
		} else {
			// Asked only about the exception set, which a connected socket
			// has nothing to report in.
			return;
		}

		s.__selectKey = key;
		s.__selectArmed = s.__selectOps;
	}

	@:noCompletion private static function __register(ch:java.nio.channels.SelectableChannel, selector:Selector, ops:Int, s:Socket):SelectionKey {
		return try {
			ch.register(selector, ops, s);
		} catch (_:java.nio.channels.CancelledKeyException) {
			// Cancelled on this selector earlier and not yet released, which
			// only the selector's next select operation does. It is done now,
			// and the registration made again.
			selector.selectNow();
			ch.register(selector, ops, s);
		}
	}

	/**
		Registers `s` with `selector` for this call only: a look at a single
		socket, or at a blocking one. Given up again before select returns (see
		`__unwatch`), so nothing is kept, a listener asked each tick whether a
		connection waits costs one socket, not every socket its runtime watches,
		and nothing is left holding it registered once it closes.
	**/
	@:noCompletion private static function __look(s:Socket, selector:Selector, transients:Array<Socket>):Void {
		var ch:java.nio.channels.SelectableChannel = s.serverChannel != null ? cast s.serverChannel : s.channel;
		if (ch == null) {
			return;
		}

		var ops:Int = __interestFor(s, s.__selectOps);
		if (ops == 0) {
			return;
		}

		// Listed first, so the blocking mode is put back even if registering
		// fails.
		transients.push(s);
		s.__lookRestore = ch.isBlocking();
		if (s.__lookRestore) {
			ch.configureBlocking(false);
		}
		s.__lookKey = __register(ch, selector, ops, s);
	}

	/** Gives up a registration made by `__look`, and puts back a blocking mode it changed. **/
	@:noCompletion private static function __unwatch(s:Socket):Void {
		var key = s.__lookKey;
		s.__lookKey = null;
		var restore:Bool = s.__lookRestore;
		s.__lookRestore = false;

		try {
			if (key != null) {
				key.cancel();
			}
			if (restore) {
				var ch:java.nio.channels.SelectableChannel = s.serverChannel != null ? cast s.serverChannel : s.channel;
				ch.configureBlocking(true);
			}
		} catch (_:Dynamic) {}
	}
}

/** One thread's selectors, and the scratch its select calls reuse. **/
@:noCompletion private class SelectState {
	/** For the many sockets a runtime watches, which stay registered. **/
	public var main:Selector = null;

	/** For a look at one socket without waiting. **/
	public var probe:Selector = null;

	/** For a blocking wait on one socket, which nothing else may end. **/
	public var wait:Selector = null;

	public var pass:Int = 0;
	public var asked:Array<Socket> = [];
	public var transients:Array<Socket> = [];

	public function new() {}

	public function mainSelector():Selector {
		if (main == null) {
			main = Selector.open();
		}
		return main;
	}

	public function probeSelector():Selector {
		if (probe == null) {
			probe = Selector.open();
		}
		return probe;
	}

	public function waitSelector():Selector {
		if (wait == null) {
			wait = Selector.open();
		}
		return wait;
	}
}

/** Haxe ships no extern for it, and only this module needs one. **/
@:native("java.lang.ThreadLocal")
extern class JThreadLocal {
	function new();
	function get():Dynamic;
	function set(value:Dynamic):Void;
}

#else

class Socket {
	public var socket:Dynamic;
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public function new() {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function close():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function read():String {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function write(content:String):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function connect(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function listen(connections:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function shutdown(read:Bool, write:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function bind(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function accept():Socket {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function peer():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function host():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function setTimeout(timeout:Float):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function waitForRead():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function setBlocking(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public function setFastSend(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, java and jvm targets";
	}
}

#end
