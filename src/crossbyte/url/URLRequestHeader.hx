package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
final class URLRequestHeader {
	/**
		An HTTP request header name(such as `Content-Type` or
		`SOAPAction`).
	**/
	public var name:String;

	/**
		The value associated with the `name` property(such as
		`text/plain`).
	**/
	public var value:String;

	/**
		Creates a new URLRequestHeader object that encapsulates a single HTTP
		request header. URLRequestHeader objects are used in the
		`requestHeaders` property of the URLRequest class.
		@param name  An HTTP request header name(such as
					 `Content-Type` or `SOAPAction`).
		@param value The value associated with the `name` property
					(such as `text/plain`).
	**/
	public function new(name:String = "", value:String = "") {
		this.name = name;
		this.value = value;
	}

	public function toString():String {
		return '${this.name}:${this.value}';
	}
}
