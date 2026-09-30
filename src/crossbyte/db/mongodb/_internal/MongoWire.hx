package crossbyte.db.mongodb._internal;

#if !js
import crossbyte._internal.socket.FlexSocket;
import crossbyte.errors.IOError;
import haxe.io.Bytes;

/**
	MongoDB's OP_MSG framing over one blocking socket.

	A message is a 16-byte header, length, request id, the id it answers,
	and the opcode, 2013, then flag bits and sections: one of kind 0, the
	command's body document, and any of kind 1, a named sequence of documents
	sent beside the body rather than as an array inside it. Compression is
	never negotiated, so OP_COMPRESSED never arrives; nor does the legacy
	OP_REPLY, since nothing here sends OP_QUERY.

	Replies are read into one buffer the connection keeps, a few reads at
	most for a small one, and decoded straight out of it. A reply's length is
	checked against the most the server said it would send before any of it
	is allocated for, so a corrupt or hostile length cannot make this reserve
	gigabytes.
**/
class MongoWire {
	public static inline var OP_MSG:Int = 2013;
	public static inline var OP_COMPRESSED:Int = 2012;
	public static inline var CHECKSUM_PRESENT:Int = 1;
	public static inline var MORE_TO_COME:Int = 2;
	public static inline var EXHAUST_ALLOWED:Int = 1 << 16;

	/** What the buffer shrinks back to after a large reply, so an idle pooled connection does not keep it. **/
	@:noCompletion private static inline var IDLE_CAPACITY:Int = 16 * 1024;

	public var socket(default, null):FlexSocket;
	public var reader(default, null):BsonReader;

	/** The largest message the server will send, from its hello; 48 MB until then. **/
	public var maxMessageSize:Int = 48000000;

	/** Where the server is, for messages. **/
	public var peer(default, null):String;

	@:noCompletion private var __in:Bytes;
	@:noCompletion private var __held:Int = 0;
	@:noCompletion private var __requestId:Int = 0;
	@:noCompletion private var __closed:Bool = false;

	public function new(socket:FlexSocket, reader:BsonReader, peer:String) {
		this.socket = socket;
		this.reader = reader;
		this.peer = peer;
		__in = Bytes.alloc(IDLE_CAPACITY);
	}

	/** A fresh request id: positive, and not repeated on this connection until it wraps. **/
	public function nextRequestId():Int {
		__requestId = (__requestId + 1) & 0x7FFFFFFF;

		if (__requestId == 0) {
			__requestId = 1;
		}

		return __requestId;
	}

	/**
		Sends the whole message `writer` holds, from its first byte.

		@throws IOError When the connection fails; it is closed then.
	**/
	public function send(writer:BsonWriter):Void {
		if (__closed) {
			throw new IOError('The connection to $peer is closed.');
		}

		try {
			socket.output.writeFullBytes(writer.buffer, 0, writer.length);
		} catch (e:Dynamic) {
			close();
			throw new IOError('Sending to MongoDB at $peer failed: ${Std.string(e)}');
		}
	}

	/**
		Reads the reply to `requestId` and answers its body document, with any
		document sequences it carried set on it as arrays.

		@throws IOError When the connection fails or the reply is not a
		well-formed answer to that request; the connection is closed then,
		since where the next message starts is no longer known.
	**/
	public function receive(requestId:Int):Dynamic {
		if (__closed) {
			throw new IOError('The connection to $peer is closed.');
		}

		try {
			return __receive(requestId);
		} catch (e:IOError) {
			close();
			throw e;
		} catch (e:haxe.io.Eof) {
			close();
			throw new IOError('MongoDB at $peer closed the connection.');
		} catch (e:Dynamic) {
			close();
			throw new IOError('Reading from MongoDB at $peer failed: ${Std.string(e)}');
		}
	}

	public var closed(get, never):Bool;

	private inline function get_closed():Bool {
		return __closed;
	}

