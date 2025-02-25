package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract URLLoaderDataFormat(Null<Int>)
{
	/**
		Specifies that downloaded data is received as raw binary data.
	**/
	public var BINARY = 0;

	/**
		Specifies that downloaded data is received as text.
	**/
	public var TEXT = 1;

	/**
		Specifies that downloaded data is received as URL-encoded variables.
	**/
	public var VARIABLES = 2;

	@:from private static function fromString(value:String):URLLoaderDataFormat
	{
		return switch (value)
		{
			case "binary": BINARY;
			case "text": TEXT;
			case "variables": VARIABLES;
			default: null;
		}
	}

	@:to private function toString():String
	{
		return switch (cast this : URLLoaderDataFormat)
		{
			case URLLoaderDataFormat.BINARY: "binary";
			case URLLoaderDataFormat.TEXT: "text";
			case URLLoaderDataFormat.VARIABLES: "variables";
			default: null;
		}
	}
}