package crossbyte._internal.http;

import crossbyte.io.ByteArray;

/**
 * Where a decided response goes, and how it gets framed.
 *
 * `HTTPRequestHandler` decided a response and wrote HTTP/1.1 in the same
 * breath -- `__dispatchResponseBytes` built a `"HTTP/1.1 200 OK\r\n..."`
 * string and pushed it at a socket -- so nothing above that could serve a
 * response over any other protocol. This is the line between the two halves.
 *
 * The buffering members are not incidental. The streaming file path feeds a
 * body in bounded bursts and pauses at a watermark, so peak memory per
 * transfer is the watermark plus a slice rather than the whole file. That
 * needs to know how much is queued (`bufferedBytes`), how much is allowed
 * (`maxBufferedBytes`), and when the peer has taken some (`onDrain`) -- from
 * whatever is underneath, not from a socket specifically.
 */
interface HTTPResponseWriter {
	/** False once the peer is gone; nothing further should be written. */
	var connected(get, never):Bool;

	/**
	 * Whether the connection outlives this response and belongs to someone
	 * else.
	 *
	 * True under HTTP/2, where one connection carries many streams and the
	 * frame layer decides when it ends. A response must then never close the
	 * socket, and the HTTP/1.1 keep-alive question does not arise: closing
	 * after one response would take down every other request in flight, and
	 * even a single blocked response still waiting on a flow-control window.
	 */
	var ownsConnection(get, never):Bool;

	/** Bytes written but not yet taken by the peer. */
	var bufferedBytes(get, never):Int;

	/** Cap on `bufferedBytes`, or `0` for no cap. */
	var maxBufferedBytes(get, never):Int;

	/**
	 * Invoked when queued bytes have drained and more may be written.
	 *
	 * Drain-driven rather than clock-driven: the cadence then follows the peer
	 * instead of a timer, and costs nothing on a connection that is not
	 * mid-transfer. Set to `null` to stop.
	 */
	var onDrain(get, set):Null<Void->Void>;
	/**
	 * Invoked if this response is abandoned without the connection closing:
	 * under HTTP/2, a reset of its stream, whether the peer sent it or the
	 * server did -- for a protocol error of the peer's on that stream, say. A
	 * closed connection is the socket's own `Event.CLOSE`, and under HTTP/1.1
	 * that is the only way a response is abandoned, so this is never called
	 * there.
	 */
	var onAbandoned(get, set):Null<Void->Void>;

	/**
	 * Has the server's sweep call `check` with its `haxe.Timer.stamp()`, a
	 * few times a second, while a body is pumped out or bytes wait on the
	 * peer, so a transfer the peer has stopped taking has a deadline; `null`
	 * stops it. The sweep runs for these whatever `requestTimeout` and
	 * `keepAliveTimeout` are, and visits only these when both are off: a
	 * stall deadline was checked from the walk those two arm, so with both
	 * at `0` it never was.
	 *
	 * @return Whether a sweep runs it: false for a writer with no server
	 *         behind it, which has no sweep and ignores this.
	 */
	function sweepWith(check:Null<Float->Void>):Bool;

	/**
	 * Tells a client that sent `Expect: 100-continue` to send its body: an
	 * interim `100 Continue`, ahead of the response, which goes out later
	 * through `writeHead` as usual.
	 */
	function writeContinue():Void;

	/** Writes the status and header fields. Called once per response. */
	function writeHead(head:HTTPResponseHead):Void;

	/** Appends body bytes. May be called repeatedly while streaming. */
	function writeBody(data:ByteArray, offset:Int, length:Int):Void;

	/**
	 * `writeBody`, for bytes the caller hands over: it never changes them
	 * again, so a writer that holds a body until its peer takes it -- HTTP/2,
	 * behind flow control -- may keep `data` itself rather than a copy.
	 */
	function writeBodyTaken(data:ByteArray, offset:Int, length:Int):Void;

	/** Pushes whatever is queued toward the peer. */
	function flush():Void;

	/**
	 * Marks the response complete.
	 *
	 * HTTP/1.1 has nothing to do here -- the framing already said how long the
	 * body was -- but HTTP/2 must close the stream, since a stream left open
	 * is a request the client is still waiting on.
	 */
	function endResponse():Void;

	/**
	 * Gives up on a response partway through its body, where no status can
	 * say so any more: HTTP/1.1 closes the connection, the only way left to
	 * tell the peer the body is short, and HTTP/2 resets the stream, leaving
	 * the connection's other streams alone.
	 */
	function abort():Void;
}
