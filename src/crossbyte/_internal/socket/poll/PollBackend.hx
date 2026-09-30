package crossbyte._internal.socket.poll;

// Not built for the browser: it polls OS socket descriptors, which a page does not have. The browser socket is driven by the runtime tick instead.
#if !(js && !nodejs)

import sys.net.Socket;

interface PollBackend {
	public var capacity(get, never):Int;
	public var readIndexes(default, null):Array<Int>;
	public var writeIndexes(default, null):Array<Int>;
	public function prepare(read:Array<Socket>, write:Array<Socket>):Void;
	public function events(timeout:Float):Void;
	public function dispose():Void;

	/**
		`socket` is no longer watched, and is about to be closed: called at
		once, while it is still open, rather than left to the next `prepare`.

		A backend that snapshots the set at each `prepare` -- the built-in
		one -- has nothing to do here. One that registers each descriptor
		with the system for as long as it is watched, as libuv's `uv_poll_t`
		does, must let go of it now: libuv forbids closing a descriptor with a
		poll handle still active on it, and if the file outlives the close --
		a child process inherited it -- its registration survives, and the
		loop wakes for it for good. The registry also skips `prepare` once
		its set is empty, so without this a backend never hears that the last
		socket left.
	**/
	public function remove(socket:Socket):Void;
}

/**
	A backend that can take more sockets without being rebuilt. Optional:
	the registry otherwise makes a larger backend and disposes of this one,
	which for a backend holding a watcher per descriptor means rebuilding
	every one of them.
**/
interface PollBackendGrowable {
	/** Makes room for `capacity` sockets; false when it cannot. **/
	public function grow(capacity:Int):Bool;
}
#end
