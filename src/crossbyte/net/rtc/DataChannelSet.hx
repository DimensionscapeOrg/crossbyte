package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net.rtc._internal.sctp.DcepMessage;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;
import haxe.ds.IntMap;

/**
	Every data channel on one association, and the negotiation that opens them.

	SCTP hands up messages tagged with a stream number and a payload protocol
	identifier. This sorts them: identifier 50 is DCEP, which opens and
	acknowledges channels, and everything else is a message for whichever
	channel owns that stream.

	## Even and odd

	The peer that was the DTLS client opens channels on even stream numbers and
	the other on odd ones. That is the entire collision-avoidance scheme, and it
	is worth the paragraph because the alternative -- negotiating a number --
	would cost a round trip before every channel and could still race. Two peers
	opening a channel at the same instant here simply cannot pick the same
	stream.

	A caller does not choose the number, which is why `create` does not offer
	it: a number chosen from the wrong side of the parity is one the peer will
	answer on a stream it thinks it owns.

	## Closing

	By resetting streams, RFC 6525, as RFC 8831 section 6.7 has it. A channel
	closed here resets the stream this end sends on, once what was sent on it
	before has gone; the peer closes its end when the reset reaches it and
	resets its own in answer. A peer's reset closes the channel here the same
	way. Against a peer that did not say it understands RE-CONFIG the close is
	this end's alone.
**/
class DataChannelSet {
	/** RFC 8832's identifier for a channel control message. **/
	private static inline var PPID_CONTROL:Int = 50;

	/** The transfer these channels run over. **/
	public var transfer(default, null):SctpDataTransfer;

	/** Whether this peer takes the even stream numbers. **/
	public var usesEvenStreams(default, null):Bool;

	/** Called when the peer opens a channel rather than answering one. **/
	public dynamic function onChannel(channel:DataChannel):Void {}

	/** The largest stream number SCTP can carry: the field is sixteen bits. **/
	public static inline var MAX_STREAM_ID:Int = 65535;

	@:noCompletion private var __channels:IntMap<DataChannel> = new IntMap();
	@:noCompletion private var __nextId:Int;

	/** Set once the association is ending, when there is nobody left to reset a stream toward. **/
	@:noCompletion private var __ending:Bool = false;

	/**
		@param wasDtlsClient Whether this peer was the client in the DTLS
		handshake. It decides the parity, and the two peers must disagree about
		it -- which they will, having been on opposite ends of that handshake.
	**/
	public function new(transfer:SctpDataTransfer, wasDtlsClient:Bool) {
		if (transfer == null) {
			throw new ArgumentError("Data channels need a transfer to run over.");
		}

		this.transfer = transfer;
		this.usesEvenStreams = wasDtlsClient;
		this.__nextId = wasDtlsClient ? 0 : 1;

		transfer.onMessage = function(streamId:Int, payload:ByteArray, protocolId:Int):Void {
			if (protocolId == PPID_CONTROL) {
				__onControl(streamId, payload);
				return;
			}

			var channel = __channels.get(streamId);

			if (channel != null) {
				@:privateAccess channel.__deliver(payload, protocolId);
			}
		};

		// The peer closed channels: it reset the streams it sends on, or asked
		// this end to reset its own. Each channel closes the ordinary way, which
		// resets the stream this end sends on in answer -- RFC 8831 section
		// 6.7's other half. A channel this end had already closed is not here,
		// and its stream was reset when it closed.
		transfer.onStreamsReset = function(streams:Null<Array<Int>>):Void {
			var closing:Array<DataChannel> = streams == null ? [for (channel in __channels) channel] : [
				for (streamId in streams)
					if (__channels.exists(streamId)) __channels.get(streamId)
			];

			for (channel in closing) {
				channel.close();
			}
		};
	}

	/**
		Opens a channel and asks the peer to acknowledge it.

		The channel exists immediately and is not usable until the peer answers,
		which is what `opened` is for. Sending before then throws rather than
		buffering, since a caller cannot otherwise tell a message that went from
		one that is waiting.
	**/
	public function create(label:String, ordered:Bool = true, protocol:String = "", ?maxRetransmits:Int,
			?maxPacketLifeTime:Int):DataChannel {
		// The WebRTC API's rules: one limit or the other, each an unsigned
		// short.
		if (maxRetransmits != null && maxPacketLifeTime != null) {
			throw new ArgumentError("A channel may limit how many times a message is sent or for how long, not both.");
		}

		if ((maxRetransmits != null && (maxRetransmits < 0 || maxRetransmits > 65535))
			|| (maxPacketLifeTime != null && (maxPacketLifeTime < 0 || maxPacketLifeTime > 65535))) {
			throw new ArgumentError("maxRetransmits and maxPacketLifeTime must be between 0 and 65535.");
		}

		var id:Int = __freeStreamId();

		var channel = @:privateAccess new DataChannel(transfer, id, label, ordered, protocol, maxRetransmits, maxPacketLifeTime);
		__channels.set(id, channel);
		@:privateAccess channel.__onClosed = __release;

		var open = DcepMessage.open(label, ordered, protocol, maxRetransmits, maxPacketLifeTime);

		// The OPEN travels on the very stream it is about, told apart from that
		// channel's messages by its identifier alone. That is what saves a
		// channel from needing a second stream to be negotiated on.
		transfer.send(id, open.encode(), PPID_CONTROL, true, haxe.Timer.stamp());

		return channel;
	}

