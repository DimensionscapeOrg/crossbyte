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
	The promises CrossByte's `sys.net` sockets keep on every target, including
	the places hl's and neko's standard libraries kept a different one.

	CrossByte replaces `sys.net.Socket` and `sys.net.UdpSocket` on every target,
	and hl and neko had no branch of their own until they were given their
	standard implementations. Those differed from the other targets in small
	ways that callers here had been written against: an idle accept that
	answered null, a peer with no name, a second close that threw, a reset that
	read as an ending. Each case runs everywhere the promise can be kept, so a
	target that drifts fails here rather than in whatever it broke.
**/
class SysSocketContractTest extends utest.Test {
	#if (sys && !(js || php))
	static inline var LOOPBACK:String = "127.0.0.1";

	#if !eval
	/**
		A would-block, as every other target reports it. hl's standard library
		answered null, which ServerSocket went on to treat as a connection.

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

		hl's standard library left `host` null on the hosts it built here, and
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
		#if !eval
		// eval's own sockets leave the text unset; theirs is a branch of its own.
		Assert.equals(LOOPBACK, accepted.host.host);
		Assert.equals(LOOPBACK, client.host.host);
		Assert.equals(LOOPBACK, pair.client.host().host.host);
		#end

		pair.close();
	}

	#if !eval
	/**
		A second close does nothing. neko's native close throws when handed a
		socket it already closed, and its standard library passed the same
		handle every time.

		Not on eval, whose branch of this module hands the second close to the
		system and throws "not a socket".
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
	#end

	#if (hl || neko || java || jvm)
	/**
		Null, as on hl and the jvm. neko's natives throw instead, which the
		standard library's own null check never saw.
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

	#if !eval
	/**
		A reset partway through is a failure, and the end of the stream is
		`Eof`: a reader has to be able to tell a peer that finished from one
		that was cut off, and a body delimited by its connection's end cannot
		be told complete otherwise.

		hl's standard library reported both as `Eof`, since its native read
		answers -2 for each. neko's reported a reset seen by `readByte` as the
		end too.

		Not on eval, whose reset is a native error no Haxe catch intercepts.
		And `readByte` is not asked natively: the cpp branch of this module
		reports every failure a byte read meets as `Eof`, as the standard
		library it came from does, so a reset there is told apart by
		`readBytes` alone.
	**/
	public function testAResetIsAFailureRatherThanAnEnd():Void {
		#if (cpp || hxcpp)
		var modes:Array<Bool> = [false];
		#else
		var modes:Array<Bool> = [false, true];
		#end
		for (byByte in modes) {
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
	#end

	#if (cpp || hxcpp || java || jvm || hl || neko)
	/**
		A datagram's sender, by address and port, as text and in `host`.

		On hl every datagram threw here before it was delivered: the Address
		wrote an `ipv6` field into a Host that has none there. UDP, RUDP, STUN
		and ICE received nothing at all. The targets without a native
		conversion named every sender "0.0.0.0".
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
