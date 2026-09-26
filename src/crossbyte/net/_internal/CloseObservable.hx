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

	It is told, the same way, when the connection becomes ready: a
	heartbeat started before the connection was up starts then, and a
	connection that takes another peer -- a `LocalConnection` listening
	again -- is ready to answer again.

	The transports CrossByte ships implement it. A `NetConnection` wrapping
	some other `INetConnection` falls back to wrapping that connection's
	`onClose` and `onReady`, which is all such a connection offers.

	Told on the thread the connection's callbacks run on. Costs a connection
	a field and a check as it ends or becomes ready; nothing on the way data
	goes.
**/
interface CloseObservable {
	/** Sets the one observer, replacing any before it; `null` removes it. **/
	@:noCompletion function __observeClose(observer:Null<Reason->Void>):Void;

	/** Sets the one observer of the connection becoming ready, before its `onReady`; `null` removes it. **/
	@:noCompletion function __observeReady(observer:Null<Void->Void>):Void;
}
