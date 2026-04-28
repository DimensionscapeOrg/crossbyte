package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import haxe.io.Error;
import sys.net.Socket as SysSocket;
import utest.Assert;

@:access(crossbyte.net.Socket)
class SocketTest extends utest.Test {
	public function testInvalidSocketReadWriteGuards():Void {
		var socket = new Socket();

		Assert.isTrue(throwsIOError(() -> socket.readObject()));
		Assert.isTrue(throwsIOError(() -> socket.readVarUInt()));
		Assert.isTrue(throwsIOError(() -> socket.writeObject({value: 1})));
	}

	public function testCloseToleratesPartiallyInitializedSocket():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = null;

		socket.close();

		Assert.isNull(socket.__socket);
		Assert.isFalse(socket.connected);
		Assert.isTrue(socket.__closed);
	}

	public function testOpenEventClearsClosedState():Void {
		var socket = new Socket();
		var connectedEvents = 0;
		socket.__closed = true;
		socket.addEventListener(Event.CONNECT, _ -> connectedEvents++);

		socket.socket_onOpen(null);

		Assert.isTrue(socket.connected);
		Assert.isFalse(socket.__closed);
		Assert.equals(1, connectedEvents);
	}

	public function testWriteWithoutRuntimeBuffersButDoesNotCrash():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = null;
		socket.__output = new ByteArray();
		socket.__output.endian = socket.__endian;

		socket.writeByte(42);

		Assert.equals(1, socket.bytesPending);
		Assert.isFalse(socket.__isDirty);
	}

	public function testBlockedErrorRecognitionIncludesCustomBlocked():Void {
		var socket = new Socket();

		Assert.isTrue(socket.__isBlockedError(Error.Blocked));
		Assert.isTrue(socket.__isBlockedError(Error.Custom(Error.Blocked)));
		Assert.isFalse(socket.__isBlockedError(Error.Custom("boom")));
	}

	public function testFailedConnectCleanupResetsState():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = crossbyte.core.CrossByte.current();
		socket.__connected = true;
		socket.__isConnecting = true;
		socket.__isDirty = true;
		socket.flushFull = true;
		socket.__closed = false;

		socket.__cleanupFailedConnect();

		Assert.isNull(socket.__socket);
		Assert.isNull(socket.__cbInstance);
		Assert.isFalse(socket.connected);
		Assert.isFalse(socket.__isConnecting);
		Assert.isFalse(socket.__isDirty);
		Assert.isFalse(socket.flushFull);
		Assert.isTrue(socket.__closed);
	}

	public function testInvalidHostDispatchesIOErrorWithoutSocket():Void {
		var socket = new Socket();
		var errors = 0;
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);

		socket.connect("bad host name", 80);

		Assert.equals(1, errors);
		Assert.isNull(socket.__socket);
		Assert.isFalse(socket.connected);
	}

	public function testPartialFlushRetainsUnwrittenBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(2, socket.__output.length);

		Assert.equals(4, socket.bytesPending);
		Assert.equals("cdef", readOutput(socket));
		Assert.isFalse(socket.__isDirty);
	}

	public function testZeroByteFlushRetainsAllBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(0, socket.__output.length);

		Assert.equals(6, socket.bytesPending);
		Assert.equals("abcdef", readOutput(socket));
		Assert.isFalse(socket.__isDirty);
	}

	public function testCompleteFlushClearsPendingBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(socket.__output.length, socket.__output.length);

		Assert.equals(0, socket.bytesPending);
		Assert.isFalse(socket.__isDirty);
	}

	public function testClientServerEchoOverLocalhost():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("ping");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> echoed != null, 2.0);

			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("ping", echoed);
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testIpv6ClientServerEchoOnLoopback():Void {
		var ipv6Supported = requireIpv6Loopback();
		if (!ipv6Supported) {
			Assert.isFalse(ipv6Supported);
			return;
		}

		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "::1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("pong");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("::1", server.localPort);

			pumpUntil(() -> echoed != null, 2.0);

			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("pong", echoed);
			Assert.equals("::1", server.localAddress);
			Assert.equals("::1", serverPeer.localAddress);
			Assert.equals(0, serverPeer.__socket.peer().host.ip);
			Assert.equals("::1", client.remoteAddress);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(serverPeer);
		closeServerQuietly(server);
	}

	public function testServerSocketIdlePumpDoesNotClose():Void {
		var server = new ServerSocket();
		var closeEvents = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.addEventListener(Event.CLOSE, _ -> closeEvents++);

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			CrossByte.current().pump(1 / 60, 0);

			Assert.isTrue(server.listening);
			Assert.equals(0, closeEvents);
		} catch (e:Dynamic) {
			closeServerQuietly(server);
			throw e;
		}

		closeServerQuietly(server);
	}

	private static function throwsIOError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IOError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:Socket):Void {
		try {
			if (socket != null && socket.__socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeServerQuietly(server:ServerSocket):Void {
		try {
			if (server != null && server.listening) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function requireIpv6Loopback():Bool {
		var server = new ServerSocket();
		try {
			server.bind(0, "::1");
			server.close();
			return true;
		} catch (_:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			return false;
		}
	}

	private static function socketWithOutput(value:String):Socket {
		var socket = new Socket();
		socket.__output = new ByteArray();
		socket.__output.endian = socket.__endian;
		socket.__output.writeUTFBytes(value);
		socket.__isDirty = true;
		return socket;
	}

	private static function readOutput(socket:Socket):String {
		socket.__output.position = 0;
		return socket.__output.readUTFBytes(socket.__output.length);
	}
}
