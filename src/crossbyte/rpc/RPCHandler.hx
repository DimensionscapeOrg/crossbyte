package crossbyte.rpc;

// Not built for the browser: it dispatches on an RPCSession, which is not built there.

import crossbyte.net.NetConnection;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;

/**
	`RPCHandler` is the inbound implementation surface for CrossByte RPC sessions.

	A handler can be defined in two ways:

	- Manual mode: declare `@:rpc` methods directly on the subclass.
	- Contract mode: implement a single shared contract interface whose methods use
	  plain logical return types. The handler methods should match that interface
	  directly; unlike `RPCCommands`, handlers do not use `RPCResponse<T>` in their
	  method signatures.

	In contract mode, the shared interface can be used by `@:rpcContract(Contract)`
	on the command side, while the handler simply `implements Contract`.

	A handler method that throws answers its call with an error and leaves the
	connection up. Throw an `RPCError` for a failure the caller should see: its
	message is the caller's answer. Anything else reaches the caller as
	`RPCError.INTERNAL_MESSAGE`, and `RPCSession.onHandlerError` is told what
	it was. Only a frame that cannot be read -- too long, for no known method,
	or with arguments that do not decode -- ends the connection, since nothing
	after it could be trusted to line up. A handler that writes its own
	`dispatch` decodes and calls in one place, so whatever that throws still
	ends the connection.
**/
@:autoBuild(crossbyte.rpc._internal.RPCHandlerMacro.build())
@:access(crossbyte.net.Socket)
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
abstract class RPCHandler {
	public static inline final MAX_FRAME_LEN:Int = 8 * 1024 * 1024;

	@:noCompletion private var this_connection:NetConnection;
	@:noCompletion private var this_commands:RPCCommands;
	@:noCompletion private var this_session:RPCSession<Dynamic, Dynamic>;
	// Where the frame being dispatched ends; the generated decoders read no
	// further.
	@:noCompletion private var this_frameEnd:Int = RPCWire.NO_FRAME_END;

	@:noCompletion private inline function this_socket_onData(input:ByteArrayInput):Void {
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (MAX_FRAME_LEN != 0 && payloadLen > MAX_FRAME_LEN)) {
				throw "Invalid RPC frame length";
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			this_frameEnd = frameEnd;
			if (this_commands != null) {
				this_commands.__frameEnd = frameEnd;
			}
			final flags:Int = input.readByte();
			if ((flags & RPCWire.FLAG_RUNTIME) != 0) {
				throw "Runtime RPC frame delivered to compile-time handler lane";
			}
			final op:Int = input.readInt();
			if (flags == 0) {
				this.dispatch(op, input, 0);
			} else if (flags == RPCWire.FLAG_REQUEST) {
				this.dispatch(op, input, input.readVarUInt());
			} else if (flags == RPCWire.FLAG_RESPONSE) {
				final requestId:Int = input.readVarUInt();
				if (this_commands != null) {
					this_commands.__rpc_handle_response(op, requestId, input, false);
				}
			} else if (flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
				final requestId:Int = input.readVarUInt();
				if (this_commands != null) {
					this_commands.__rpc_handle_response(op, requestId, input, true);
				}
			} else {
				final requestId:Int = ((flags & RPCWire.FLAG_REQUEST) != 0) ? input.readVarUInt() : 0;
				this.dispatch(op, input, requestId);
			}
			input.position = frameEnd;
		}
		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			this_connection.inTimestamp = now;
		}
	}

	abstract public function dispatch(op:Int, input:ByteArrayInput, requestId:Int):Void;

	/**
		What a handler method throwing becomes, once its arguments have been
		read: an error answer to a request, and a report on this side of
		whatever the caller is not told.

		It used to reach the session as if the frame had been unreadable,
		which ended the connection and failed every call still waiting on it.
		The frame was sound -- only the method failed -- so the read goes on
		at the next one.
	**/
	@:noCompletion private function __rpc_fail(op:Int, method:String, requestId:Int, error:Dynamic):Void {
		final answer:Null<String> = RPCSession.__answerFor(error);
		if (requestId != 0) {
			__rpc_send_error(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
		}
		if ((answer == null || requestId == 0) && this_session != null) {
			this_session.__reportHandlerError(op, method, error);
		}
	}

	@:noCompletion private function __rpc_send_error(op:Int, requestId:Int, message:String):Void {
		final framed:ByteArrayOutput = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
		framed.writeInt(op);
		framed.writeVarUInt(requestId);
		framed.writeVarUTF(message);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		this_connection.send(framed);
	}

	/**
		Built-in heartbeat/system ping. This stays on the handler surface and should not
		be declared inside shared RPC contract interfaces.
	**/
	abstract public function ping():Void;
}
