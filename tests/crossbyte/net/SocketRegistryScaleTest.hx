package crossbyte.net;

import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	A runtime serves more connections than one `select` can name.

	neko's registry selected every socket it held at once, and neko's
	`select` takes at most 64 on Windows and throws past them, so from the
	65th connection no socket was serviced at all: 39 of 100 connections
	timed out. It polls through neko's poll natives now. This asks every
	target the same of its registry: 100 connections, each answered.
**/
class SocketRegistryScaleTest extends utest.Test {
	private static inline var COUNT:Int = 100;

	#if (cpp || java || jvm || eval || hl || neko)
	@:timeout(30000)
	public function testAHundredConnectionsAreAllServiced(async:Async):Void {
		var server = new ServerSocket();
		var sessions:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:Socket = e.socket;
			sessions.push(session);
			session.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				session.writeUTFBytes(session.readUTFBytes(session.bytesAvailable));
				session.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var peers:Array<WirePeer> = [];
		function answered():Int {
			var count:Int = 0;
			for (i in 0...peers.length) {
				peers[i].poll();
				if (peers[i].text() == 'hello $i') {
					count++;
				}
			}
			return count;
		}

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Opened in batches the listen queue can hold, with the runtime
			// taking each batch before the next.
			function open(from:Int):Void {
				var upTo:Int = from + 25 < COUNT ? from + 25 : COUNT;
				for (i in from...upTo) {
					var peer = new WirePeer(server.localPort);
					peers.push(peer);
					peer.send(Bytes.ofString('hello $i'));
				}
				NetPump.until(() -> sessions.length >= upTo, 10.0, function(_) {
					if (upTo < COUNT && sessions.length >= upTo) {
						open(upTo);
						return;
					}
					NetPump.until(() -> answered() == COUNT, 10.0, function(_) {
						Assert.equals(COUNT, sessions.length, "not every connection was accepted");
						Assert.equals(COUNT, answered(), "not every connection was answered");
						for (peer in peers) {
							peer.close();
						}
						for (session in sessions) {
							try session.close() catch (_:Dynamic) {}
						}
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			}
			open(0);
		});
	}
	#end
}
