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

// This module replaces the standard library's sys.net.Socket on every target,
// so a target without a branch here falls into the one at the bottom, which
// throws. hl and neko did, and their own sys.ssl.Socket extends this class and
// reaches into it, SocketHandle, __s, init() and the socket_* primitives,
// so the whole TLS stack failed to compile inside Haxe's std, with errors
// naming nothing in CrossByte. The two branches below are each target's
// standard implementation, private surface included, with the changes their
// comments give. Both are IPv4 only, as the targets' natives are.
#if hl

import haxe.io.Error;

#if doc_gen
@:noDoc enum SocketHandle {}
#else
@:noDoc typedef SocketHandle = hl.Abstract<"hl_socket">;
#end

@:access(sys.net.Socket)
private class SocketOutput extends haxe.io.Output {
	var sock:Socket;

	public function new(s) {
		this.sock = s;
	}

	public override function writeByte(c:Int) {
		var k = Socket.socket_send_char(sock.__s, c);
		if (k < 0) {
			if (k == -1)
				throw Blocked;
			throw new haxe.io.Eof();
		}
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw haxe.io.Error.OutsideBounds;
		var n = Socket.socket_send(sock.__s, buf.getData().bytes, pos, len);
		if (n < 0) {
			if (n == -1)
				throw Blocked;
			throw new haxe.io.Eof();
		}
		return n;
	}

	public override function close() {
		sock.close();
	}
}

@:access(sys.net.Socket)
private class SocketInput extends haxe.io.Input {
	var sock:Socket;
	var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);

	public function new(s) {
		sock = s;
	}

	/**
		Through `readBytes`. The native `socket_recv_char` answers -2 both at
		the end of the stream and on a failure, so a byte read could not tell
		a peer that finished from one that was cut off.
	**/
	public override function readByte():Int {
		readBytes(one, 0, 1);
		return one.get(0);
	}

	/**
		0 is the end of the stream and -2 a failure: a reset, or a socket
		already closed. The standard library reported both as `Eof`, and a
		body whose length is its connection's end, HTTP/1.0 style, came
		back complete when the connection was reset partway through it. The
		other targets raise the failure.
	**/
	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos + len > buf.length)
			throw haxe.io.Error.OutsideBounds;
		var r = Socket.socket_recv(sock.__s, buf.getData().bytes, pos, len);
		if (r <= 0) {
			if (r == -1)
				throw Blocked;
			if (r == 0)
				throw new haxe.io.Eof();
			throw Custom("Connection failed while reading");
		}
		return r;
	}

	public override function close() {
		sock.close();
	}
}

/**
	Where `select` builds its descriptor sets: one per thread.

	The standard library keeps a single buffer in a static and grows it in
	place, shared by every thread that selects. Each runtime selects on its own
	thread, so two runtimes wrote their sets over each other's. Two runtimes on
	two threads each saw `select` fail with "Error while waiting on socket"
	about two hundred times in twelve seconds, every failure a tick whose
	sockets went unserviced; two threads selecting as fast as they could got an
	answer for the wrong sockets up to one time in seven.
**/
private class SelectScratch {
	public var bytes:hl.Bytes = null;
	public var size:Int = 0;

	public function new() {}
}

@:coreApi
@:keepInit
class Socket {
	private var __s:SocketHandle;

	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	// socket_init is WSAStartup on Windows, and every call below fails
	// without it, @:keepInit keeps this even where nothing names the class.
	static function __init__():Void {
		socket_init();
	}

	public function new():Void {
		init();
	}

	function init():Void {
		if (__s == null)
			__s = socket_new(false);
		input = new SocketInput(this);
		output = new SocketOutput(this);
	}

	public function close():Void {
		if (__s != null) {
			socket_close(__s);
			__s = null;
		}
	}

	public function read():String {
		return input.readAll().toString();
	}

	public function write(content:String):Void {
		output.writeString(content);
	}

