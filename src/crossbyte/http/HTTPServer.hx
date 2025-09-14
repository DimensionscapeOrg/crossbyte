package crossbyte.http;

import haxe.ds.ObjectMap;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServerConfig;
import crossbyte.utils.Logger;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPServer extends ServerSocket {
	private var __config:HTTPServerConfig;
	private var __active:ObjectMap<Dynamic, HTTPRequestHandler>;
	private var __maxConnections:Int;
	private var __connections:Int;

	public function new(config:HTTPServerConfig) {
		super();
		__connections = 0;
		__config = config;
		__active = new ObjectMap();
		__maxConnections = config.maxConnections;

		addEventListener(ServerSocketConnectEvent.CONNECT, this_onConnect);

		try {
			bind(__config.port, __config.address);
			listen(__config.backlog);
			Logger.info('HTTP Server started on ${__config.address}:${__config.port}');
		} catch (e:Dynamic) {
			Logger.error('HTTP Server failed to start on ${__config.address}:${__config.port}: ' + e);
			throw e;
		}
	}

	private function this_onConnect(e:ServerSocketConnectEvent):Void {
		if (__connections >= __maxConnections) {
			Logger.error('Connection refused: concurrency limit ${__maxConnections}');
			try {
				e.socket.writeUTFBytes('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
				e.socket.flush();
			} catch (_:Dynamic) {}
			try
				e.socket.close()
			catch (_:Dynamic) {}
			return;
		}

		var handler:HTTPRequestHandler = new HTTPRequestHandler(e.socket, __config);
		__active.set(e.socket, handler);
		__connections++;
		
		handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, this_onResponse);

		e.socket.addEventListener("close", (_) -> cleanupSocket(e.socket));
		e.socket.addEventListener("error", (_) -> cleanupSocket(e.socket));
	}

	private function cleanupSocket(sock:Dynamic):Void {
		if (__active.exists(sock)){
			__active.remove(sock);
		}
			
	}

	private function this_onResponse(e:HTTPStatusEvent):Void {
		Logger.info(e.toString());
	}
}
