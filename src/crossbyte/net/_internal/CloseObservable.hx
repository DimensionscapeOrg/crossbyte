package crossbyte.net._internal;

import crossbyte.net.Reason;

/**
	A connection that tells one observer when it can carry nothing more --
	it closed, or a transport error stopped its reads -- before its own
	`onClose` or `onError` runs, whoever set that and whenever they did.

	`RPCSession` is the observer: it fails the calls still waiting on an
	answer, which otherwise waited for good once their connection went. It
	cannot use `onClose` for that. That is the application's one callback,
	and set after the session was made it would replace the session's.

	The transports CrossByte ships implement it. A `NetConnection` wrapping
	some other `INetConnection` falls back to wrapping that connection's
	`onClose`, which is all such a connection offers.

	Told on the thread the connection's callbacks run on. Costs a connection
	one field and a check as it ends; nothing on the way data goes.
**/
interface CloseObservable {
	/** Sets the one observer, replacing any before it; `null` removes it. **/
	@:noCompletion function __observeClose(observer:Null<Reason->Void>):Void;
}
