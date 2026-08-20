package crossbyte.net;

/**
 * What a `Socket` does when the peer stops sending — when a read ends in
 * `Eof` because the peer shut its write side, or closed entirely.
 *
 * The two are indistinguishable at that moment. A peer that half-closes to
 * mark the end of a request and a peer that has gone away produce the same
 * `Eof`, and the first write after either one succeeds, because it only
 * reaches the kernel send buffer; a departed peer's RST arrives later, if at
 * all. Nothing the socket can ask separates them, which is why this is the
 * consumer's decision rather than the socket's.
 */
enum abstract PeerShutdownPolicy(Int) from Int to Int {
	/**
	 * End the connection. `Event.CLOSE` is dispatched and the socket is torn
	 * down.
	 *
	 * The right default, and what a socket has always done here. Most
	 * protocols carry their own framing — HTTP/1.1 has `Content-Length` and
	 * chunked encoding — so a peer's FIN tells them nothing they did not
	 * already know, and treating it as the end reclaims the connection
	 * without every consumer needing a deadline of its own.
	 */
	var CLOSE:Int = 0;

	/**
	 * End the read direction only. The socket stops reading, sets
	 * `peerShutdown`, dispatches `Event.PEER_CLOSE`, and stays writable until
	 * the consumer closes it.
	 *
	 * For protocols where a half-close is how the peer says "that is my whole
	 * request" — the shape of a great many hand-rolled TCP protocols, and the
	 * only end-of-request signal available to one that does not length-prefix.
	 * Writes after the FIN do reach a half-closed peer.
	 *
	 * **The consumer must bound what happens next.** Because a departed peer
	 * looks exactly like a half-closed one, this keeps dead connections open
	 * as readily as live ones, and a write that "succeeds" is not evidence
	 * anybody is there. Pair it with a deadline, a response that completes and
	 * then closes, or a sweep. Selecting it and waiting indefinitely is how a
	 * server runs out of descriptors.
	 */
	var HALF_OPEN:Int = 1;
}
