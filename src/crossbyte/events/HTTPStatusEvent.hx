package crossbyte.events;

import crossbyte.url.URLRequestHeader;

/** Event dispatched when an HTTP request or response reports a status code. */
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

		From a server's `HTTPRequestHandler`, every field the response was
		given, less the framing the protocol writes itself:
		`Content-Length`, `Transfer-Encoding` and `Connection`. It used to be
		only the fields a caller had added.
	**/
	public var responseHeaders:Array<URLRequestHeader>;

	/**
		The URL that the response was returned from. In the case of redirects,
		this will be different from the request URL.

		From a server's `HTTPRequestHandler`, the path and query the response
		answers, as `requestPath` and `queryString` read: `/index.html?x=1`.
		It used to be the client's address, which is `remoteAddress`.
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
		event.responseHeaders = responseHeaders;
		event.responseURL = responseURL;
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}

	public override function toString():String {
		return '[HTTPStatusEvent], type:$type, status:$status, redirected:$redirected';
	}
}
