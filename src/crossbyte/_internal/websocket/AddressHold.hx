package crossbyte._internal.websocket;

/**
	One open connection counted under its address for a server's
	`maxConnectionsPerAddress`: carried by the connection (its handshake
	first, then its socket) and let go of once, however it ends.

	Only the thread holding the connection lets go of it, so `held` needs no
	lock; the counts it names take their own.
**/
@:noCompletion
final class AddressHold {
	private final __counts:AddressCounts;
	private final __key:String;
	private var __held:Bool = true;

	public function new(counts:AddressCounts, key:String) {
		__counts = counts;
		__key = key;
	}

	/** The connection has ended: its address counts it no more. A second call does nothing. **/
	public function release():Void {
		if (!__held) {
			return;
		}
		__held = false;
		__counts.release(__key);
	}
}
