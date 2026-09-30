package crossbyte.net;

import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A listener started without a backlog, as nearly every one is.

	The default was the largest Int, which neko's integers -- 31 bits --
	cannot carry, so `listen()` threw there and no `ServerSocket`,
	`HTTPServer` or `FlexSocket` listener could start. Any backlog past the
	system's own maximum is granted as that maximum, so the default now fits
	every target's Int and asks for the same thing.
**/
class ServerSocketBacklogTest extends utest.Test {
	public function testTheDefaultBacklogFitsEveryTargetsInt():Void {
		var backlog:Int = @:privateAccess ServerSocket.DEFAULT_BACKLOG;
		Assert.isTrue(backlog > 0, "the default backlog is not a backlog");
		Assert.isTrue(backlog <= 0x3FFFFFFF, 'the default backlog, $backlog, is past the largest Int neko carries');
	}

	#if (cpp || java || jvm || eval || hl || neko)
	@:timeout(15000)
	public function testListenersStartedWithoutABacklogAccept(async:Async):Void {
		var plain:ServerSocket = new ServerSocket();
		var web:ServerWebSocket = new ServerWebSocket();
		var accepted:Int = 0;
		plain.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) accepted++);
		plain.bind(0, "127.0.0.1");
		web.bind(0, "127.0.0.1");

		var failure:String = null;
		try {
			plain.listen();
			web.listen();
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}

		var raw:crossbyte._internal.socket.FlexSocket = new crossbyte._internal.socket.FlexSocket(false);
		var rawFailure:String = null;
		try {
			raw.bind("127.0.0.1", 0);
			raw.listen();
		} catch (e:Dynamic) {
			rawFailure = Std.string(e);
		}

		Assert.isNull(failure, "listen() with no backlog threw: " + failure);
		Assert.isNull(rawFailure, "FlexSocket.listen() with no backlog threw: " + rawFailure);

		var client:WirePeer = failure == null ? new WirePeer(plain.localPort) : null;
		NetPump.until(() -> accepted > 0 || failure != null, 5.0, function(_) {
			if (failure == null) {
				Assert.equals(1, accepted, "the listener started without a backlog never accepted");
			}
			if (client != null) {
				client.close();
			}
			try raw.close() catch (_:Dynamic) {}
			try web.close() catch (_:Dynamic) {}
			try plain.close() catch (_:Dynamic) {}
			async.done();
		});
	}
	#end
}
