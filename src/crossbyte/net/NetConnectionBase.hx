package crossbyte.net;

import crossbyte.io.ByteArray;
import crossbyte.net._internal.CloseObservable;

/** Shared base storage for concrete `NetConnection` transport adapters. */
abstract class NetConnectionBase implements CloseObservable {
	/**
		A slot for whatever the application wants this connection to carry.

		Untouched by the framework, and it goes when the connection does.
		Without one, an application holding per-connection state, a session,
		a player, a room membership, keeps a `Map` beside the connection and
		has to remember to remove the entry on close. Forgetting is not
		noisy: the connection is gone, the traffic stops, and the entry stays
		until the process does.

		Typed as `Any` rather than `Dynamic` so reading it back needs an
		explicit cast, and a wrong one is a compile error rather than a field
		access on whatever happened to be there.

		```haxe
		connection.userData = new Session(player);
		var session:Session = cast connection.userData;
		```
	**/
	public var userData:Any = null;

	/** Transport protocol implemented by the concrete adapter. */
	public var protocol:Protocol;
	/** Timestamp of the most recent inbound payload, in uptime seconds. */
	public var inTimestamp:Float = 0.0;
	/** Timestamp of the most recent outbound payload, in uptime seconds. */
	public var outTimestamp:Float = 0.0;

	// Told as the connection ends, and as it becomes ready, before the
	// application's callbacks; see CloseObservable.
	@:noCompletion private var __closeObserver:Null<Reason->Void> = null;
	@:noCompletion private var __readyObserver:Null<Void->Void> = null;

	@:noCompletion public function __observeClose(observer:Null<Reason->Void>):Void {
		__closeObserver = observer;
	}

	@:noCompletion public function __observeReady(observer:Null<Void->Void>):Void {
		__readyObserver = observer;
	}

	/** Called by each transport wherever it ends: before `onClose`, and before an `onError` that stopped its reads. **/
	@:noCompletion private inline function __notifyClose(reason:Reason):Void {
		final observer = __closeObserver;
		if (observer != null) {
			observer(reason);
		}
	}

	/** Called by each transport as it becomes ready, before `onReady`. **/
	@:noCompletion private inline function __notifyReady():Void {
		final observer = __readyObserver;
		if (observer != null) {
			observer();
		}
	}

	/** Exposes the concrete transport wrapper. */
	public abstract function expose():Transport;
	/** Sends a payload over the transport. */
	public abstract function send(data:ByteArray):Void;
	/** Closes the transport. */
	public abstract function close():Void;
}
