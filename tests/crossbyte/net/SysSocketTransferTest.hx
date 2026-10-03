package crossbyte.net;

#if (sys && !(js || php))
import crossbyte._internal.socket.BlockedError;
import haxe.io.Bytes;
import sys.net.Address;
import sys.net.Host;
import sys.net.Socket;
import sys.net.UdpSocket;
#end
import utest.Assert;

/**
	The transfers CrossByte's own read and write loops make through its
	`sys.net` sockets: `__tryRead`, `__tryWrite`, `__tryReadFrom` and
	`__trySendTo`, which answer -1 for "would block" where the standard
	`input`, `output`, `readFrom` and `sendTo` throw `Blocked`.

	The end of every pass over a non-blocking socket is a would-block: the
	read that finds it dry, the send a slow peer's window refuses. Reported
	by exceptions, a native one, thrown again in Haxe, each cost 1.9 to
	4.3 us natively and 2.4 to 4.8 us on the jvm, where the call itself is a
	few hundred nanoseconds. These cases did not compile before: the
	transfers did not exist. The standard surface is checked alongside, to
	throw as it always did.

	Not on eval, whose sockets cannot be made non-blocking: a read with
	nothing waiting would wait for good.
**/
class SysSocketTransferTest extends utest.Test {
	#if (sys && !(js || php) && !eval)
	static inline var LOOPBACK:String = "127.0.0.1";

	public function testATryReadAnswersMinusOneThenDataThenTheEnd():Void {
		var pair = connectedPair();
		if (pair == null) {
			return;
		}

		try {
			pair.client.setBlocking(false);
			var buffer = Bytes.alloc(16);

			Assert.equals(-1, @:privateAccess pair.client.__tryRead(buffer, 0, 16), "a read with nothing waiting was not -1");

			pair.accepted.output.writeString("ping");
			pair.accepted.output.flush();
			Socket.select([pair.client], null, null, 5.0);
			var read:Int = @:privateAccess pair.client.__tryRead(buffer, 0, 16);
			Assert.equals(4, read);
			Assert.equals("ping", buffer.getString(0, 4));

			pair.accepted.close();
			Socket.select([pair.client], null, null, 5.0);
			Assert.equals(0, @:privateAccess pair.client.__tryRead(buffer, 0, 16), "the end of the stream was not 0");
		} catch (e:Dynamic) {
			Assert.fail("a non-throwing read threw " + Std.string(e));
		}

		pair.close();
	}

	public function testATryWriteAnswersMinusOneWhenThePeerStopsReading():Void {
		var pair = connectedPair();
		if (pair == null) {
			return;
		}

		var refused:Bool = false;
		var error:Dynamic = null;
		try {
			pair.accepted.setBlocking(false);
			var chunk = Bytes.alloc(65536);
			// A peer that never reads: the kernel takes what its buffers hold,
			// then refuses. Bounded, should a system buffer without limit.
			for (_ in 0...4096) {
				if (@:privateAccess pair.accepted.__tryWrite(chunk, 0, chunk.length) < 0) {
					refused = true;
					break;
				}
			}
		} catch (e:Dynamic) {
			error = e;
		}

		Assert.isNull(error, "a write to a full socket threw " + Std.string(error));
		Assert.isTrue(refused, "a write to a peer that does not read was never refused");
		pair.close();
	}

	/** The standard surface throws for "would block", as it always has. **/
	public function testInputAndOutputStillThrowBlocked():Void {
		var pair = connectedPair();
		if (pair == null) {
			return;
		}

		var readError:Dynamic = null;
		try {
			pair.client.setBlocking(false);
			pair.client.input.readBytes(Bytes.alloc(16), 0, 16);
		} catch (e:Dynamic) {
			readError = e;
		}
		Assert.isTrue(BlockedError.isBlocked(readError), "an empty read threw " + Std.string(readError));

		var writeError:Dynamic = null;
		try {
			pair.accepted.setBlocking(false);
			var chunk = Bytes.alloc(65536);
			for (_ in 0...4096) {
				pair.accepted.output.writeBytes(chunk, 0, chunk.length);
			}
		} catch (e:Dynamic) {
			writeError = e;
		}
		Assert.isTrue(BlockedError.isBlocked(writeError), "a full write threw " + Std.string(writeError));
		pair.close();
	}

	#if (cpp || hxcpp || java || jvm || hl || neko)
	public function testADatagramTryReadAnswersMinusOneWhenNoneWaits():Void {
		var receiver = new UdpSocket();
		var sender = new UdpSocket();

		try {
			receiver.bind(new Host(LOOPBACK), 0);
			sender.bind(new Host(LOOPBACK), 0);
			receiver.setBlocking(false);

			var buffer = Bytes.alloc(64);
			var from = new Address();
			Assert.equals(-1, @:privateAccess receiver.__tryReadFrom(buffer, 0, buffer.length, from), "a receive with nothing waiting was not -1");

			var blocked:Dynamic = null;
			try {
				receiver.readFrom(buffer, 0, buffer.length, from);
			} catch (e:Dynamic) {
				blocked = e;
			}
			Assert.isTrue(BlockedError.isBlocked(blocked), "readFrom with nothing waiting threw " + Std.string(blocked));

			var to = new Address();
			to.setHost(new Host(LOOPBACK));
			to.port = receiver.host().port;
			Assert.equals(4, @:privateAccess sender.__trySendTo(Bytes.ofString("ping"), 0, 4, to));

			Socket.select([receiver], null, null, 5.0);
			var length:Int = @:privateAccess receiver.__tryReadFrom(buffer, 0, buffer.length, from);
			Assert.equals(4, length);
			Assert.equals("ping", buffer.getString(0, 4));
			Assert.equals(sender.host().port, from.port);
		} catch (e:Dynamic) {
			Assert.fail("a non-throwing datagram transfer threw " + Std.string(e));
		}

		closeQuietly(receiver);
		closeQuietly(sender);
	}
	#end

	static function connectedPair():Null<TransferPair> {
		var listener = new Socket();
		var client = new Socket();
		try {
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(1);
			client.connect(new Host(LOOPBACK), listener.host().port);
			var accepted = listener.accept();
			return new TransferPair(listener, client, accepted);
		} catch (e:Dynamic) {
			Assert.fail("could not connect over loopback: " + Std.string(e));
			closeQuietly(client);
			closeQuietly(listener);
			return null;
		}
	}

	static function closeQuietly(socket:Socket):Void {
		if (socket != null) {
			try socket.close() catch (_:Dynamic) {}
		}
	}
	#end
}

#if (sys && !(js || php) && !eval)
private class TransferPair {
	public var listener:Socket;
	public var client:Socket;
	public var accepted:Socket;

	public function new(listener:Socket, client:Socket, accepted:Socket) {
		this.listener = listener;
		this.client = client;
		this.accepted = accepted;
	}

	public function close():Void {
		for (socket in [accepted, client, listener]) {
			try socket.close() catch (_:Dynamic) {}
		}
	}
}
#end
