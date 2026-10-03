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
	by exceptions -- a native one, thrown again in Haxe -- each cost 1.9 to
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

	#if cpp
	/**
		The transfers on a TLS session, through every outcome a read loop
		meets: -1 while the handshake waits on the peer, however many passes
		it takes; -1 for a record that carries nothing to read -- the TLS 1.3
		session ticket a server sends once the handshake is done -- and for a
		session read dry; the bytes as they arrive; -1 when a blocking
		socket's read times out; and 0 at the end of the stream. A client
		reads through its own session (`AlpnSocket`), a socket `accept` made
		through its `input`, the exception taken inside; both are checked.

		These are the conditions a client-certificate upgrade that failed on
		Linux was suspected of meeting, after the transfers stopped throwing
		for "would block". Each maps as it did through `input`.
	**/
	public function testTlsTransfersAnswerMinusOneThroughTheHandshakeThenDataThenTheEnd():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var listener = new crossbyte._internal.socket.AlpnSocket();
		var client = new crossbyte._internal.socket.AlpnSocket();
		var accepted:sys.ssl.Socket = null;
		try {
			listener.verifyCert = false;
			listener.setCertificate(@:privateAccess fixture.certificate.__native, @:privateAccess fixture.key.__native);
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(1);

			client.verifyCert = false;
			client.setBlocking(false);
			try {
				client.connect(new Host(LOOPBACK), listener.host().port);
			} catch (e:Dynamic) {
				// The connect, or the handshake behind it, waiting on the peer.
				if (!BlockedError.isBlocked(e)) {
					throw e;
				}
			}
			Socket.select([listener], null, null, 5.0);
			accepted = cast listener.accept();
			accepted.setBlocking(false);

			// Each side's handshake is stepped by its reads, as a runtime steps
			// it, and every read until both are done is -1.
			var buffer = Bytes.alloc(256);
			var deadline:Float = haxe.Timer.stamp() + 10.0;
			var passes:Int = 0;
			var midHandshake:Array<Int> = [];
			while (!(@:privateAccess client.handshakeDone && @:privateAccess accepted.handshakeDone) && haxe.Timer.stamp() < deadline) {
				var fromClient:Int = @:privateAccess client.__tryRead(buffer, 0, buffer.length);
				var fromServer:Int = @:privateAccess accepted.__tryRead(buffer, 0, buffer.length);
				if (fromClient != -1 || fromServer != -1) {
					midHandshake.push(fromClient);
					midHandshake.push(fromServer);
					break;
				}
				passes++;
				Socket.select([client, accepted], null, null, 0.05);
			}
			Assert.same([], midHandshake, "a read during the handshake was not -1 (client, server)");
			Assert.isTrue(@:privateAccess client.handshakeDone && @:privateAccess accepted.handshakeDone, "the handshake did not finish");
			Assert.isTrue(passes > 1, "the handshake finished in one pass, so no read met it waiting");

			// What the server sent after its handshake -- a TLS 1.3 session
			// ticket -- carries nothing for the client to read.
			Socket.select([client], null, null, 0.5);
			Assert.equals(-1, @:privateAccess client.__tryRead(buffer, 0, buffer.length), "a read of what follows the handshake was not -1");

			Assert.equals(5, @:privateAccess client.__tryWrite(Bytes.ofString("hello"), 0, 5));
			Assert.equals(5, readWithin(accepted, buffer, 5.0), "the server read nothing");
			Assert.equals("hello", buffer.getString(0, 5));
			Assert.equals(-1, @:privateAccess accepted.__tryRead(buffer, 0, buffer.length), "a dry session's read was not -1");

			Assert.equals(5, @:privateAccess accepted.__tryWrite(Bytes.ofString("world"), 0, 5));
			Assert.equals(5, readWithin(client, buffer, 5.0), "the client read nothing");
			Assert.equals("world", buffer.getString(0, 5));
			Assert.equals(-1, @:privateAccess client.__tryRead(buffer, 0, buffer.length), "a dry session's read was not -1");

			// A blocking socket whose read times out reads as "would block",
			// as the standard surface throws Blocked for it.
			client.setBlocking(true);
			client.setTimeout(0.2);
			Assert.equals(-1, @:privateAccess client.__tryRead(buffer, 0, buffer.length), "a read that timed out was not -1");
			var timedOut:Dynamic = null;
			try {
				client.input.readBytes(buffer, 0, buffer.length);
			} catch (e:Dynamic) {
				timedOut = e;
			}
			Assert.isTrue(BlockedError.isBlocked(timedOut), "input's read that timed out threw " + Std.string(timedOut));

			client.close();
			Socket.select([accepted], null, null, 5.0);
			Assert.equals(0, @:privateAccess accepted.__tryRead(buffer, 0, buffer.length), "the end of a TLS stream was not 0");
		} catch (e:Dynamic) {
			Assert.fail("a TLS transfer threw " + Std.string(e));
		}

		closeQuietly(accepted);
		closeQuietly(client);
		closeQuietly(listener);
	}

	/**
		A peer that does not speak TLS is a failure, which throws, on either
		side: it is no "would block", which would wait on it for good, and no
		end of the stream.
	**/
	public function testATlsTransferWithAPeerSpeakingPlainTextThrows():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var buffer = Bytes.alloc(256);

		// A TLS server read by a plain client's request.
		var listener = new crossbyte._internal.socket.AlpnSocket();
		var plain = new Socket();
		var accepted:sys.ssl.Socket = null;
		var serverError:Dynamic = null;
		try {
			listener.verifyCert = false;
			listener.setCertificate(@:privateAccess fixture.certificate.__native, @:privateAccess fixture.key.__native);
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(1);
			plain.connect(new Host(LOOPBACK), listener.host().port);
			plain.output.writeString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
			Socket.select([listener], null, null, 5.0);
			accepted = cast listener.accept();
			accepted.setBlocking(false);
			Socket.select([accepted], null, null, 5.0);
			try {
				var read:Int = @:privateAccess accepted.__tryRead(buffer, 0, buffer.length);
				serverError = "answered " + read;
			} catch (e:Dynamic) {
				serverError = e;
			}
		} catch (e:Dynamic) {
			Assert.fail("could not set the server case up: " + Std.string(e));
		}
		Assert.isFalse(serverError == null || Std.string(serverError).indexOf("answered") == 0, "a TLS server's read of plain text did not throw: " + Std.string(serverError));
		Assert.isFalse(BlockedError.isBlocked(serverError), "a TLS server's read of plain text was taken for would-block");
		closeQuietly(accepted);
		closeQuietly(plain);
		closeQuietly(listener);

		// A TLS client read by a plain server's answer.
		var plainListener = new Socket();
		var client = new crossbyte._internal.socket.AlpnSocket();
		var plainAccepted:Socket = null;
		var clientError:Dynamic = null;
		try {
			plainListener.bind(new Host(LOOPBACK), 0);
			plainListener.listen(1);
			client.verifyCert = false;
			client.setBlocking(false);
			try {
				client.connect(new Host(LOOPBACK), plainListener.host().port);
			} catch (e:Dynamic) {
				if (!BlockedError.isBlocked(e)) {
					throw e;
				}
			}
			plainAccepted = plainListener.accept();
			plainAccepted.output.writeString("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
			Socket.select([client], null, null, 5.0);
			try {
				var read:Int = @:privateAccess client.__tryRead(buffer, 0, buffer.length);
				clientError = "answered " + read;
			} catch (e:Dynamic) {
				clientError = e;
			}
		} catch (e:Dynamic) {
			Assert.fail("could not set the client case up: " + Std.string(e));
		}
		Assert.isFalse(clientError == null || Std.string(clientError).indexOf("answered") == 0, "a TLS client's read of plain text did not throw: " + Std.string(clientError));
		Assert.isFalse(BlockedError.isBlocked(clientError), "a TLS client's read of plain text was taken for would-block");
		closeQuietly(plainAccepted);
		closeQuietly(client);
		closeQuietly(plainListener);
	}

	/** Reads what arrives within `seconds`: the first answer that is not -1. **/
	static function readWithin(socket:Socket, buffer:Bytes, seconds:Float):Int {
		var deadline:Float = haxe.Timer.stamp() + seconds;
		while (true) {
			var read:Int = @:privateAccess socket.__tryRead(buffer, 0, buffer.length);
			if (read != -1 || haxe.Timer.stamp() >= deadline) {
				return read;
			}
			Socket.select([socket], null, null, 0.05);
		}
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
