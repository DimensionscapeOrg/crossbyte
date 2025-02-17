package crossbyte.net;

import crossbyte.io.ByteArray;

@:forward
abstract NetConnection(INetConnection) from INetConnection{
	public static inline function fromSocket(socket:Socket):NetConnection {
        @:privateAccess
        var nc:NetConnection = new TCPConnection(socket);
        return nc;
	}

	public static inline function fromWebSocket(webSocket:WebSocket):NetConnection {
		@:privateAccess
        var nc:NetConnection = new WSConnection(webSocket);
        return nc;
	}

	public static inline function fromDatagramSocket(datagramSocket:DatagramSocket):NetConnection {
        @:privateAccess
		var nc:NetConnection = new UDPConnection(datagramSocket);
        return nc;
	}
}

private class TCPConnection implements INetConnection{
    public var socket:Socket;
    public var connected:Bool;
    public var protocol:Protocol = TCP;

    private function new(socket:Socket){
        this.socket = socket;
    }

    public function send(data:ByteArray):Void{
    }

    public function read():ByteArray{
        return null;
    }

    public function close():Void{
        socket.close();
    }
}

private class UDPConnection implements INetConnection{
    public var socket:DatagramSocket;
    public var connected:Bool;
    public var protocol:Protocol = UDP;


    private function new(socket:DatagramSocket){
        this.socket = socket;
    }

    public function send(data:ByteArray):Void{
    }

    public function read():ByteArray{
        return null;
    }

    public function close():Void{
       // socket.close();
    }
}

private class WSConnection implements INetConnection{
    public var socket:WebSocket;
    public var connected:Bool;
    public var protocol:Protocol = WEBSOCKET;


    private function new(socket:WebSocket){
        this.socket = socket;
    }

    public function send(data:ByteArray):Void{
    }

    public function read():ByteArray{
        return null;
    }

    public function close():Void{
        socket.close();
    }
}
