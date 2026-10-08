package crossbyte.net;

/**
	Why a TURN relay would not relay, or stopped: what a failed
	`TurnClient.allocated` carries as its `cause`, and `TurnClient.failure`
	once an allocation has gone.

	A failure carries its code as well as a sentence, so an application
	deciding what to do next (try another relay, fetch new credentials,
	give up) need not match on the wording. The decision turns on the code:
	486 and 508 are this relay being full, a good reason to try another; 401
	is the credentials; 300 names where to go instead.
**/
class TurnError {
	/**
		The relay's STUN error code, such as 300, 401, 437, 486 or 508, or 0
		when it gave none: it never answered, none of its answers could be
		believed, or the connection to it ended.
	**/
	public var code(default, null):Int;

	/** The relay's reason phrase, or what went wrong in words when it gave none. **/
	public var reason(default, null):String;

	/** The relay this is about, as "address:port". **/
	public var server(default, null):String;

	/**
		Where a 300 Try Alternate pointed, when that is why: a redirection this
		client did not follow because it had already been sent there.
	**/
	public var alternate(default, null):Null<ReflexiveAddress>;

	public function new(code:Int, reason:String, server:String, ?alternate:ReflexiveAddress) {
		this.code = code;
		this.reason = reason;
		this.server = server;
		this.alternate = alternate;
	}

	public function toString():String {
		return (code > 0 ? code + " " : "") + reason + " (" + server + (alternate != null ? ", redirected to " + alternate : "") + ")";
	}
}