	public function connect(host:Host, port:Int):Void {
		if (!socket_connect(__s, host.ip, port))
			throw new Sys.SysError("Failed to connect on " + host.toString() + ":" + port);
	}

	public function listen(connections:Int):Void {
		if (!socket_listen(__s, connections))
			throw new Sys.SysError("listen() failure");
	}

	public function shutdown(read:Bool, write:Bool):Void {
		if (!socket_shutdown(__s, read, write))
			throw new Sys.SysError("shutdown() failure");
	}

	public function bind(host:Host, port:Int):Void {
		if (!socket_bind(__s, host.ip, port))
			throw new Sys.SysError("Cannot bind socket on " + host + ":" + port);
	}

	/**
		The standard library answers null when nothing is waiting on a
		non-blocking listener. Every caller here treats an accept as a socket or
		a would-block, as the other targets report it, and null is neither: it
		went on to be registered as a connection.

		hl's accept answers null for any failure, so a real one, a process
		out of descriptors, reads as nothing waiting too. The connection stays
		queued and is asked for again, which is all a caller could do anyway.
	**/
	public function accept():Socket {
		var c = socket_accept(__s);
		if (c == null)
			throw Blocked;
		var s:Socket = Type.createEmptyInstance(Socket);
		s.__s = c;
		s.input = new SocketInput(s);
		s.output = new SocketOutput(s);
		return s;
	}

	public function peer():{host:Host, port:Int} {
		var ip = 0, port = 0;
		if (!socket_peer(__s, ip, port))
			return null;
		return {host: __hostOf(ip), port: port};
	}

	public function host():{host:Host, port:Int} {
		var ip = 0, port = 0;
		if (!socket_host(__s, ip, port))
			return null;
		return {host: __hostOf(ip), port: port};
	}

	public function setTimeout(timeout:Float):Void {
		if (!socket_set_timeout(__s, timeout))
			throw new Sys.SysError("setTimeout() failure");
	}

	public function waitForRead():Void {
		select([this], null, null, null);
	}

	public function setBlocking(b:Bool):Void {
		if (!socket_set_blocking(__s, b))
			throw new Sys.SysError("setBlocking() failure");
	}

	public function setFastSend(b:Bool):Void {
		if (!socket_set_fast_send(__s, b))
			throw new Sys.SysError("setFastSend() failure");
	}

	/**
		A Host for an address the system reported. The standard library leaves
		its `host` text null here, and `peer().host.host` is how
		ServerWebSocket names a client; every other target fills it in.
	**/
	private static function __hostOf(ip:Int):Host {
		var h:Host = Type.createEmptyInstance(Host);
		@:privateAccess h.ip = ip;
		@:privateAccess h.host = h.toString();
		return h;
	}

	private static var __scratch:sys.thread.Tls<SelectScratch> = new sys.thread.Tls();

	static function makeArray(a:Array<Socket>):hl.NativeArray<SocketHandle> {
		if (a == null)
			return null;
		var arr = new hl.NativeArray(a.length);
		for (i in 0...a.length)
			arr[i] = a[i].__s;
		return arr;
	}

	static function outArray(a:hl.NativeArray<SocketHandle>, original:Array<Socket>):Array<Socket> {
		var out = [];
		if (a == null)
			return out;
		var i = 0, p = 0;
		var max = original.length;
		while (i < max) {
			var sh = a[i++];
			if (sh == null)
				break;
			while (original[p].__s != sh)
				p++;
			out.push(original[p++]);
		}
		return out;
	}

