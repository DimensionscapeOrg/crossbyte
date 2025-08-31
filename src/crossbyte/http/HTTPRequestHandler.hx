package crossbyte.http;

import crossbyte.events.EventDispatcher;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.Logger;

class HTTPRequestHandler extends EventDispatcher {
	private static inline var MAX_BUFFER_SIZE:Int = 1024 * 1024; // 1 MB

	private var _origin:Socket;
	private var _incomingBuffer:ByteArray;
	private var _config:HTTPServerConfig;
	private var _headers:Map<String, String>;
	private var _method:String;
	private var _filePath:String;
	private var _httpVersion:String;

	public function new(socket:Socket, config:HTTPServerConfig) {
		super();
		_origin = socket;
		_config = config;
		_incomingBuffer = new ByteArray();
		_headers = new Map<String, String>();
		_setup();
	}

	private function _setup():Void {
		_origin.addEventListener(ProgressEvent.SOCKET_DATA, _onData);
	}

	private function _onData(e:ProgressEvent):Void {
		try {
			if (_incomingBuffer.length > MAX_BUFFER_SIZE) {
				throw "Request too large";
			}
			_origin.readBytes(_incomingBuffer, _incomingBuffer.length);
			_parseRequest();
		} catch (error:Dynamic) {
			Logger.error("Error reading data: " + error);
			_sendErrorResponse(500, "Internal Server Error");
		}
	}

	private function _parseRequest():Void {
		var requestLine:Null<String> = readLine(_incomingBuffer);
		trace(requestLine);
		if (requestLine == null) {
			return;
		}

		var parts:Array<String> = requestLine.split(" ");
		_method = parts[0].toUpperCase();
		_filePath = _config.rootDirectory.resolvePath(parts[1]).nativePath;
		_httpVersion = parts[2];
		// Parse headers
		while (true) {
			var headerLine:Null<String> = readLine(_incomingBuffer);
			if (headerLine == null || headerLine == "\r\n" || headerLine == "\n") {
				break;
			}

			var headerParts:Array<String> = headerLine.split(": ");
			if (headerParts.length == 2) {
				_headers.set(headerParts[0], headerParts[1]);
			}
		}

		for (hdr in _headers) {
			trace(hdr);
		}
		switch (_method) {
			case "GET":
				serveFile(_filePath);
			case "HEAD":
				serveFile(_filePath, true);
			case "OPTIONS":
				if (_config.corsEnabled) {
					handleOptionsRequest();
				} else {
					_sendErrorResponse(405, "Method Not Allowed");
				}
			default:
				_sendErrorResponse(405, "Method Not Allowed");
		}
	}

	private function handleOptionsRequest():Void {
		var response:String = "HTTP/1.1 204 No Content\r\n";
		response += "Access-Control-Allow-Origin: " + _config.corsAllowedOrigins.join(", ") + "\r\n";
		response += "Access-Control-Allow-Methods: " + _config.corsAllowedMethods.join(", ") + "\r\n";
		response += "Access-Control-Allow-Headers: " + _config.corsAllowedHeaders.join(", ") + "\r\n";
		response += "Content-Length: 0\r\n";
		response += "\r\n";

		_origin.writeUTFBytes(response);
		_origin.flush();
		_origin.close();
	}

	private function serveFile(filePath:String, headOnly:Bool = false):Void {
		var safeFilePath:String = sanitizePath(filePath);
		var file:File = new File(filePath);

		if (_config.blacklist.indexOf(file.nativePath) != -1) {
			dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}

		if (_config.whitelist.length > 0 && _config.whitelist.indexOf(file.nativePath) == -1) {
			dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}

		if (file.exists && !file.isDirectory) {
			file.load();
			var fileContent:String = file.data.readUTFBytes(file.data.length);
			var mimeType:String = getMimeType(file.nativePath);
			dispatchResponse(200, file.nativePath, null, mimeType, fileContent, headOnly);
		} else if (file.isDirectory) {
			var indexFile:String = findIndexFile(file);
			if (indexFile != null) {
				serveFile(indexFile, headOnly);
			} else {
				dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			}
		} else {
			dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
		}

		if (!headOnly) {
			if (_origin.connected) {
				_origin.close();
			}
		}
	}

	private function findIndexFile(directory:File):Null<String> {
		for (index in _config.directoryIndex) {
			var indexPath:File = directory.resolvePath(index);
			if (indexPath.exists) {
				return indexPath.nativePath;
			}
		}
		return null;
	}

	private function dispatchResponse(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String, content:String,
			headOnly:Bool = false):Void {
		var clientAddress:String = _origin.remoteAddress;
		Logger.info("Client " + clientAddress + " requested " + _origin.remoteAddress + " - Status: " + statusCode);

		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = _origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		if (_origin.connected) {
			var response:String = "HTTP/1.1 " + statusCode + " " + statusMessage + "\r\n";
			response += "Content-Type: " + contentType + "\r\n";

			if (_config.corsEnabled) {
				response += "Access-Control-Allow-Origin: " + _config.corsAllowedOrigins.join(", ") + "\r\n";
			}

			for (header in _config.customHeaders) {
				response += header.name + ": " + header.value + "\r\n";
			}

			response += "Content-Length: " + content.length + "\r\n";
			response += "\r\n";

			if (!headOnly) {
				response += content;
			}

			_origin.writeUTFBytes(response);
			_origin.flush();
		}
	}

	private function _sendErrorResponse(statusCode:Int, message:String):Void {
		dispatchResponse(statusCode, message, null, "text/plain", message);
		if (_origin.connected) {
			_origin.close();
		}
	}

	private function getStatusMessage(statusCode:Int):String {
		switch (statusCode) {
			case 200:
				return "OK";
			case 403:
				return "Forbidden";
			case 404:
				return "Not Found";
			case 405:
				return "Method Not Allowed";
			case 500:
				return "Internal Server Error";
			default:
				return "Unknown";
		}
	}

	private function readLine(buffer:ByteArray):Null<String> {
		var line:String = "";
		while (buffer.position < buffer.length) {
			var char:Int = buffer.readByte();
			line += String.fromCharCode(char);
			if (char == 10) {
				return line;
			}
		}
		return null;
	}

	private function sanitizePath(filePath:String):String {
		var safePath:String = StringTools.replace(StringTools.replace(filePath, "../", ""), "..\\", "");
		return safePath;
	}

	private function getMimeType(filePath:String):String {
		var extension:String = filePath.split('.').pop().toLowerCase();
		return switch (extension) {
			case "html", "htm": "text/html";
			case "css": "text/css";
			case "js": "application/javascript";
			case "png": "image/png";
			case "jpg", "jpeg": "image/jpeg";
			case "gif": "image/gif";
			case "txt": "text/plain";
			default: "application/octet-stream";
		}
	}
}