	/** The channel on a stream, or null. **/
	public function channel(id:Int):Null<DataChannel> {
		return __channels.get(id);
	}

	/**
		Closes every channel, because the association under them has ended.

		Each is closed the ordinary way, so each reports `onClose` and one still
		waiting for its acknowledgement settles `opened`. Without this a channel
		outlived its association: `open` stayed true after the peer had aborted,
		and the first sign of it was a `send` that threw.
	**/
	public function closeAll():Void {
		// No stream is reset on the way: the association is ending, which
		// closes the peer's channels with it.
		__ending = true;

		// Copied first: closing a channel removes it from the map being read.
		var closing:Array<DataChannel> = [for (channel in __channels) channel];

		for (channel in closing) {
			channel.close();
		}
	}

	@:noCompletion private function __onControl(streamId:Int, payload:ByteArray):Void {
		var message = DcepMessage.decode(payload);

		if (message == null) {
			return;
		}

		if (message.messageType == DcepMessage.ACK) {
			var waiting = __channels.get(streamId);

			if (waiting != null) {
				@:privateAccess waiting.__acknowledge();
			}

			return;
		}

		if (message.messageType != DcepMessage.OPEN) {
			return;
		}

		// A peer opening a channel on a stream this side would have chosen is a
		// peer that has the parity wrong, and answering would give two channels
		// one number. Refused rather than accepted into a collision.
		var even:Bool = (streamId % 2) == 0;

		if (even == usesEvenStreams) {
			return;
		}

		if (__channels.exists(streamId)) {
			return;
		}

		// With the peer's own terms. A browser's `{ordered: false,
		// maxRetransmits: 0}` channel was answered as a reliable one: the type
		// and the reliability parameter were parsed and dropped, so what this
		// end sent back on it was retransmitted like everything else.
		var channel = @:privateAccess new DataChannel(transfer, streamId, message.label, !message.unordered, message.protocol,
			message.maxRetransmits, message.maxPacketLifeTime);
		__channels.set(streamId, channel);
		@:privateAccess channel.__onClosed = __release;

		transfer.send(streamId, DcepMessage.acknowledge().encode(), PPID_CONTROL, true, haxe.Timer.stamp());

		// Open at both ends the moment the acknowledgement goes out: this side
		// has everything it needs, and waiting for a reply to a reply would
		// never end.
		@:privateAccess channel.__acknowledge();
		onChannel(channel);
	}

	/**
		The next stream number for a channel this side opens.

		**Deliberately never reuses a closed channel's number.** Closing resets
		the stream at both ends, and a number is free again only once both
		resets are done -- the peer's answering one can be late, or never come
		from a peer without stream reconfiguration -- so a reused number could
		be one the far side still believes taken, and its own collision guard
		would refuse the OPEN in silence. Freeing the map entry is about not
		retaining a dead channel, and about letting the *peer* reopen on a
		number of its parity, whose sequence numbers the reset has started
		again; it is not licence to hand this side's numbers out twice.

		What changed is the end of the range. The counter used to run past 65535
		and keep going, while `SctpDataChunk` writes the number into a sixteen-
		bit field -- so after 32768 channels it wrapped on the wire and collided
		with a live stream, silently, while this map went on keying by the
		untruncated value. Running out now says so.
	**/
	@:noCompletion private function __freeStreamId():Int {
		while (__nextId <= MAX_STREAM_ID && __channels.exists(__nextId)) {
			__nextId += 2;
		}

		if (__nextId > MAX_STREAM_ID) {
			throw new crossbyte.errors.Error("Every stream number of this side's parity has been used.");
		}

		var id:Int = __nextId;
		__nextId += 2;
		return id;
	}

	/**
		A channel has closed: its stream number goes back into circulation for
		the peer, and the stream this end sends on is reset, which closes the
		peer's end of the channel -- after everything already sent on it.

		Guarded on identity because a handler on `onClose` may already have
		opened a replacement on that number, and dropping that one would lose a
		live channel.
	**/
	@:noCompletion private function __release(channel:DataChannel):Void {
		if (__channels.get(channel.id) == channel) {
			__channels.remove(channel.id);

			if (!__ending) {
				transfer.resetStreams([channel.id], transfer.association.clock);
			}
		}
	}
}
