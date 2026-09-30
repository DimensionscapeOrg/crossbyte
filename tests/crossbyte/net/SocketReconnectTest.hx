package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A `Socket` connected again -- after a connect that failed, or in place of
	one still under way -- is the new connection's alone.

	On Node it was not: the socket given up went on reporting, and its
	reports were taken for the one that replaced it. A refused connect's
	close comes a turn after its error, so a connect retried from that
	ioError was released by it and then connected with nothing to write to;
	and a connect abandoned for another still announced CONNECT when it came
	up, and its end closed the connection that replaced it.
**/
class SocketReconnectTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(30000)
	public function testAConnectRetriedFromItsFailureCarriesData(async:Async):Void {
		var heard:Array<String> = [];
		var peers:Array<Socket> = [];
		var server = __echoServer(heard, peers);

		// A port nothing listens on: taken from a listener, which is closed.
		var probe = new ServerSocket();
		probe.bind(0, "127.0.0.1");
		probe.listen();

		NetPump.until(() -> server.localPort != 0 && probe.localPort != 0, 5.0, function(_) {
			var refused:Int = probe.localPort;
			try probe.close() catch (_:Dynamic) {}

			NetPump.wait(0.1, function() {
				var client = new Socket();
				var failures:Int = 0;
				var connects:Int = 0;
				var answer:String = "";
				client.addEventListener(IOErrorEvent.IO_ERROR, function(_) {
					failures++;
					if (failures == 1) {
						client.connect("127.0.0.1", server.localPort);
					}
				});
				client.addEventListener(Event.CONNECT, function(_) {
					connects++;
					client.writeUTFBytes("ping");
					client.flush();
				});
				client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> answer += client.readUTFBytes(client.bytesAvailable));
				client.connect("127.0.0.1", refused);

				NetPump.until(() -> answer.length >= 4 || failures > 1, 15.0, function(_) {
					// A little longer, for anything the refused socket had
					// still to say.
					NetPump.wait(0.2, function() {
						Assert.equals(1, failures, "the refused connect was not reported once");
						Assert.equals(1, connects, "the retried connect was not announced once");
						Assert.equals("PING", answer, "the retried connection carried nothing");
						Assert.isTrue(client.connected, "the retried connection was let go of");
						try client.close() catch (_:Dynamic) {}
						for (peer in peers) {
							try peer.close() catch (_:Dynamic) {}
						}
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}
	#end

	// Not on eval, whose connect completes and announces itself before it
	// returns, so there is no connect under way to give up.
	#if (cpp || java || jvm || nodejs)
	@:timeout(30000)
	public function testAConnectGivenUpForAnotherIsNotAnnounced(async:Async):Void {
		var firstHeard:Array<String> = [];
		var secondHeard:Array<String> = [];
		var peers:Array<Socket> = [];
		var first = __echoServer(firstHeard, peers);
		var second = __echoServer(secondHeard, peers);

		NetPump.until(() -> first.localPort != 0 && second.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var connects:Int = 0;
			var closes:Int = 0;
			var answer:String = "";
			client.addEventListener(Event.CONNECT, function(_) {
				connects++;
				client.writeUTFBytes("ping");
				client.flush();
			});
			client.addEventListener(Event.CLOSE, _ -> closes++);
			client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> answer += client.readUTFBytes(client.bytesAvailable));

			// The first given up at once, for the second.
			client.connect("127.0.0.1", first.localPort);
			client.connect("127.0.0.1", second.localPort);

			NetPump.until(() -> answer.length >= 4, 10.0, function(_) {
				// Long enough for the first to come up, and to end, if it
				// still reports.
				NetPump.wait(0.5, function() {
					Assert.equals(1, connects, "a connect given up for another was announced too");
					Assert.equals("PING", answer, "the connection that replaced it carried nothing");
					Assert.equals("ping", secondHeard.join(""), "the second server did not hear the client");
					Assert.equals("", firstHeard.join(""), "the connect given up for another was written to");
					Assert.equals(0, closes, "the connection was closed by the one it replaced");
					Assert.isTrue(client.connected, "the connection was let go of");
					try client.close() catch (_:Dynamic) {}
					for (peer in peers) {
						try peer.close() catch (_:Dynamic) {}
					}
					try first.close() catch (_:Dynamic) {}
					try second.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval || nodejs)
	/** A server answering what it reads in capitals; what it read goes in `heard`. **/
	private static function __echoServer(heard:Array<String>, peers:Array<Socket>):ServerSocket {
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var peer:Socket = e.socket;
			peers.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				var text:String = peer.readUTFBytes(peer.bytesAvailable);
				heard.push(text);
				peer.writeUTFBytes(text.toUpperCase());
				peer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		return server;
	}
	#end
}