	static function setSize(a:hl.NativeArray<SocketHandle>):Int {
		if (a == null)
			return 0;
		var size = socket_fd_size(a.length);
		// More sockets than the system's descriptor set holds. Summed as it
		// was, the -1 shrank the buffer, and the native select then built its
		// sets past the end of it.
		if (size < 0)
			throw "Too many sockets in select: " + a.length;
		return size;
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var sread = makeArray(read);
		var swrite = makeArray(write);
		var sothers = makeArray(others);
		var tmpSize = setSize(sread) + setSize(swrite) + setSize(sothers);
		var scratch = __scratch.value;
		if (scratch == null) {
			scratch = new SelectScratch();
			__scratch.value = scratch;
		}
		if (tmpSize > scratch.size) {
			scratch.bytes = new hl.Bytes(tmpSize);
			scratch.size = tmpSize;
		}
		if (!socket_select(sread, swrite, sothers, scratch.bytes, scratch.size, timeout == null ? -1 : timeout))
			throw "Error while waiting on socket";
		return {
			read: outArray(sread, read),
			write: outArray(swrite, write),
			others: outArray(sothers, others),
		};
	}

	@:hlNative("std", "socket_init") static function socket_init():Void {}

	@:hlNative("std", "socket_new") static function socket_new(udp:Bool):SocketHandle {
		return null;
	}

	@:hlNative("std", "socket_close") static function socket_close(s:SocketHandle):Void {}

	@:hlNative("std", "socket_connect") static function socket_connect(s:SocketHandle, host:Int, port:Int):Bool {
		return true;
	}

	@:hlNative("std", "socket_listen") static function socket_listen(s:SocketHandle, count:Int):Bool {
		return true;
	}

	@:hlNative("std", "socket_bind") static function socket_bind(s:SocketHandle, host:Int, port:Int):Bool {
		return true;
	}

	@:hlNative("std", "socket_accept") static function socket_accept(s:SocketHandle):SocketHandle {
		return null;
	}

	@:hlNative("std", "socket_peer") static function socket_peer(s:SocketHandle, host:hl.Ref<Int>, port:hl.Ref<Int>):Bool {
		return true;
	}

	@:hlNative("std", "socket_host") static function socket_host(s:SocketHandle, host:hl.Ref<Int>, port:hl.Ref<Int>):Bool {
		return true;
	}

	@:hlNative("std", "socket_set_timeout") static function socket_set_timeout(s:SocketHandle, timeout:Float):Bool {
		return true;
	}

	@:hlNative("std", "socket_shutdown") static function socket_shutdown(s:SocketHandle, read:Bool, write:Bool):Bool {
		return true;
	}

	@:hlNative("std", "socket_set_blocking") static function socket_set_blocking(s:SocketHandle, b:Bool):Bool {
		return true;
	}

	@:hlNative("std", "socket_set_fast_send") static function socket_set_fast_send(s:SocketHandle, b:Bool):Bool {
		return true;
	}

	@:hlNative("std", "socket_fd_size") static function socket_fd_size(count:Int):Int {
		return 0;
	}

	@:hlNative("std", "socket_select") static function socket_select(read:hl.NativeArray<SocketHandle>, write:hl.NativeArray<SocketHandle>,
			other:hl.NativeArray<SocketHandle>, tmpData:hl.Bytes, tmpSize:Int, timeout:Float):Bool {
		return false;
	}

	@:hlNative("std", "socket_send_char") static function socket_send_char(s:SocketHandle, c:Int):Int {
		return 0;
	}

	@:hlNative("std", "socket_send") static function socket_send(s:SocketHandle, bytes:hl.Bytes, pos:Int, len:Int):Int {
		return 0;
	}

	@:hlNative("std", "socket_recv") static function socket_recv(s:SocketHandle, bytes:hl.Bytes, pos:Int, len:Int):Int {
		return 0;
	}
}

#elseif neko

import haxe.io.Error;

@:callable
@:coreType
abstract SocketHandle {}

private class SocketOutput extends haxe.io.Output {
	var __s:SocketHandle;

	public function new(s) {
		__s = s;
	}

	public override function writeByte(c:Int) {
		try {
			socket_send_char(__s, c);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else if (e == "EOF")
				throw new haxe.io.Eof();
			else
				throw Custom(e);
		}
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		return try {
			socket_send(__s, buf.getData(), pos, len);
		} catch (e:Dynamic) {
			if (e == "Blocking")
				throw Blocked;
			else
				throw Custom(e);
		}
	}

