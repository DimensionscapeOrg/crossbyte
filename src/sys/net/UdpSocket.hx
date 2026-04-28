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
