package crossbyte._internal.http;

import haxe.io.Bytes;

/**
 * @author Christopher Speciale
 */
enum ContentType {
	XML(data:String);
	JSON(data:String);
	IMAGE(data:Bytes);
	TEXT(data:String);
	BINARY(data:Bytes);
	NONE;
}