	public override function close() {
		super.close();
		if (__s != null)
			socket_close(__s);
	}

	private static var socket_close = neko.Lib.load("std", "socket_close", 1);
	private static var socket_send_char = neko.Lib.load("std", "socket_send_char", 2);
	private static var socket_send = neko.Lib.load("std", "socket_send", 4);
}

private class SocketInput extends haxe.io.Input {
	var __s:SocketHandle;
	var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);

	public function new(s) {
		__s = s;
	}

	/**
		Through `readBytes`. neko's `socket_recv_char` raises the same error at
		the end of the stream as on a failure, and the standard library read
		every one of them as `Eof`: a connection reset mid-line looked like a
		peer that had finished.
	**/
	public override function readByte():Int {
		readBytes(one, 0, 1);
		return one.get(0);
	}

	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		var r;
		try {
			r = socket_recv(__s, buf.getData(), pos, len);
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
			socket_close(__s);
	}

	private static var socket_recv = neko.Lib.load("std", "socket_recv", 4);
	private static var socket_close = neko.Lib.load("std", "socket_close", 1);
}

@:coreApi
class Socket {
	private var __s:SocketHandle;

	public var input(default, null):haxe.io.Input;
	public var output(default, null):haxe.io.Output;
	public var custom:Dynamic;

	public function new():Void {
		init();
	}

	private function init():Void {
		if (__s == null)
			__s = socket_new(false);
		input = new SocketInput(__s);
		output = new SocketOutput(__s);
	}

	/**
		Once, however often it is called. neko's socket_close throws when
		handed a socket it already closed, and the standard library passed it
		the same handle every time; the other targets let a second close
		through.
	**/
	public function close():Void {
		var socket = __s;
		__s = null;
		if (socket != null)
			socket_close(socket);
		untyped {
			input.__s = null;
			output.__s = null;
		}
		input.close();
		output.close();
	}

	public function read():String {
		return new String(socket_read(__s));
	}

	public function write(content:String):Void {
		socket_write(__s, untyped content.__s);
	}

	public function connect(host:Host, port:Int):Void {
		try {
			socket_connect(__s, host.ip, port);
		} catch (s:String) {
			if (s == "std@socket_connect")
				throw "Failed to connect on " + host.toString() + ":" + port;
			else if (s == "Blocking") {
				// Do nothing, this is not a real error, it simply indicates
				// that a non-blocking connect is in progress
			} else
				neko.Lib.rethrow(s);
		}
	}

	public function listen(connections:Int):Void {
		socket_listen(__s, connections);
	}

	public function shutdown(read:Bool, write:Bool):Void {
		socket_shutdown(__s, read, write);
	}

	public function bind(host:Host, port:Int):Void {
		socket_bind(__s, host.ip, port);
	}

	public function accept():Socket {
		var c = socket_accept(__s);
		var s = Type.createEmptyInstance(Socket);
		s.__s = c;
		s.input = new SocketInput(c);
		s.output = new SocketOutput(c);
		return s;
	}

	/**
		Null when there is no peer, as on the other targets. neko's natives
		throw there instead, which the standard library's own null check never
		saw, and it named every peer 127.0.0.1, resolving that name to have a
		Host to overwrite the address of.
	**/
	public function peer():{host:Host, port:Int} {
		var a:Dynamic = try socket_peer(__s) catch (_:Dynamic) null;
		if (a == null) {
			return null;
		}
		return {host: __hostOf(a[0]), port: a[1]};
	}

	public function host():{host:Host, port:Int} {
		var a:Dynamic = try socket_host(__s) catch (_:Dynamic) null;
		if (a == null) {
			return null;
		}
		return {host: __hostOf(a[0]), port: a[1]};
	}

