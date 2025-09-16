package crossbyte.http;

import haxe.io.Path;
import haxe.ds.ObjectMap;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.http.HTTPRequestHandler;
import crossbyte.http.HTTPServerConfig;
import crossbyte.utils.Logger;
import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPMode;

using StringTools;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPServer extends ServerSocket {
	private var __config:HTTPServerConfig;
	private var __active:ObjectMap<Dynamic, HTTPRequestHandler>;
	private var __maxConnections:Int;
	private var __connections:Int;
	private var docRoot = "./www";
	private var autoIndex = ["index.php", "index.html"];
	private var php:PHPBridge;

	public function new(config:HTTPServerConfig) {
		super();
		__connections = 0;
		__config = config;
		__active = new ObjectMap();
		__maxConnections = config.maxConnections;

		if (__config.phpEnabled) {
			var mode:PHPMode = switch (__config.phpMode) {
				case 0: Connect("127.0.0.1", 6666);
				case 1: Launch("127.0.0.1", 6666, __config.phpCGIPath, __config.phpINIPath);
				default:
					throw "Invalid PHPMode enum";
			}
			php = new PHPBridge(mode, docRoot, autoIndex);
		}

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

		var handler:HTTPRequestHandler = new HTTPRequestHandler(e.socket, __config, php);
		__active.set(e.socket, handler);
		__connections++;

		handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, this_onResponse);

		e.socket.addEventListener("close", (_) -> cleanupSocket(e.socket));
		e.socket.addEventListener("error", (_) -> cleanupSocket(e.socket));
	}

	private function cleanupSocket(sock:Dynamic):Void {
		if (__active.exists(sock)) {
			__active.remove(sock);
			if (__connections > 0) {
				__connections--;
			}
		}

		if (php != null) {
			try {
				php.stop();
			} catch (_:Dynamic) {}
			php = null;
		}
	}

	private function this_onResponse(e:HTTPStatusEvent):Void {
		Logger.info(e.toString());
	}

	private function sanitizePath(docRoot:String, uriPath:String):{abs:String, isDir:Bool} {
		var p = StringTools.urlDecode(uriPath);
		p = p.split("?")[0];
		p = p.replace("\\", "/");
		if (p.indexOf("..") >= 0) {
			throw "403";
		}

		final rootNorm:String = Path.normalize(docRoot);
		final rootNormSlash:String = rootNorm.endsWith("/") ? rootNorm : rootNorm + "/";

		var abs:String = Path.normalize(rootNormSlash + (p.startsWith("/") ? p.substr(1) : p));
		var absSlash:String = abs.endsWith("/") ? abs : abs + "/";

		if (!(abs == rootNorm || abs.startsWith(rootNormSlash))) {
			throw "403";
		}

		final isDir:Bool = sys.FileSystem.exists(abs) && sys.FileSystem.isDirectory(abs);
		return {abs: abs, isDir: isDir};
	}

	private function pickIndex(absDir:String, autoIndex:Array<String>):Null<String> {
		for (name in autoIndex) {
			var path:String = Path.join([absDir, name]);
			if (sys.FileSystem.exists(path)) {
				return path;
			}
		}
		return null;
	}

	private function contentType(path:String):String {
		final ext = Path.extension(path).toLowerCase();
		return switch ext {
			case "html", "htm": "text/html; charset=utf-8";
			case "css": "text/css; charset=utf-8";
			case "js": "application/javascript; charset=utf-8";
			case "png": "image/png";
			case "jpg", "jpeg": "image/jpeg";
			case "gif": "image/gif";
			case "svg": "image/svg+xml";
			case "webp": "image/webp";
			case "ico": "image/x-icon";
			case "json": "application/json; charset=utf-8";
			case "txt": "text/plain; charset=utf-8";
			default: "application/octet-stream";
		}
	}
}
