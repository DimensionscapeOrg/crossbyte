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
#end

class Address {
	public var host:Int;
	public var port:Int;

	private var ipv6(default, null):haxe.io.BytesData;

	public function new() {
		host = 0;
		port = 0;
		ipv6 = null;
	}

	public function setHost(value:Host):Void {
		host = value.ip;
		ipv6 = Reflect.field(value, "ipv6");
	}

	public function getHost():Host {
		var resolved:Host = Type.createEmptyInstance(Host);
		untyped resolved.ip = host;
		untyped resolved.ipv6 = ipv6;
		untyped resolved.host = ipv6 == null
			? #if (cpp || hxcpp) NativeSocket.host_to_string(host) #else "0.0.0.0" #end
			: #if (cpp || hxcpp) NativeSocket.host_to_string_ipv6(ipv6) #else "::1" #end;
		return resolved;
	}

	public function compare(a:Address):Int {
		if (port != a.port) {
			return a.port - port;
		}

		var thisHost = getHost().toString();
		var thatHost = a.getHost().toString();
		return thatHost > thisHost ? 1 : (thatHost < thisHost ? -1 : 0);
	}

	public function clone():Address {
		var copy = new Address();
		copy.host = host;
		copy.port = port;
		copy.ipv6 = ipv6;
		return copy;
	}
}