	public function setTimeout(timeout:Float):Void {
		socket_set_timeout(__s, timeout);
	}

	public function waitForRead():Void {
		select([this], null, null, null);
	}

	public function setBlocking(b:Bool):Void {
		socket_set_blocking(__s, b);
	}

	public function setFastSend(b:Bool):Void {
		socket_set_fast_send(__s, b);
	}

	private static function __hostOf(ip:Int):Host {
		var h:Host = Type.createEmptyInstance(Host);
		untyped h.ip = ip;
		untyped h.host = h.toString();
		return h;
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var c = untyped __dollar__hnew(1);
		var f = function(a:Array<Socket>) {
			if (a == null)
				return null;
			untyped {
				var r = __dollar__amake(a.length);
				var i = 0;
				while (i < a.length) {
					r[i] = a[i].__s;
					__dollar__hadd(c, a[i].__s, a[i]);
					i += 1;
				}
				return r;
			}
		}
		var neko_array = socket_select(f(read), f(write), f(others), timeout);

		var g = function(a):Array<Socket> {
			if (a == null)
				return null;

			var r = new Array();
			var i = 0;
			while (i < untyped __dollar__asize(a)) {
				var t = untyped __dollar__hget(c, a[i], null);
				if (t == null)
					throw "Socket object not found.";
				r[i] = t;
				i += 1;
			}
			return r;
		}

		return {
			read: g(neko_array[0]),
			write: g(neko_array[1]),
			others: g(neko_array[2])
		};
	}

	private static var socket_new = neko.Lib.load("std", "socket_new", 1);
	private static var socket_close = neko.Lib.load("std", "socket_close", 1);
	private static var socket_write = neko.Lib.load("std", "socket_write", 2);
	private static var socket_read = neko.Lib.load("std", "socket_read", 1);
	private static var socket_connect = neko.Lib.load("std", "socket_connect", 3);
	private static var socket_listen = neko.Lib.load("std", "socket_listen", 2);
	private static var socket_select = neko.Lib.load("std", "socket_select", 4);
	private static var socket_bind = neko.Lib.load("std", "socket_bind", 3);
	private static var socket_accept = neko.Lib.load("std", "socket_accept", 1);
	private static var socket_peer = neko.Lib.load("std", "socket_peer", 1);
	private static var socket_host = neko.Lib.load("std", "socket_host", 1);
	private static var socket_set_timeout = neko.Lib.load("std", "socket_set_timeout", 2);
	private static var socket_shutdown = neko.Lib.load("std", "socket_shutdown", 3);
	private static var socket_set_blocking = neko.Lib.load("std", "socket_set_blocking", 2);
	private static var socket_set_fast_send = neko.Lib.loadLazy("std", "socket_set_fast_send", 2);
}

