package crossbyte.url;

/** Process-wide defaults applied to newly created `URLRequest` instances. */
class URLRequestDefaults {
	/**
		The default `followRedirects` for new URLRequest objects. Setting the
		property on a request overrides this.

		The default value is `true`.
	**/
	public static var followRedirects:Bool = true;

	/**
		The default `idleTimeout` for new URLRequest objects, in milliseconds --
		how long the client waits for a response after the connection is
		established before abandoning the request. Setting the property on a
		request overrides this.

		The default value is 0, which here means unset rather than no limit:
		a request takes this value only when it is greater than zero, and
		otherwise starts at 30000. To give a request no limit, set its own
		`idleTimeout` to `0`.
	**/
	public static var idleTimeout:Int = 0;

	/**
		The default `manageCookies` for new URLRequest objects. Setting the
		property on a request overrides this.

		The default value is `true`.
	**/
	public static var manageCookies:Bool = true;

	/**
		The default `userAgent` for new URLRequest objects. Setting the property
		on a request overrides this.

		Unset, and while it is null the client sends `CrossByte`; a browser
		sends its own. See `URLRequest.userAgent`.
	**/
	public static var userAgent:String;
}
