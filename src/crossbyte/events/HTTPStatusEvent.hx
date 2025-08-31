package crossbyte.events;

import crossbyte.url.URLRequestHeader;

/**
 * ...
 * @author Christopher Speciale
 */
class HTTPStatusEvent extends Event {
	public static inline var HTTP_RESPONSE_STATUS:EventType<HTTPStatusEvent> = "httpResponseStatus";

	public static inline var HTTP_STATUS:EventType<HTTPStatusEvent> = "httpStatus";

	/**
		Indicates whether the request was redirected.
	**/
	public var redirected:Bool;

	/**
		The response headers that the response returned, as an array of
		URLRequestHeader objects.
	**/
	public var responseHeaders:Array<URLRequestHeader>;

	/**
		The URL that the response was returned from. In the case of redirects,
		this will be different from the request URL.
	**/
	public var responseURL:String;

	/**
		The HTTP status code returned by the server.
	**/
	public var status(default, null):Int;

	public function new(type:String, status:Int = 0, redirected:Bool = false):Void {
		this.status = status;
		this.redirected = redirected;

		super(type);
	}

	public override function clone():HTTPStatusEvent {
		var event = new HTTPStatusEvent(type, status, redirected);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	public override function toString():String {
		return '[HTTPStatusEvent], type:$type, status:$status, redirected:$redirected';
	}
}
