package crossbyte.http;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;


/**
 * ...
 * @author Christopher Speciale
 */
class HTTPRequest 
{
	private var _origin:Socket;
	private var _incomingBuffer:ByteArray;
	public function new(socket:Socket) 
	{
		_origin = socket;
		_incomingBuffer = new ByteArray();
		_setup();
	}
	
	private function _setup():Void
	{
		_origin.addEventListener(ProgressEvent.SOCKET_DATA, _onData);
	}
	
	private function _onData(e:ProgressEvent):Void{
		_origin.readBytes(_incomingBuffer, _incomingBuffer.length);
		
		_readBuffer();
	}

	private function _readBuffer():Void{
		var req:Null<String> = readLine(_incomingBuffer);
		if (req == null){
			return;
		}
		
		var filePath:String = parseRequest(req);
		var file:File = File.applicationDirectory.resolvePath("root" + File.seperator + filePath);
		
		if (file.exists) {
            file.load();
		}
		
		if(file.data != null){
			var fileContent:String = file.data.readUTFBytes(file.data.length);

			if(_origin.connected){
				_origin.writeUTFBytes("HTTP/1.1 200 OK\r\n");
				_origin.writeUTFBytes("Content-Type: text/html\r\n");
				_origin.writeUTFBytes("\r\n");
				_origin.writeUTFBytes(fileContent);
				_origin.flush();
			}
			
        } else {
			if(_origin.connected){
				_origin.writeUTFBytes("HTTP/1.1 404 Not Found\r\n");
				_origin.writeUTFBytes("Content-Type: text/plain\r\n");
				_origin.writeUTFBytes("\r\n");
				_origin.writeUTFBytes("404 Not Found");
				_origin.flush();
			}			
        }	
	}
	
	private function readLine(buffer:ByteArray):Null<String> {
		var line:String = "";
		
		while (_incomingBuffer.position < _incomingBuffer.length) { // Read until newline character (ASCII 10)
			var char:Int = buffer.readByte();
			line += String.fromCharCode(char);
			
			if (char == 10){
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