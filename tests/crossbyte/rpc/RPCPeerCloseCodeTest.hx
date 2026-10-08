package crossbyte.rpc;

import crossbyte.events.Event;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.net.NetConnection;
import crossbyte.net.Reason;
import crossbyte.net.WebSocket;
import utest.Assert;

/**
	What a WebSocket peer closed with reaches the connection, and the RPC
	calls its closing fails, rather than `Reason.Closed` whatever the close
	frame said: a gateway can tell a backend going away (1001) from one
	refusing it by policy (1008), and so can a call that failed because of it.

	The close is dispatched on the socket as its session dispatches it, so
	this needs no peer: whether a CrossByte peer writes the code into its
	close frame is the WebSocket's own concern.
**/
class RPCPeerCloseCodeTest extends utest.Test {
	public function testTheCodeAPeerClosedWithReachesTheConnection():Void {
		var socket = new WebSocket();
		var connection = NetConnection.fromWebSocket(socket);
		var told:Reason = null;
		connection.onClose = reason -> told = reason;

		socket.dispatchEvent(new WebSocketCloseEvent(Event.CLOSE, 4001, "shutting down"));

		Assert.isTrue(told != null && Type.enumEq(Reason.Code(4001, "shutting down"), told), 'onClose was told $told');
	}

	public function testACloseWithNoCodeIsClosed():Void {
		for (event in [new Event(Event.CLOSE), new WebSocketCloseEvent(Event.CLOSE, 0)]) {
			var socket = new WebSocket();
			var connection = NetConnection.fromWebSocket(socket);
			var told:Reason = null;
			connection.onClose = reason -> told = reason;

			socket.dispatchEvent(event);

			Assert.isTrue(told != null && Type.enumEq(Reason.Closed, told), 'onClose was told $told');
		}
	}

	public function testACallTheCloseFailsCarriesTheCode():Void {
		var socket = new WebSocket();
		var connection = NetConnection.fromWebSocket(socket);
		var session = new RPCSession(connection);

		socket.dispatchEvent(new WebSocketCloseEvent(Event.CLOSE, WebSocketCloseEvent.POLICY_VIOLATION, "not allowed"));
		var call:RPCResponse<Dynamic> = session.request(77, [1]);

		Assert.isTrue(call.completed, "the call was left waiting");
		Assert.isFalse(call.succeeded);
		Assert.isTrue(Type.enumEq(Reason.Code(WebSocketCloseEvent.POLICY_VIOLATION, "not allowed"), call.cause), 'the call failed with ${call.cause}');
	}
}
