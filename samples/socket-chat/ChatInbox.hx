import crossbyte.io.ByteArray;

class ChatInbox {
	private var buffer:ByteArray;

	public function new() {
		buffer = new ByteArray();
	}

	public function append(bytes:ByteArray):Void {
		buffer.position = buffer.length;
		buffer.writeBytes(bytes, 0, bytes.length);
		buffer.position = 0;
	}

	public function drain(onMessage:String->Void):Void {
		while (true) {
			var frameStart = buffer.position;
			if (buffer.bytesAvailable < 2) {
				buffer.position = frameStart;
				break;
			}

			var length = buffer.readUnsignedShort();
			if (buffer.bytesAvailable < length) {
				buffer.position = frameStart;
				break;
			}

			onMessage(buffer.readUTFBytes(length));
		}

		compact();
	}

	private function compact():Void {
		if (buffer.position <= 0) {
			return;
		}

		if (buffer.bytesAvailable <= 0) {
			buffer.clear();
			return;
		}

		var remaining = new ByteArray();
		remaining.writeBytes(buffer, buffer.position, buffer.bytesAvailable);
		remaining.position = 0;
		buffer = remaining;
	}
}
