class SocketChatSampleCheck {
	public static function main():Void {
		var serverMain = SocketChatServerSample.main;
		var clientMain = SocketChatClientSample.main;
		if (serverMain == null || clientMain == null) {
			throw "Chat samples failed to link.";
		}
	}
}
