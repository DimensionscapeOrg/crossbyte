package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.io.ByteArray;
import utest.Assert;

@:access(crossbyte.net.DatagramSocket)
class DatagramSocketTest extends utest.Test {
	public function testBindEphemeralPortSetsLocalEndpoint():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		try {
			socket.bind(0, "127.0.0.1");

			Assert.isTrue(socket.bound);
			Assert.equals("127.0.0.1", socket.localAddress);
			Assert.isTrue(socket.localPort > 0);
		} catch (e:Dynamic) {
			closeQuietly(socket);
			throw e;
		}

		closeQuietly(socket);
	}

	public function testValidationErrors():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var bytes = bytesOf("x");

		Assert.isTrue(throwsRangeError(() -> socket.bind(-1)));
		Assert.isTrue(throwsRangeError(() -> socket.connect("127.0.0.1", 65536)));
		Assert.isTrue(throwsRangeError(() -> socket.connect("127.0.0.1", 0)));
		Assert.isTrue(throwsArgumentError(() -> socket.connect("", 1234)));
		Assert.isTrue(throwsArgumentError(() -> socket.send(bytes)));
		Assert.isTrue(throwsArgumentError(() -> socket.send(null, 0, 0, "127.0.0.1", 1234)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, 0, 0, "127.0.0.1", 0)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, -1, 0, "127.0.0.1", 1234)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, 0, bytes.length + 1, "127.0.0.1", 1234)));

		socket.bind(0, "127.0.0.1");
		socket.connect("127.0.0.1", socket.localPort);
		Assert.isTrue(throwsIllegalOperationError(() -> socket.send(bytes, 0, 0, "127.0.0.1", socket.localPort)));

		closeQuietly(socket);
	}

	public function testReceiveRegistrationFollowsDataListener():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var listener = (_:DatagramSocketDataEvent) -> {};

		try {
			socket.bind(0, "127.0.0.1");
			socket.receive();

			Assert.isFalse(socket.__registered);
			socket.addEventListener(DatagramSocketDataEvent.DATA, listener);
			Assert.isTrue(socket.__registered);

			socket.removeEventListener(DatagramSocketDataEvent.DATA, listener);
			Assert.isFalse(socket.__registered);
			Assert.isTrue(socket.receiving);
		} catch (e:Dynamic) {
			closeQuietly(socket);
			throw e;
		}

		closeQuietly(socket);
	}

	public function testCloseStopsReceivingAndDispatchesOnce():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var closeEvents = 0;
		socket.addEventListener(Event.CLOSE, _ -> closeEvents++);
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> {});
		socket.receive();

		socket.close();
		socket.close();

		Assert.isFalse(socket.bound);
		Assert.isFalse(socket.connected);
		Assert.isFalse(socket.receiving);
		Assert.isFalse(socket.__registered);
		Assert.equals(1, closeEvents);
	}

	public function testSendReceiveOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;
		var srcPort = 0;
		var dstPort = 0;

		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
				srcPort = event.srcPort;
				dstPort = event.dstPort;
			});
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			sender.send(bytesOf("ping"), 0, 0, "127.0.0.1", receiver.localPort);

			pumpUntil(() -> payload != null, 2.0);

			Assert.equals("ping", payload);
			Assert.equals(sender.localPort, srcPort);
			Assert.equals(receiver.localPort, dstPort);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	public function testConnectedSendUsesDefaultEndpoint():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;

		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
			});
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			sender.connect("127.0.0.1", receiver.localPort);
			sender.send(bytesOf("connected"));

			pumpUntil(() -> payload != null, 2.0);

			Assert.isTrue(sender.connected);
			Assert.equals("connected", payload);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function requireDatagramSupport():Bool {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:DatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function throwsArgumentError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:ArgumentError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function throwsIllegalOperationError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IllegalOperationError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function throwsRangeError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:RangeError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
