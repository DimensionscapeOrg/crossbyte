package crossbyte.http;

import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.File;
import crossbyte.net.ServerSocket;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.net.Socket;
import crossbyte.http.HTTPServerConfig;
import crossbyte.utils.Logger;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPServer extends ServerSocket {
	private var _config:HTTPServerConfig;

	public function new(config:HTTPServerConfig) {
		super();
		_config = config;
		addEventListener(ServerSocketConnectEvent.CONNECT, this_onConnect);
		bind(_config.port, _config.address);
		listen();
		Logger.info("HTTP Server started on " + _config.address + ":" + _config.port);
	}

	private function this_onConnect(e:ServerSocketConnectEvent):Void {
		var httpRequest:HTTPRequestHandler = new HTTPRequestHandler(e.socket, _config);
		httpRequest.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, this_onResponse);
	}

	private function this_onResponse(e:HTTPStatusEvent):Void {
		Logger.info(e.toString());
	}
}
