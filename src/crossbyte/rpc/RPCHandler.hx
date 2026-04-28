package crossbyte.rpc;

import crossbyte.net.NetConnection;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.io.ByteArrayInput;

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
				input.position = input.length;
				return;
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			final flags:Int = input.readByte();
			final op:Int = input.readInt();
			if ((flags & RPCWire.FLAG_RESPONSE) != 0) {
				final requestId:Int = input.readVarUInt();
				if (this_commands != null) {
					this_commands.__rpc_handle_response(op, requestId, input, (flags & RPCWire.FLAG_ERROR) != 0);
				}
			} else {
				final requestId:Int = ((flags & RPCWire.FLAG_REQUEST) != 0) ? input.readVarUInt() : 0;
				this.dispatch(op, input, requestId);
			}
			input.position = frameEnd;
		}
		@:privateAccess
		try {
			this_connection.inTimestamp = Timer.getTime();
		} catch (_:Dynamic) {}
	}

	abstract public function dispatch(op:Int, input:ByteArrayInput, requestId:Int):Void;

	abstract public function ping():Void;
}
