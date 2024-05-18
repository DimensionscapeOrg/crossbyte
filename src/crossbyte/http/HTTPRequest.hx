package crossbyte.http;

import crossbyte.events.EventDispatcher;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import crossbyte.url.URLRequestHeader;

/**
 * Represents an HTTP request handler.
 */
class HTTPRequest extends EventDispatcher {
    private var _origin:Socket;
    private var _incomingBuffer:ByteArray;

    public function new(socket:Socket) {
		super();
		
        _origin = socket;
        _incomingBuffer = new ByteArray();
        _setup();
    }

    private function _setup():Void {
        _origin.addEventListener(ProgressEvent.SOCKET_DATA, _onData);
    }

    private function _onData(e:ProgressEvent):Void {
        _origin.readBytes(_incomingBuffer, _incomingBuffer.length);
        _readBuffer();
    }

    private function _readBuffer():Void {
        var req:Null<String> = readLine(_incomingBuffer);
        if (req == null) {
            return;
        }

        var filePath:String = parseRequest(req);
        serveFile(filePath);
    }

    private function serveFile(filePath:String):Void {
        var file:File = File.applicationDirectory.resolvePath("root/" + filePath);

        if (file.exists && !file.isDirectory) {
			file.load();
			
            var fileContent:String = file.data.readUTFBytes(file.data.length);

            dispatchResponse(200, file.nativePath, null);//, "text/html", fileContent);
        } else {
            dispatchResponse(404, file.nativePath, null);//, "text/plain", "404 Not Found");
        }

        _origin.close();
    }

    private function dispatchResponse(statusCode:Int, url:String, headers:Array<URLRequestHeader>):Void {
		
		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = url;
		statusEvent.responseHeaders = headers;
		
		dispatchEvent(statusEvent);
		
		if (_origin.connected) {
            var response:String = "HTTP/1.1 " + statusCode + " " + getStatusMessage(statusCode) + "\r\n";
            response += "Content-Type: " + contentType + "\r\n";
            response += "\r\n";
            response += content;

            _origin.writeUTFBytes(response);
            _origin.flush();
        }
    }

    private function getStatusMessage(statusCode:Int):String {
        switch (statusCode) {
            case 200: return "OK";
            case 404: return "Not Found";
            default: return "Unknown";
        }
    }

    private function readLine(buffer:ByteArray):Null<String> {
        var line:String = "";

        while (_incomingBuffer.position < _incomingBuffer.length) {
            var char:Int = buffer.readByte();
            line += String.fromCharCode(char);

            if (char == 10) { // Newline character
                return line;
            }
        }

        return null;
    }

    static function parseRequest(request:String):String {
        var parts:Array<String> = request.split(" ");
        var filePath:String = parts[1];

        if (filePath.charAt(0) == '/') {
            filePath = filePath.substring(1);
        }

        return filePath;
    }
}