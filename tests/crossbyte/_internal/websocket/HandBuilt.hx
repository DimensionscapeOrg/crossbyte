package crossbyte._internal.websocket;

/**
	A framing layer made without its constructor, for the tests that drive
	its parser and its sender directly.

	`Type.createEmptyInstance` runs no field initialiser, and on the dynamic
	targets an Int or Bool left so is null rather than 0 or false, so each
	limit and flag the parser reads is set here as the initialisers would.
	One place, so a field the session starts reading on a path these tests
	reach is given its value once rather than in every test's own helper,
	a field missed there was a release crash natively, with no output at all.
**/
@:access(crossbyte._internal.websocket.WebSocket)
class HandBuilt {
	public static function session():WebSocket {
		var ws:WebSocket = Type.createEmptyInstance(WebSocket);
		// -D ws_before builds the tests against the sources before these
		// fields, to show a new test failing there.
		#if !ws_before
		ws.maxHeaderSize = WebSocket.DEFAULT_MAX_HEADER_SIZE;
		ws.__headScanned = 0;
		ws.__refusing = false;
		ws.__pongUntil = 0;
		ws.__pongOwed = false;
		ws.__control = null;
		ws.maxMessageSize = WebSocket.DEFAULT_MAX_MESSAGE_SIZE;
		ws.closeTimeout = WebSocket.DEFAULT_CLOSE_TIMEOUT;
		#end
		ws.__incomingMessageSize = 0;
		ws.__writeQueued = false;
		ws.__passFlushQueued = false;
		ws.__pendingSent = 0;
		ws.bytesSent = 0;
		return ws;
	}
}
