package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
class URLRequest {
	public var contentType:String;

	/**
		**Note**: The value of `contentType` must correspond to
		the type of data in the `data` property. See the note in the
		description of the `contentType` property.
	**/
	public var data:Dynamic;

	/**
		Specifies whether redirects are to be followed (`true`) or not (`false`).
		**Note:** The `FileReference.upload()`, `FileReference.download()`, and
		`HTMLLoader.load()` methods do not support the `URLRequest.followRedirects` property.
		The default value is `true`.
	**/
	public var followRedirects:Bool;

	/**
		Specifies the idle timeout value (in milliseconds) for this request.
		The idle timeout is the amount of time the client waits for a response from the
		server, after the connection is established, before abandoning the request.
		**Note:** The `HTMLLoader.load()` method does not support the
		`URLRequest.idleTimeout` property. The HTMLLoader class defines its own
		`idleTimeout` property.
		The default value is initialized from the `URLRequestDefaults.idleTimeout` property.
	**/
	public var idleTimeout:Float;

	/**
		Specifies whether the HTTP protocol stack should manage cookies for this request.
		When `true`, cookies are added to the request and response cookies are remembered.
		If `false`, cookies are not added to the request and response cookies are not
		remembered, but users can manage cookies themselves by direct header manipulation.
		**Note:** On Windows, you cannot add cookies to a URL request manually when
		`manageCookies` is set to `true`. On other operating systems, adding cookies to a
		request is permitted irrespective of whether `manageCookies` is set to `true` or
		`false`. When permitted, you can add cookies to a request manually by adding a
		URLRequestHeader object containing the cookie data to the `requestHeaders` array.
		On Mac OS, cookies are shared with Safari. To clear cookies on Mac OS:
		1. Open Safari.
		2. Select Safari > Preferences, and click the Security panel.
		3. Click the Show Cookies button.
		4. Click the Reomove All button.
		To clear cookies on Windows:
		1. Open the Internet Properties control panel, and click the General tab.
		2. Click the Delete Cookies button.
		The default value is `true`.
	**/
	public var manageCookies:Bool;

	/**
		Controls the HTTP form submission method.
		For SWF content running in Flash Player(in the browser), this property
		is limited to GET or POST operations, and valid values are
		`URLRequestMethod.GET` or
		`URLRequestMethod.POST`.
		For content running in Adobe AIR, you can use any string value if the
		content is in the application security sandbox. Otherwise, as with content
		running in Flash Player, you are restricted to using GET or POST
		operations.
		For content running in Adobe AIR, when using the
		`navigateToURL()` function, the runtime treats a URLRequest
		that uses the POST method(one that has its `method` property
		set to `URLRequestMethod.POST`) as using the GET method.
		**Note:** If running in Flash Player and the referenced form has no
		body, Flash Player automatically uses a GET operation, even if the method
		is set to `URLRequestMethod.POST`. For this reason, it is
		recommended to always include a "dummy" body to ensure that the correct
		method is used.
		@default URLRequestMethod.GET
		@throws ArgumentError If the `value` parameter is not
							  `URLRequestMethod.GET` or
							  `URLRequestMethod.POST`.
	**/
	public var method:String;

	/**
		The array of HTTP request headers to be appended to the HTTP request. The
		array is composed of URLRequestHeader objects. Each object in the array
		must be a URLRequestHeader object that contains a name string and a value
		string, as follows:
		Flash Player and the AIR runtime impose certain restrictions on request
		headers; for more information, see the URLRequestHeader class
		description.
		Not all methods that accept URLRequest parameters support the
		`requestHeaders` property, consult the documentation for the
		method you are calling. For example, the
		`FileReference.upload()` and
		`FileReference.download()` methods do not support the
		`URLRequest.requestHeaders` property.
		Due to browser limitations, custom HTTP request headers are only
		supported for `POST` requests, not for `GET`
		requests.
	**/
	public var requestHeaders:Array<URLRequestHeader>;

	/**
		The URL to be requested.
		Be sure to encode any characters that are either described as unsafe in
		the Uniform Resource Locator specification(see
		http://www.faqs.org/rfcs/rfc1738.html) or that are reserved in the URL
		scheme of the URLRequest object(when not used for their reserved
		purpose). For example, use `"%25"` for the percent(%) symbol
		and `"%23"` for the number sign(#), as in
		`"http://www.example.com/orderForm.cfm?item=%23B-3&discount=50%25"`.
		By default, the URL must be in the same domain as the calling file,
		unless the content is running in the Adobe AIR application security
		sandbox. If you need to load data from a different domain, put a URL
		policy file on the server that is hosting the data. For more information,
		see the description of the URLRequest class.
		For content running in Adobe AIR, files in the application security
		sandbox  -  files installed with the AIR application  -  can access URLs
		using any of the following URL schemes:
		* `http` and `https`
		* `file`
		* `app-storage`
		* `app`
		**Note:** IPv6(Internet Protocol version 6) is supported in AIR and
		in Flash Player 9.0.115.0 and later. IPv6 is a version of Internet
		Protocol that supports 128-bit addresses(an improvement on the earlier
		IPv4 protocol that supports 32-bit addresses). You might need to activate
		IPv6 on your networking interfaces. For more information, see the Help for
		the operating system hosting the data. If IPv6 is supported on the hosting
		system, you can specify numeric IPv6 literal addresses in URLs enclosed in
		brackets([]), as in the following.
		`rtmp://[2001:db8:ccc3:ffff:0:444d:555e:666f]:1935/test`
	**/
	public var url:String;

	/**
		Specifies the user-agent string to be used in the HTTP request.
		The default value is the same user agent string that is used by OpenFL on native
		targets, by the web browser or by Flash Player (depending upon the target).
		**Note:** This property does not affect the user agent string when the
		URLRequest object is used with the `load()` method of an HTMLLoader object. To set
		the user agent string for an HTMLLoader object, set the `userAgent` property of the
		HTMLLoader object or set the static `URLRequestDefaults.userAgent` property.
	**/
	public var userAgent:String;

	/**
		Creates a URLRequest object. If `System.useCodePage` is
		`true`, the request is encoded using the system code page,
		rather than Unicode. If `System.useCodePage` is
		`false`, the request is encoded using Unicode, rather than the
		system code page.
		@param url The URL to be requested. You can set the URL later by using the
				   `url` property.
	**/
	public function new(url:String = null) {
		if (url != null) {
			this.url = url;
		}

		contentType = null;
		followRedirects = URLRequestDefaults.followRedirects;

		if (URLRequestDefaults.idleTimeout > 0) {
			idleTimeout = URLRequestDefaults.idleTimeout;
		} else {
			idleTimeout = 30000;
		}

		manageCookies = URLRequestDefaults.manageCookies;
		method = URLRequestMethod.GET;
		requestHeaders = [];
		userAgent = URLRequestDefaults.userAgent;
	}
}
