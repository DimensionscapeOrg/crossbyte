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

// Each target's standard implementation, where this module replaces it. hl
// and neko had none here and got the throwing class at the bottom, so
// `new UdpSocket()` threw "Not available on this platform" on two targets
// whose standard library has UDP. IPv4 only, as their natives are.
#if hl

import haxe.io.Error;
import sys.net.Socket.SocketHandle;

class UdpSocket extends Socket {
	public function new() {
		super();
	}

	override function init():Void {
		__s = Socket.socket_new(true);
		super.init();
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw OutsideBounds;
		var ret = socket_send_to(__s, (buf : hl.Bytes).offset(pos), len, addr.host, addr.port);
		if (ret < 0) {
			if (ret == -1)
				throw Blocked;
			throw new haxe.io.Eof();
		}
		return ret;
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var ret = __tryReadFrom(buf, pos, len, addr);
		if (ret < 0)
			throw Blocked;
		if (ret == 0)
			throw new haxe.io.Eof();
		return ret;
	}

	/** `readFrom` answering -1 for "would block" rather than throwing; see the cpp form. **/
	@:noCompletion private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var host = 0, port = 0;
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw OutsideBounds;
		var ret = socket_recv_from(__s, (buf : hl.Bytes).offset(pos), len, host, port);
		if (ret == -1)
			return -1;
		if (ret < 0)
			throw new haxe.io.Eof();
		addr.host = host;
		addr.port = port;
		return ret;
	}

	/** `sendTo` answering -1 for a full send buffer rather than throwing. **/
	@:noCompletion private function __trySendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw OutsideBounds;
		var ret = socket_send_to(__s, (buf : hl.Bytes).offset(pos), len, addr.host, addr.port);
		if (ret == -1)
			return -1;
		if (ret < 0)
			throw new haxe.io.Eof();
		return ret;
	}

	public function setBroadcast(b:Bool):Void {
		if (!socket_set_broadcast(__s, b))
			throw new Sys.SysError("setBroadcast() failure");
	}

	@:hlNative("std", "socket_send_to") static function socket_send_to(s:SocketHandle, bytes:hl.Bytes, len:Int, host:Int, port:Int):Int {
		return 0;
	}

	@:hlNative("std", "socket_set_broadcast") static function socket_set_broadcast(s:SocketHandle, b:Bool):Bool {
		return true;
	}

	@:hlNative("std", "socket_recv_from") static function socket_recv_from(s:SocketHandle, bytes:hl.Bytes, len:Int, host:hl.Ref<Int>,
			port:hl.Ref<Int>):Int {
		return 0;
	}
}

#elseif neko

import haxe.io.Error;

@:coreApi
class UdpSocket extends Socket {
	private override function init():Void {
		__s = Socket.socket_new(true);
		super.init();
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			socket_send_to(__s, buf.getData(), pos, len, addr);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var r;
		try {
			r = socket_recv_from(__s, buf.getData(), pos, len, addr);
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

	/**
		`readFrom` answering -1 for "would block": the native still throws,
		but nothing throws again here.
	**/
	@:noCompletion private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			socket_recv_from(__s, buf.getData(), pos, len, addr);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				-1;
			else
				throw Custom(e);
		}
	}

	/** `sendTo` answering -1 for a full send buffer. **/
	@:noCompletion private function __trySendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			socket_send_to(__s, buf.getData(), pos, len, addr);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				-1;
			else
				throw Custom(e);
		}
	}

	public function setBroadcast(b:Bool):Void {
		socket_set_broadcast(__s, b);
	}

	static var socket_recv_from = neko.Lib.loadLazy("std", "socket_recv_from", 5);
	static var socket_send_to = neko.Lib.loadLazy("std", "socket_send_to", 5);
	static var socket_set_broadcast = neko.Lib.loadLazy("std", "socket_set_broadcast", 2);
}

#elseif (cpp || hxcpp)

import cpp.NativeSocket;
import crossbyte._internal.net.NativeSocketAddress;
import haxe.io.Error;

@:coreApi
class UdpSocket extends Socket {
	override function __createSocket(ipv6:Bool):Dynamic {
		return ipv6 ? NativeSocket.socket_new_ip(true, true) : NativeSocket.socket_new(true);
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var sent:Int = __trySendTo(buf, pos, len, addr);
		if (sent < 0)
			throw Blocked;
		return sent;
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var r:Int = __tryReadFrom(buf, pos, len, addr);
		if (r < 0)
			throw Blocked;
		if (r == 0)
			throw new haxe.io.Eof();
		return r;
	}

	/**
		`readFrom` without an exception for "would block": -1 when no datagram
		is waiting, which a non-blocking receiver meets at the end of every
		pass. That was a native throw caught here and thrown again as
		`Blocked`: 4.3 us of a datagram's 13.
	**/
	@:noCompletion private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			NativeSocketAddress.tryRecvFrom(__s, buf.getData(), pos, len, addr);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
	}

	/** `sendTo` without an exception for a full send buffer: -1 then. **/
	@:noCompletion private function __trySendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			NativeSocketAddress.trySendTo(__s, buf.getData(), pos, len, addr);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
	}

	public function setBroadcast(b:Bool):Void {
		NativeSocket.socket_set_broadcast(__s, b);
	}
}

