package crossbyte.net.rtc;

import crossbyte.Future;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;

/**
	One channel between two peers: messages in, messages out.

	The end of the whole stack. Underneath, ICE found a path, DTLS made it
	private, SCTP made it reliable and ordered, and DCEP turned a stream number
	into something with a name. What a caller sees is this.

	```haxe
	var chat = connection.createDataChannel("chat");

	chat.onMessage = function(text) {
		trace(text);
	};

	chat.opened.then(function(_) {
		chat.send("hello");
	});
	```

	## Messages, not bytes

	A channel carries whole messages. Send a megabyte and the far side gets a
	megabyte in one piece, or nothing -- never half of one and never two halves
	that have to be rejoined. That is the difference from a stream socket, and
	it is why an application on top needs no framing of its own.

	## Strings and bytes are different things

	They are told apart on the wire by the payload protocol identifier, so a
	peer knows which it received without guessing from the contents. An empty
	message of each kind has an identifier of its own, because a zero-length
	payload would otherwise be indistinguishable from no payload at all.
**/
class DataChannel {
	/** The name given when the channel was opened. Not unique, and not an address. **/
	public var label(default, null):String;

	/**
		The SCTP stream this runs on.

		Even when the peer that opened it was the DTLS client, odd when it was
		the server. That is the whole of how two peers opening channels at the
		same instant avoid choosing the same number.
	**/
	public var id(default, null):Int;

	/** Whether messages wait for those sent before them. **/
	public var ordered(default, null):Bool;

	/** An application-level protocol name, carried for the peer's benefit. **/
	public var protocol(default, null):String;

	/** Whether the channel has been acknowledged and can carry messages. **/
	public var open(default, null):Bool = false;

	/** Resolves once the peer has acknowledged the channel. **/
	public var opened(default, null):Future<DataChannel>;

	/** Called with each text message. **/
	public dynamic function onMessage(text:String):Void {}

	/** Called with each binary message. **/
	public dynamic function onBytes(payload:ByteArray):Void {}

	/** Called when the channel is closed, by either end. **/
	public dynamic function onClose():Void {}

	@:noCompletion private var __transfer:SctpDataTransfer;
	@:noCompletion private var __closed:Bool = false;

	@:allow(crossbyte.net.rtc)
	private function new(transfer:SctpDataTransfer, id:Int, label:String, ordered:Bool, protocol:String) {
		this.__transfer = transfer;
		this.id = id;
		this.label = label != null ? label : "";
		this.ordered = ordered;
		this.protocol = protocol != null ? protocol : "";
		this.opened = new Future<DataChannel>();
	}

	/**
		Sends text.

		@throws ArgumentError if the channel is not open yet. Buffering until it
		is would mean a caller cannot tell a message that was sent from one that
		is still waiting, and dropping it silently is worse.
	**/
	public function send(text:String):Void {
		__requireOpen();

		var payload = new ByteArray();

		if (text != null && text.length > 0) {
			payload.writeUTFBytes(text);
		}

		payload.position = 0;

		// The empty case has an identifier of its own, since nothing else
		// distinguishes an empty string from no payload.
		var protocolId:Int = payload.length > 0 ? SctpDataChunk.PPID_STRING : SctpDataChunk.PPID_STRING_EMPTY;
		__transfer.send(id, payload, protocolId, ordered, __now());
	}

	/** Sends bytes, which arrive as bytes rather than as text. **/
	public function sendBytes(payload:ByteArray):Void {
		__requireOpen();

		var length:Int = payload == null ? 0 : payload.length;
		var protocolId:Int = length > 0 ? SctpDataChunk.PPID_BINARY : SctpDataChunk.PPID_BINARY_EMPTY;

		__transfer.send(id, payload != null ? payload : new ByteArray(), protocolId, ordered, __now());
	}

	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;
		open = false;
		onClose();
	}

	@:allow(crossbyte.net.rtc)
	private function __acknowledge():Void {
		if (__closed || open) {
			return;
		}

		open = true;
		@:privateAccess opened.__resolve(this);
	}

	@:allow(crossbyte.net.rtc)
	private function __deliver(payload:ByteArray, protocolId:Int):Void {
		if (__closed) {
			return;
		}

		switch (protocolId) {
			case SctpDataChunk.PPID_STRING:
				payload.position = 0;
				onMessage(payload.length > 0 ? payload.readUTFBytes(payload.length) : "");
			case SctpDataChunk.PPID_STRING_EMPTY:
				onMessage("");
			case SctpDataChunk.PPID_BINARY:
				payload.position = 0;
				onBytes(payload);
			case SctpDataChunk.PPID_BINARY_EMPTY:
				onBytes(new ByteArray());
			default:
				// An identifier this does not know. Handed over as bytes rather
				// than dropped: a peer using one from a later revision is still
				// telling us something.
				payload.position = 0;
				onBytes(payload);
		}
	}

	@:noCompletion private function __requireOpen():Void {
		if (__closed) {
			throw new ArgumentError("This data channel is closed.");
		}

		if (!open) {
			throw new ArgumentError("This data channel is not open yet. Wait on `opened` before sending: a message sent now could only be dropped or buffered, and neither is what a caller expects.");
		}
	}

	@:noCompletion private inline function __now():Float {
		return haxe.Timer.stamp();
	}
}