	public function close():Void {
		if (__closed) {
			return;
		}

		__closed = true;

		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __receive(requestId:Int):Dynamic {
		__fill(16);
		var bytes:Bytes = __in;
		var length:Int = bytes.getInt32(0);

		// Slack for the header and the envelope a batch of documents at the
		// size limit travels in.
		if (length < 21 || length > maxMessageSize + 16 * 1024) {
			throw new IOError('MongoDB at $peer sent a message claiming $length bytes; that is not a message this connection can be in step with.');
		}

		if (length > __in.length) {
			var grown:Bytes = Bytes.alloc(length);
			grown.blit(0, __in, 0, __held);
			__in = grown;
		}

		__fill(length);
		bytes = __in;
		var responseTo:Int = bytes.getInt32(8);
		var opCode:Int = bytes.getInt32(12);

		if (opCode != OP_MSG) {
			throw new IOError(opCode == OP_COMPRESSED ? 'MongoDB at $peer sent a compressed message, though compression was not agreed.' : 'MongoDB at $peer sent opcode $opCode where OP_MSG was expected.');
		}

		if (responseTo != requestId) {
			throw new IOError('MongoDB at $peer answered request $responseTo while $requestId was waiting.');
		}

		var flags:Int = bytes.getInt32(16);

		// Bits 0 to 15 must be understood; an unknown one set there is a
		// message this client cannot read correctly.
		if ((flags & 0xFFFF & ~(CHECKSUM_PRESENT | MORE_TO_COME)) != 0) {
			throw new IOError('MongoDB at $peer sent OP_MSG flags 0x${StringTools.hex(flags)} this client does not know.');
		}

		if ((flags & MORE_TO_COME) != 0) {
			throw new IOError('MongoDB at $peer began a stream of replies, which nothing here asked for.');
		}

		// A checksum, when present, is the last four bytes; TCP has already
		// checked the bytes, so it is stepped over rather than recomputed.
		var end:Int = length - ((flags & CHECKSUM_PRESENT) != 0 ? 4 : 0);
		var position:Int = 20;
		var body:Dynamic = null;
		var sequences:Array<{name:String, documents:Array<Dynamic>}> = null;

		while (position < end) {
			var kind:Int = bytes.get(position++);

			if (kind == 0) {
				if (body != null) {
					throw new IOError('MongoDB at $peer sent a message with two bodies.');
				}

				body = reader.readDocument(bytes, position, end);
				position = reader.end;
			} else if (kind == 1) {
				if (position + 4 > end) {
					throw new IOError('MongoDB at $peer sent a truncated document sequence.');
				}

				var size:Int = bytes.getInt32(position);
				var sequenceEnd:Int = position + size;

				if (size < 5 || sequenceEnd > end) {
					throw new IOError('MongoDB at $peer sent a document sequence claiming $size bytes.');
				}

				var nameStart:Int = position + 4;
				var nameEnd:Int = nameStart;

				while (nameEnd < sequenceEnd && bytes.get(nameEnd) != 0) {
					nameEnd++;
				}

				if (nameEnd >= sequenceEnd) {
					throw new IOError('MongoDB at $peer sent a document sequence without a name.');
				}

				var documents:Array<Dynamic> = [];
				position = nameEnd + 1;

				while (position < sequenceEnd) {
					documents.push(reader.readDocument(bytes, position, sequenceEnd));
					position = reader.end;
				}

				if (sequences == null) {
					sequences = [];
				}

				sequences.push({name: bytes.getString(nameStart, nameEnd - nameStart), documents: documents});
			} else {
				throw new IOError('MongoDB at $peer sent a section of unknown kind $kind.');
			}
		}

		if (body == null) {
			throw new IOError('MongoDB at $peer sent a reply without a body.');
		}

		if (sequences != null) {
			// A sequence stands for an array field of the body, by name.
			for (sequence in sequences) {
				if (Std.isOfType(body, crossbyte.db.mongodb.bson.BsonDocument)) {
					(body : crossbyte.db.mongodb.bson.BsonDocument).set(sequence.name, sequence.documents);
				} else {
					Reflect.setField(body, sequence.name, sequence.documents);
				}
			}
		}

		__consume(length);
		return body;
	}

	/** Reads until at least `count` bytes are held. **/
	@:noCompletion private function __fill(count:Int):Void {
		while (__held < count) {
			var read:Int = socket.input.readBytes(__in, __held, __in.length - __held);

			if (read <= 0) {
				throw new IOError('MongoDB at $peer closed the connection.');
			}

			__held += read;
		}
	}

	/** Drops the message just read, keeping anything after it. **/
	@:noCompletion private function __consume(length:Int):Void {
		var rest:Int = __held - length;

		if (rest > 0) {
			__in.blit(0, __in, length, rest);
		}

		__held = rest;

		if (__in.length > 1024 * 1024 && rest <= IDLE_CAPACITY) {
			var small:Bytes = Bytes.alloc(IDLE_CAPACITY);
			small.blit(0, __in, 0, rest);
			__in = small;
		}
	}
}
#end
