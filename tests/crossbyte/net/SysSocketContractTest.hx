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
	The promises CrossByte's `sys.net` sockets keep on every target,
	including the places hl's and neko's standard libraries keep a
	different one.

	CrossByte replaces `sys.net.Socket` and `sys.net.UdpSocket` on every
	target. hl's and neko's standard implementations differ from the other
	targets in small ways that callers here are written against: an idle
	accept that answers null, a peer with no name, a second close that
	throws, a reset that reads as an ending. Each case runs everywhere the
	promise can be kept, so a target that drifts fails here rather than in
	whatever it broke.
**/
class SysSocketContractTest extends utest.Test {
	#if (sys && !(js || php))
	static inline var LOOPBACK:String = "127.0.0.1";

	#if !eval
	/**
		A would-block, as every other target reports it, not the null hl's
		standard library answers, which ServerSocket would treat as a connection.

		Not on eval, whose sockets cannot be made non-blocking: the accept
		would wait for a connection that never comes.
	**/
	public function testAnAcceptWithNothingWaitingIsABlockNotANull():Void {
		var listener = new Socket();
		var accepted:Socket = null;
		var error:Dynamic = null;

		try {
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(1);
			listener.setBlocking(false);
			accepted = listener.accept();
		} catch (e:Dynamic) {
			error = e;
		}

		Assert.isNull(accepted, "an accept with nothing waiting returned a socket");
		Assert.isTrue(BlockedError.isBlocked(error), "an accept with nothing waiting failed with " + Std.string(error));
		closeQuietly(listener);
	}
	#end

	/**
		Both ends name the other by its address, as text and in `host`.

		hl's standard library leaves `host` null on the hosts it builds, and
		ServerWebSocket names a client by `peer().host.host`.
	**/
	public function testAPeerIsNamedByItsAddress():Void {
		var pair = connectedPair();
		if (pair == null) {
			return;
		}

		var accepted = pair.accepted.peer();
		var client = pair.client.peer();
		Assert.equals(LOOPBACK, accepted.host.toString());
		Assert.equals(pair.client.host().port, accepted.port);
		Assert.equals(LOOPBACK, client.host.toString());
		Assert.equals(pair.listener.host().port, client.port);
		Assert.equals(LOOPBACK, accepted.host.host);
		Assert.equals(LOOPBACK, client.host.host);
		Assert.equals(LOOPBACK, pair.client.host().host.host);

		pair.close();
	}

	/**
		A second close does nothing. neko's native close throws when handed a
		socket it already closed, and the system throws "not a socket" for a
		second close handed to it, so neither may see one.
	**/
	public function testClosingTwiceIsHarmless():Void {
		var pair = connectedPair();
		if (pair == null) {
			return;
		}

		var error:Dynamic = null;
		try {
			pair.accepted.close();
			pair.accepted.close();
			var unused = new Socket();
			unused.close();
			unused.close();
		} catch (e:Dynamic) {
			error = e;
		}

		Assert.isNull(error, "closing a closed socket threw " + Std.string(error));
		pair.close();
	}

	#if (hl || neko || java || jvm)
	/**
		Null, as on hl and the jvm, though neko's natives throw instead, past
		the standard library's own null check.
	**/
	public function testASocketNeverConnectedHasNoPeer():Void {
		var socket = new Socket();
		var peer:Dynamic = null;
		var error:Dynamic = null;

		try {
			peer = socket.peer();
		} catch (e:Dynamic) {
			error = e;
		}

		Assert.isNull(error, "asking an unconnected socket for its peer threw " + Std.string(error));
		Assert.isNull(peer);
		closeQuietly(socket);
	}
	#end

	/**
		A reset partway through is a failure, and the end of the stream is
		`Eof`: a reader has to be able to tell a peer that finished from one
		that was cut off, and a body delimited by its connection's end cannot
		be told complete otherwise.

		hl's standard library reports both as `Eof`, since its native read
		answers -2 for each, and neko's reports a reset seen by `readByte` as
		the end too. The cpp branch of this module reads through `readBytes`,
		as the others do, rather than reporting every failure a byte read
		meets as `Eof`, as the standard library it came from does. On eval
		too, since its resets are caught rather than ending the interpreter.
	**/
	public function testAResetIsAFailureRatherThanAnEnd():Void {
		for (byByte in [false, true]) {
			var pair = connectedPair();
			if (pair == null) {
				return;
			}

			var outcome:String = null;
			try {
				// Unread data at the far end makes its close a reset rather than
				// an orderly end.
				pair.client.output.writeString("never read");
				pair.client.output.flush();
				crossbyte.sys.System.sleep(0.1);
				#if (java || jvm)
				// The JDK closes gracefully even over unread data; a zero linger
				// is how a Java socket is made to reset.
				var channel:java.nio.channels.SocketChannel = cast @:privateAccess pair.accepted.channel;
				channel.socket().setSoLinger(true, 0);
				#end
				pair.accepted.close();
				crossbyte.sys.System.sleep(0.1);
				pair.client.setTimeout(2.0);

				if (byByte) {
					pair.client.input.readByte();
				} else {
					pair.client.input.readBytes(Bytes.alloc(16), 0, 16);
				}
				outcome = "read data after the reset";
			} catch (_:haxe.io.Eof) {
				outcome = "Eof";
			} catch (e:Dynamic) {
				outcome = null;
			}

			Assert.isNull(outcome, (byByte ? "readByte" : "readBytes") + " reported a reset as: " + outcome);
			pair.close();
		}
	}

	#if (cpp || hxcpp || java || jvm || hl || neko)
	/**
		A datagram's sender, by address and port, as text and in `host`.

		On hl the Address must not write an `ipv6` field into a Host that has
		none there: every datagram would throw before it was delivered, and
		UDP, RUDP, STUN and ICE would receive nothing at all. The targets
		without a native conversion must not name every sender "0.0.0.0".
	**/
	public function testADatagramNamesItsSender():Void {
		var receiver = new UdpSocket();
		var sender = new UdpSocket();

		try {
			receiver.bind(new Host(LOOPBACK), 0);
			sender.bind(new Host(LOOPBACK), 0);

			var to = new Address();
			to.setHost(new Host(LOOPBACK));
			to.port = receiver.host().port;
			sender.sendTo(Bytes.ofString("ping"), 0, 4, to);

			var ready = Socket.select([receiver], null, null, 5.0);
			if (ready.read.length == 0) {
				Assert.fail("the datagram never arrived");
			} else {
				var buffer = Bytes.alloc(16);
				var from = new Address();
				var length = receiver.readFrom(buffer, 0, buffer.length, from);
				Assert.equals("ping", buffer.getString(0, length));
				Assert.equals(sender.host().port, from.port);

				var host = from.getHost();
				Assert.equals(LOOPBACK, host.toString());
				Assert.equals(LOOPBACK, host.host);
			}
		} catch (e:Dynamic) {
			Assert.fail("a loopback datagram failed: " + Std.string(e));
		}

		closeQuietly(receiver);
		closeQuietly(sender);
	}
	#end

	static function connectedPair():Null<SocketPair> {
		var listener = new Socket();
		var client = new Socket();
		try {
			listener.bind(new Host(LOOPBACK), 0);
			listener.listen(1);
			client.connect(new Host(LOOPBACK), listener.host().port);
			var accepted = listener.accept();
			return new SocketPair(listener, client, accepted);
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

#if (sys && !(js || php))
private class SocketPair {
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
