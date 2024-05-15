package crossbyte.http;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.http.HTTPRequest;
import crossbyte.net.Socket;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPServer extends ServerSocket 
{

	
	public function new(address:String = "0.0.0.0", port:UInt = 3000){
		super();
		
		addEventListener(ServerSocketConnectEvent.CONNECT, this_onConnect);
		bind(port, address);
		listen();
	}
	
	private function this_onConnect(e:ServerSocketConnectEvent):Void{
		var httpRequest:HTTPRequest = new HTTPRequest(e.socket);
		
	}
	
}