#elseif (java || jvm)

import haxe.io.Error;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.StandardSocketOptions;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;

class UdpSocket extends Socket {
	public function new() {
		// Socket.new() opens a TCP SocketChannel and stores it in `channel`.
		// Replace it with a DatagramChannel so the inherited registry/select()
		// machinery (which registers `channel`) drives UDP readiness.
		super();
		@:privateAccess {
			try {
				if (this.channel != null)
					this.channel.close();
			} catch (e:Dynamic) {}
			var dc = DatagramChannel.open();
			dc.configureBlocking(true);
			this.channel = dc;
		}
	}

	// The inherited `channel` field, viewed as a DatagramChannel.
	private inline function __dc():DatagramChannel
		return cast(@:privateAccess this.channel);

	override public function bind(host:Host, port:Int):Void {
		try {
			var addr = new InetSocketAddress(host.wrapped, port);
			__dc().bind(cast addr);
		} catch (e:Dynamic)
			throw e;
	}

	// UDP "connect" sets the default peer; the inherited TCP connect() would cast
	// the DatagramChannel to a SocketChannel and fail.
	override public function connect(host:Host, port:Int):Void {
		try {
			__dc().connect(new InetSocketAddress(host.wrapped, port));
		} catch (e:Dynamic)
			throw e;
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var n:Int = __trySendTo(buf, pos, len, addr);
		if (n < 0)
			throw Blocked;
		return n;
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var n:Int = __tryReadFrom(buf, pos, len, addr);
		if (n < 0)
			throw Blocked;
		if (n == 0)
			throw new haxe.io.Eof();
		return n;
	}

	/**
		`readFrom` without an exception for "would block": -1 when no datagram
		is waiting. Thrown as `Blocked`, that ended every pass of a
		non-blocking receiver for 2.4 us, a quarter of a datagram's cost here.
	**/
	@:noCompletion private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		// Straight into the caller's buffer. A new buffer of `len` bytes was
		// allocated, and zeroed, for every datagram, 64 KB for each of a
		// DatagramSocket's reads, and the datagram then copied out of it.
		var bb = ByteBuffer.wrap(buf.getData(), pos, len);
		var src:SocketAddress = try {
			__dc().receive(bb);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		// Non-blocking channel with no datagram available.
		if (src == null)
			return -1;
		__fromSocketAddress(addr, (cast src : InetSocketAddress));
		return bb.position() - pos;
	}

	/** `sendTo` without an exception for a full send buffer: -1 then. **/
	@:noCompletion private function __trySendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var target:SocketAddress = cast __toSocketAddress(addr);
		var bb = ByteBuffer.wrap(buf.getData(), pos, len);
		var n:Int = try {
			__dc().send(bb, target);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		// A non-blocking channel that cannot queue the datagram returns 0.
		return n == 0 ? -1 : n;
	}

	public function setBroadcast(b:Bool):Void {
		try
			__dc().setOption(StandardSocketOptions.SO_BROADCAST, b)
		catch (e:Dynamic)
			throw e;
	}

	// Build a java InetSocketAddress from the crossbyte Address (host:Int IPv4 in
	// network byte order, or the optional 16-byte ipv6 data).
	private function __toSocketAddress(addr:Address):InetSocketAddress {
		var ia:InetAddress;
		var v6:haxe.io.BytesData = @:privateAccess addr.ipv6;
		if (v6 != null) {
			ia = InetAddress.getByAddress(v6);
		} else {
			var ip:Int = addr.host;
			var raw = haxe.io.Bytes.alloc(4);
			raw.set(0, (ip >>> 24) & 0xFF);
			raw.set(1, (ip >>> 16) & 0xFF);
			raw.set(2, (ip >>> 8) & 0xFF);
			raw.set(3, ip & 0xFF);
			ia = InetAddress.getByAddress(raw.getData());
		}
		return new InetSocketAddress(ia, addr.port);
	}

	// Populate the crossbyte Address from the source InetSocketAddress.
	private function __fromSocketAddress(addr:Address, isa:InetSocketAddress):Void {
		addr.port = isa.getPort();
		var ia = isa.getAddress();
		var raw = ia.getAddress();
		if (raw.length == 16) {
			var bytes = haxe.io.Bytes.alloc(16);
			// Unchecked rather than cast(_, Int): a byte is an Int already, and
			// the checked cast was a type test per byte of every datagram.
			for (i in 0...16)
				bytes.set(i, (cast raw[i] : Int) & 0xFF);
			@:privateAccess addr.ipv6 = bytes.getData();
			addr.host = 0;
		} else {
			var b0 = (cast raw[0] : Int) & 0xFF;
			var b1 = (cast raw[1] : Int) & 0xFF;
			var b2 = (cast raw[2] : Int) & 0xFF;
			var b3 = (cast raw[3] : Int) & 0xFF;
			addr.host = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
			@:privateAccess addr.ipv6 = null;
		}
	}
}

#else

class UdpSocket extends Socket {
	public function new() {
		throw "Not available on this platform";
		super();
	}

	public function setBroadcast(b:Bool):Void {
		throw "Not available on this platform";
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return 0;
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return 0;
	}

	@:noCompletion private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return 0;
	}

	@:noCompletion private function __trySendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return 0;
	}
}

#end
