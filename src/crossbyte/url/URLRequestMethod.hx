package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
enum abstract URLRequestMethod(String) from String to String {
	/**
		Specifies that the URLRequest object is a `DELETE`.
	**/
	public var DELETE = "DELETE";

	/**
		Specifies that the URLRequest object is a `GET`.
	**/
	public var GET = "GET";

	/**
		Specifies that the URLRequest object is a `HEAD`.
	**/
	public var HEAD = "HEAD";

	/**
		Specifies that the URLRequest object is `OPTIONS`.
	**/
	public var OPTIONS = "OPTIONS";

	/**
		Specifies that the URLRequest object is a `POST`.
	**/
	public var POST = "POST";

	/**
		Specifies that the URLRequest object is a `PUT`.
	**/
	public var PUT = "PUT";
}
