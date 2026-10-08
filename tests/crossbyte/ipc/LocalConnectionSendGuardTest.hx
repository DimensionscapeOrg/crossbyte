package crossbyte.ipc;

import crossbyte.io.ByteArray;
import crossbyte.net.Reason;
import utest.Assert;

/**
 * Focused coverage for the order of `LocalConnection.send()`'s guards, which
 * on threaded targets run with the handle's check-then-write serialized under
 * a mutex.
 *
 * These assertions pin down the single-threaded / non-cpp observable behavior:
 * sending while disconnected reports `Closed` before any payload-size
 * validation, and an invalid payload on an (otherwise) unconnected transport
 * still surfaces an error through `onError`.
 *
 * Runs under every target (including eval/interp). On non-cpp the transport is
 * never connected, so the deterministic "closed" branch is what executes; the
 * mutex calls are compiled out, so there is nothing race-dependent here.
 */
class LocalConnectionSendGuardTest extends utest.Test {
	public function testSendWhileDisconnectedReportsClosed():Void {
		var connection = new LocalConnection();
		var reasons:Array<Reason> = [];
		connection.onError = reason -> reasons.push(reason);

		connection.send(bytesOf("payload"));

		Assert.equals(1, reasons.length);
		Assert.isTrue(isClosed(reasons[0]));

		connection.close();
	}

	public function testClosedCheckPrecedesPayloadValidation():Void {
		// A null payload is invalid, but the connection is also not connected.
		// Closed is reported first.
		var connection = new LocalConnection();
		var reasons:Array<Reason> = [];
		connection.onError = reason -> reasons.push(reason);

		connection.send(null);

		Assert.equals(1, reasons.length);
		Assert.isTrue(isClosed(reasons[0]));

		connection.close();
	}

	public function testSendDoesNotInvokeDataOrReadyCallbacks():Void {
		var connection = new LocalConnection();
		var readyCount = 0;
		var dataCount = 0;
		connection.onReady = () -> readyCount++;
		connection.onData = _ -> dataCount++;
		connection.onError = _ -> {};

		connection.send(bytesOf("payload"));

		Assert.equals(0, readyCount);
		Assert.equals(0, dataCount);

		connection.close();
	}

	private static function isClosed(reason:Reason):Bool {
		return switch (reason) {
			case Closed: true;
			default: false;
		}
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}
