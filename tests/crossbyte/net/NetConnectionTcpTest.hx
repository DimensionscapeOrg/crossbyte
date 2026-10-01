package crossbyte.net;

import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import utest.Assert;
import utest.Async;

/**
	A `NetConnection` dialled over TCP carries data, and an RPC call, on
	every target with sockets, Node included.

	On Node it carried nothing. The connection stamped each send and each
	arrival with the uptime of the socket's runtime, which it read from a
	field only a native connect sets: a send threw a TypeError, and the first
	bytes to arrive threw inside Node's data callback, which closed the
	connection. So `RPCSession.dial("tcp://...")` could never complete a
	call there, and nothing ran one to see.
**/
class NetConnectionTcpTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(15000)
	public function testATcpConnectionCarriesDataBothWays(async:Async):Void {
		var server = new ServerSocket();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				socket.writeUTFBytes(socket.readUTFBytes(socket.bytesAvailable).toUpperCase());
				socket.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var heard:String = "";
			var ready:Bool = false;
			var failure:String = null;
			var connection:NetConnection = null;
			connection = new NetConnection('tcp://127.0.0.1:${server.localPort}', input -> heard += input.readUTFBytes(input.bytesAvailable),
				() -> ready = true, null, reason -> failure = Std.string(reason), true);

			NetPump.until(() -> ready || failure != null, 5.0, function(_) {
				Assert.isTrue(ready, "the connection never became ready: " + failure);
				try {
					connection.send(__bytes("over tcp"));
				} catch (e:Dynamic) {
					Assert.fail("sending threw: " + Std.string(e));
				}

				NetPump.until(() -> heard == "OVER TCP" || failure != null, 5.0, function(_) {
					Assert.equals("OVER TCP", heard, "the answer did not arrive: " + failure);
					Assert.isNull(failure, "the connection failed: " + failure);
					Assert.isTrue(connection.connected, "the connection closed after its first arrival");
					try connection.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	@:timeout(15000)
	public function testAnRpcCallGoesOverTcp(async:Async):Void {
		var server = new ServerSocket();
		var host:NetHost = NetHost.fromServerSocket(server, function(connection:INetConnection) {
			// Kept in a variable: on the jvm a discarded `new` whose argument
			// inlines a branch fails class verification.
			var backend = new RPCSession(connection, null, new TcpEchoHandler());
		});
		server.bind(0, "127.0.0.1");
		host.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var commands = new TcpEchoCommands();
			var session = RPCSession.dial('tcp://127.0.0.1:${server.localPort}', commands);

			NetPump.until(() -> session.up, 5.0, function(_) {
				Assert.isTrue(session.up, "the dialled session never came up");
				var call:RPCResponse<Int> = commands.echo(41);

				NetPump.until(() -> call.completed, 5.0, function(_) {
					Assert.isTrue(call.completed, "the call was never answered");
					Assert.isTrue(call.succeeded, "the call failed: " + call.error);
					Assert.equals(41, call.result);
					session.close();
					try host.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	private static function __bytes(text:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return bytes;
	}
	#end
}

private class TcpEchoCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echo(value:Int):RPCResponse<Int> {}
}

private class TcpEchoHandler extends RPCHandler {
	public function new() {}

	@:rpc public function echo(value:Int):Int {
		return value;
	}
}
