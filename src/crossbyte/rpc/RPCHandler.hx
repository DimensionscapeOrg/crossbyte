package crossbyte.rpc;

import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.Socket;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArrayInput;

@:autoBuild(crossbyte.rpc._internal.RPCHandlerMacro.build())
@:access(crossbyte.net.Socket)
abstract class RPCHandler {
	public static inline final MAX_FRAME_LEN:Int = 8 * 1024 * 1024;

	@:noCompletion private var this_connection:NetConnection;
	@:noCompletion private inline function this_socket_onData(input:ByteArrayInput):Void {

		while (input.bytesAvailable >= 8) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < 4 || (MAX_FRAME_LEN != 0 && payloadLen > MAX_FRAME_LEN)) {
				input.position = input.length;
				return;
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				return;
			}

			final frameEnd:Int = input.position + payloadLen;
			final op:Int = input.readInt();
			this.dispatch(op, input);
			input.position = frameEnd;
		}
	}


	abstract public function dispatch(op:Int, input:ByteArrayInput):Void;
	
	
	abstract public function ping():Void;
}
