package crossbyte.net;

enum Transport {
	TCP(socket:Socket);
	UDP(socket:DatagramSocket);
	WEBSOCKET(socket:WebSocket);
}
