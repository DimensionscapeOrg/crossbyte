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

import cpp.NativeSocket;
import crossbyte._internal.net.NativeSocketAddress;
import haxe.io.Error;

@:coreApi
class UdpSocket extends Socket {
	override function __createSocket(ipv6:Bool):Dynamic {
		return ipv6 ? NativeSocket.socket_new_ip(true, true) : NativeSocket.socket_new(true);
	}

	public function sendTo(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		return try {
			NativeSocketAddress.sendTo(untyped this.__s, buf.getData(), pos, len, addr);
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
			r = NativeSocketAddress.recvFrom(untyped this.__s, buf.getData(), pos, len, addr);
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

	public function setBroadcast(b:Bool):Void {
		NativeSocket.socket_set_broadcast(untyped this.__s, b);
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
		var target:SocketAddress = cast __toSocketAddress(addr);
		var bb = ByteBuffer.wrap(buf.getData(), pos, len);
		var n:Int = try {
			__dc().send(bb, target);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		// A non-blocking channel that cannot queue the datagram returns 0.
		if (n == 0)
			throw Blocked;
		return n;
	}

	public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:Address):Int {
		var bb = ByteBuffer.allocate(len);
		var src:SocketAddress = try {
			__dc().receive(bb);
		} catch (e:Dynamic) {
			throw Custom(e);
		}
		// Non-blocking channel with no datagram available.
		if (src == null)
			throw Blocked;
		bb.flip();
		var n:Int = bb.remaining();
		if (n == 0)
			throw new haxe.io.Eof();
		var data = buf.getData();
		bb.get(data, pos, n);
		__fromSocketAddress(addr, cast(src, InetSocketAddress));
		return n;
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
			for (i in 0...16)
				bytes.set(i, cast(raw[i], Int) & 0xFF);
			@:privateAccess addr.ipv6 = bytes.getData();
			addr.host = 0;
		} else {
			var b0 = cast(raw[0], Int) & 0xFF;
			var b1 = cast(raw[1], Int) & 0xFF;
			var b2 = cast(raw[2], Int) & 0xFF;
			var b3 = cast(raw[3], Int) & 0xFF;
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
}

#end
