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

	public function new(socket:NativeSocket) {
		this.socket = socket;
	}

	public override function readByte() {
		return try {
			socket.receiveChar();
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw new haxe.io.Eof();
		}
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

	public function setBlocking(b:Bool):Void {} // TODO: Don't know how to implement this...

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

private class SocketInput extends haxe.io.Input {
	var channel:SocketChannel;

	public function new(channel:SocketChannel) {
		this.channel = channel;
	}

	public override function readByte():Int {
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
		var bb = ByteBuffer.allocate(len);
		var n:Int = try {
			channel.read(bb);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		if (n == 0)
			throw Blocked;
		if (n < 0)
			throw new haxe.io.Eof();
		bb.flip();
		var data = buf.getData();
		bb.get(data, pos, n);
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
		this.input = new SocketInput(channel);
		this.output = new SocketOutput(channel);
	}

	public function close():Void {
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
	}

	public function read():String {
		return input.readAll().toString();
	}

	public function write(content:String):Void {
		output.writeString(content);
	}

	public function connect(host:Host, port:Int):Void {
		try {
			var addr = new InetSocketAddress(host.wrapped, port);
			var sc = __sock();
			sc.connect(addr);
			// Non-blocking connect: drive it to completion.
			while (!sc.finishConnect()) {
				// busy-wait until the connection is established
			}
			this.input = new SocketInput(sc);
			this.output = new SocketOutput(sc);
		} catch (e:Dynamic)
			throw e;
	}

	public function listen(connections:Int):Void {
		if (serverChannel == null)
			throw "You must bind the Socket to an address!";
		// Backlog is provided to ServerSocketChannel.bind in bind(); java.nio
		// has no separate listen() call, so this is a no-op beyond validation.
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
				serverChannel.configureBlocking(true);
			}
			var addr = new InetSocketAddress(host.wrapped, port);
			serverChannel.bind(cast addr);
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
		// java.nio channels have no per-socket SO_TIMEOUT; store best-effort.
		__timeout = timeout;
	}

	public function waitForRead():Void {
		var selector = Selector.open();
		try {
			if (channel.isBlocking())
				channel.configureBlocking(false);
			channel.register(selector, SelectionKey.OP_READ);
			selector.select();
		} catch (e:Dynamic) {}
		try
			selector.close()
		catch (e:Dynamic) {}
	}

	public function setBlocking(b:Bool):Void {
		try {
			if (channel != null)
				channel.configureBlocking(b);
			if (serverChannel != null)
				serverChannel.configureBlocking(b);
		} catch (e:Dynamic)
			throw e;
	}

	public function setFastSend(b:Bool):Void {
		try
			__sock().setOption(java.net.StandardSocketOptions.TCP_NODELAY, b)
		catch (e:Dynamic)
			throw e;
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var resRead:Array<Socket> = [];
		var resWrite:Array<Socket> = [];
		var resOthers:Array<Socket> = [];

		var selector = Selector.open();
		// Track interest ops per socket so a socket present in both read and
		// write lists gets a single registration with ORed interest ops.
		var sockets:Array<Socket> = [];
		var interest:Array<Int> = [];

		function addInterest(s:Socket, ops:Int):Void {
			for (i in 0...sockets.length) {
				if (sockets[i] == s) {
					interest[i] = interest[i] | ops;
					return;
				}
			}
			sockets.push(s);
			interest.push(ops);
		}

		if (read != null) {
			for (s in read) {
				if (s.serverChannel != null)
					addInterest(s, SelectionKey.OP_ACCEPT);
				else
					addInterest(s, SelectionKey.OP_READ);
			}
		}
		if (write != null) {
			for (s in write)
				addInterest(s, SelectionKey.OP_WRITE);
		}

		try {
			for (i in 0...sockets.length) {
				var s = sockets[i];
				var ch:java.nio.channels.SelectableChannel = s.serverChannel != null ? cast s.serverChannel : cast s.channel;
				if (ch == null)
					continue;
				// A channel must be non-blocking to register with a Selector.
				if (ch.isBlocking())
					ch.configureBlocking(false);
				var key = ch.register(selector, interest[i]);
				key.attach(s);
			}

			var n:Int;
			if (timeout == null || timeout <= 0) {
				n = selector.selectNow();
			} else {
				n = selector.select(cast(Std.int(timeout * 1000), haxe.Int64));
			}

			if (n > 0) {
				var it = selector.selectedKeys().iterator();
				while (it.hasNext()) {
					var key:SelectionKey = it.next();
					var s:Socket = cast key.attachment();
					var ready = key.readyOps();
					if ((ready & (SelectionKey.OP_READ | SelectionKey.OP_ACCEPT)) != 0)
						resRead.push(s);
					if ((ready & SelectionKey.OP_WRITE) != 0)
						resWrite.push(s);
				}
			}
		} catch (e:Dynamic) {
			// fall through, return whatever we collected
		}

		// Cancel keys and close the selector so channels can be re-registered.
		try {
			var keys = selector.keys().iterator();
			while (keys.hasNext()) {
				var k:SelectionKey = keys.next();
				k.cancel();
			}
		} catch (e:Dynamic) {}
		try
			selector.close()
		catch (e:Dynamic) {}

		return {read: resRead, write: resWrite, others: resOthers};
	}
}

#else

class Socket {
	public var socket:Dynamic;
	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public function new() {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function close():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function read():String {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function write(content:String):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function connect(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function listen(connections:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function shutdown(read:Bool, write:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function bind(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function accept():Socket {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function peer():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function host():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function setTimeout(timeout:Float):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function waitForRead():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function setBlocking(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public function setFastSend(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, and eval targets";
	}
}

#end
