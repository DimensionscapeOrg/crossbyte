package crossbyte.rpc;

import crossbyte.net.NetConnection;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.io.ByteArrayInput;

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
**/
@:autoBuild(crossbyte.rpc._internal.RPCHandlerMacro.build())
@:access(crossbyte.net.Socket)
abstract class RPCHandler {
	public static inline final MAX_FRAME_LEN:Int = 8 * 1024 * 1024;

	@:noCompletion private var this_connection:NetConnection;
	@:noCompletion private var this_commands:RPCCommands;

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
			final flags:Int = input.readByte();
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
		Built-in heartbeat/system ping. This stays on the handler surface and should not
		be declared inside shared RPC contract interfaces.
	**/
	abstract public function ping():Void;
}