#elseif (cpp || hxcpp)

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
			var input = new SocketInput(sc);
			input.timeout = __timeout;
			this.input = input;
			this.output = new SocketOutput(sc);
		} catch (e:Dynamic)
			throw e;
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
		// The selector `select` uses, for the same reason: opening one here
		// costs a loopback socket pair on Windows, and closing it leaves them
		// in TIME_WAIT. Cancelled and flushed after, so the next caller on
		// this thread starts clean.
		var selector = __threadSelector();
		try {
			if (channel.isBlocking())
				channel.configureBlocking(false);
			channel.register(selector, SelectionKey.OP_READ);
			selector.select();
		} catch (e:Dynamic) {}
		try {
			var keys = selector.keys().iterator();
			while (keys.hasNext()) {
				var k:SelectionKey = keys.next();
				k.cancel();
			}

			selector.selectNow();
		} catch (e:Dynamic) {}
	}

	public function setBlocking(b:Bool):Void {
		__blocking = b;

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

	/**
		The selector `select` uses: one per thread, opened once and kept.

		It used to be opened and closed on every call. On Windows a `Selector`
		builds its wakeup pipe out of a loopback socket pair, so each open cost
		two sockets and each close left them in TIME_WAIT for the best part of a
		minute. `SocketRegistry` calls `select` once per tick, so a runtime at
		sixty ticks a second put a hundred and twenty sockets a second into
		TIME_WAIT and worked through the whole ephemeral range, about sixteen
		thousand on Windows, in a couple of minutes. Everything socket-shaped
		then failed at once: "Address already in use" out of a connect, and
		"Unable to establish loopback connection" out of the JVM's own pipe
		setup. Measured at two thousand calls leaving one thousand seven hundred
		and ninety-six sockets behind.

		Keeping it is safe because the call already cancels every key it
		registers before returning. The `selectNow` at the end is what makes
		those cancellations take effect, so the next call starts clean.

		Per thread rather than shared: each runtime ticks on its own thread, and
		a `Selector` is not safe to use from several at once.
	**/
	@:noCompletion private static var __selectors:JThreadLocal = new JThreadLocal();

	/**
		A blocking NIO channel has no read timeout, SO_TIMEOUT reaches only
		the stream API, never `channel.read`, so `setTimeout` was stored and
		never read, and a read with nothing coming waited for ever: the HTTP
		client's idle limit did nothing here. Waiting for readability on the
		thread's selector first gives the timeout the other targets honour.
		The TLS socket calls this too, before it reads ciphertext.
	**/
	@:noCompletion private static function __awaitReadable(channel:SocketChannel, timeout:Float):Void {
		if (timeout <= 0 || channel == null || !channel.isBlocking()) {
			return;
		}

		var selector = __threadSelector();
		var ready:Int = 0;
		var failure:Dynamic = null;
		try {
			channel.configureBlocking(false);
			channel.register(selector, SelectionKey.OP_READ);
			// 0 would mean no limit to select; the shortest real wait is 1 ms.
			var millis:Float = Math.ceil(timeout * 1000);
			ready = selector.select(haxe.Int64.fromFloat(millis < 1 ? 1 : millis));
		} catch (e:Dynamic) {
			failure = e;
		}
		try {
			var keys = selector.keys().iterator();
			while (keys.hasNext()) {
				var k:SelectionKey = keys.next();
				k.cancel();
			}
			selector.selectNow();
		} catch (_:Dynamic) {}
		try {
			channel.configureBlocking(true);
		} catch (e:Dynamic) {
			if (failure == null) {
				failure = e;
			}
		}

		if (failure != null) {
			throw Custom(failure);
		}
		if (ready == 0) {
			throw Custom("Timeout");
		}
	}

	@:noCompletion private static function __threadSelector():Selector {
		var existing:Dynamic = __selectors.get();

		if (existing == null) {
			existing = Selector.open();
			__selectors.set(existing);
		}

		return cast existing;
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		var resRead:Array<Socket> = [];
		var resWrite:Array<Socket> = [];
		var resOthers:Array<Socket> = [];

		var selector = __threadSelector();
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

			// Cancelling only marks a key; the registration is not released
			// until the next select. Without this, the next call would register
			// the same channel again and be met with a CancelledKeyException.
			selector.selectNow();
		} catch (e:Dynamic) {}

		return {read: resRead, write: resWrite, others: resOthers};
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
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function close():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function read():String {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function write(content:String):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function connect(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function listen(connections:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function shutdown(read:Bool, write:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function bind(host:Host, port:Int):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function accept():Socket {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function peer():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function host():{host:Host, port:Int} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function setTimeout(timeout:Float):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function waitForRead():Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function setBlocking(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public function setFastSend(b:Bool):Void {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}

	public static function select(read:Array<Socket>, write:Array<Socket>, others:Array<Socket>,
			?timeout:Float):{read:Array<Socket>, write:Array<Socket>, others:Array<Socket>} {
		throw "sys.net.Socket shim is only supported on cpp, hxcpp, eval, hl, neko, java and jvm targets";
	}
}

#end
