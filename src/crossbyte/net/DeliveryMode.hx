package crossbyte.net;

import crossbyte.errors.ArgumentError;

/**
 * What a `ReliableDatagramSocket` in `DATAGRAM` mode promises about one message.
 *
 * ```haxe
 * socket.send(chat);                                        // RELIABLE
 * socket.send(footstep, 0, 0, DeliveryMode.UNRELIABLE);
 * socket.send(snapshot, 0, 0, DeliveryMode.sequenced(0));
 * socket.send(input, 0, 0, DeliveryMode.sequenced(1));
 * ```
 *
 * - `RELIABLE` arrives, once, in the order it was sent, however large it is:
 *   it is split into frames, each resent until acknowledged, and put back
 *   together. What was not yet delivered holds back what came after it --
 *   the price of the order.
 * - `UNRELIABLE` goes out once and is never resent, and may arrive in any
 *   order or not at all. Nothing waits for it and it waits for nothing.
 * - `sequenced(channel)` is unreliable, and a message arriving after a newer
 *   one on the same channel is dropped rather than delivered late: the
 *   receiver sees only ever-newer messages. What state updates want -- a
 *   snapshot older than the last one is worse than none. Channels are
 *   independent, so a newer snapshot on one never makes an older input on
 *   another look stale.
 *
 * An unreliable or sequenced message must fit one frame,
 * `ReliableDatagramProtocol.MAX_PAYLOAD_SIZE` bytes. Split across frames, the
 * loss of any one would lose the whole, so it is refused rather than sent
 * that way; splitting is the caller's to do, where it knows what each part
 * means on its own.
 *
 * Neither is paced by the reliable congestion window: it has no
 * acknowledgements to open or close by, and the traffic that uses them --
 * state at a fixed rate -- is the traffic that must not wait behind a
 * queue. How fast to send it is the caller's, who knows what it can shed.
 *
 * An `Int` underneath, so choosing a mode per message costs nothing.
 */
enum abstract DeliveryMode(Int) {
	var RELIABLE = 0;
	var UNRELIABLE = 1;

	// A sequenced mode is this bit and the channel in the low byte.
	private static inline var SEQUENCED_BIT:Int = 0x100;

	/** The number of channels `sequenced` accepts: 0 to 255. **/
	public static inline var CHANNELS:Int = 256;

	/**
	 * Unreliable, and never delivered after a newer message on `channel`.
	 *
	 * @param channel 0 to 255.
	 */
	public static inline function sequenced(channel:Int):DeliveryMode {
		if (channel < 0 || channel >= CHANNELS) {
			throw new ArgumentError("A sequenced channel is 0 to 255.");
		}
		return cast(SEQUENCED_BIT | channel);
	}

	/** Whether this mode resends until acknowledged. **/
	public var reliable(get, never):Bool;

	/** Whether this mode drops what arrives after something newer. **/
	public var isSequenced(get, never):Bool;

	/** The channel of a sequenced mode, or -1 for any other. **/
	public var channel(get, never):Int;

	private inline function get_reliable():Bool {
		return (cast this : DeliveryMode) == RELIABLE;
	}

	private inline function get_isSequenced():Bool {
		return (this & SEQUENCED_BIT) != 0;
	}

	private inline function get_channel():Int {
		return (this & SEQUENCED_BIT) != 0 ? this & 0xFF : -1;
	}
}
