package crossbyte.url;

/**
 * ...
 * @author Christopher Speciale
 */
class URLRequestDefaults {
	/**
		The default setting for the `followRedirects` property of URLRequest objects.
		Setting the `followRedirects` property in a URLRequest object overrides this
		default setting. This setting does not apply to URLRequest objects used in file
		upload or RTMP requests.
		The default value is `true`.
	**/
	public static var followRedirects:Bool = true;

	/**
		The default setting for the `idleTimeout` property of URLRequest objects and
		HTMLLoader objects.
		The idle timeout is the amount of time (in milliseconds) that the client waits for
		a response from the server, after the connection is established, before abandoning
		the request.
		This defines the default idle timeout used by the URLRequest or HTMLLoader object.
		Setting the `idleTimeout` property in a URLRequest object or an HTMLLoader object
		overrides this default setting.
		When this property is set to 0 (the default), the runtime uses the default idle
		timeout value defined by the operating system. The default idle timeout value
		varies between operating systems (such as Mac OS, Linux, or Windows) and between
		operating system versions.
		This setting does not apply to URLRequest objects used in file upload or RTMP
		requests.
		The default value is 0.
	**/
	public static var idleTimeout:Float = 0;

	/**
		The default setting for the manageCookies property of URLRequest objects. Setting
		the manageCookies property in a URLRequest object overrides this default setting.
		**Note:** This setting does not apply to URLRequest objects used in file upload
		or RTMP requests.
		The default value is `true`.
	**/
	public static var manageCookies:Bool = true;

	/**
		The default setting for the `userAgent` property of URLRequest objects. Setting the
		`userAgent` property in a URLRequest object overrides this default setting.
	**/
	public static var userAgent:String;
}
