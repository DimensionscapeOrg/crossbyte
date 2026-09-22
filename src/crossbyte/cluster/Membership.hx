package crossbyte.cluster;

import crossbyte.errors.ArgumentError;

/**
	Which nodes are alive, from how recently each was heard from.

	Knows nothing about how a heartbeat arrives -- a datagram, a `NetHost`
	broadcast, a row in a table someone else writes. Tell it what was heard
	and when, sweep it on the tick, and it says who is there and reports the
	changes. That is deliberately all it does: who should be sent what is a
	policy written against this, and `Rendezvous` is where it usually goes.

	```haxe
	var alive = new Membership(5.0);
	alive.onJoin = node -> ring.add(node);
	alive.onLeave = node -> ring.remove(node);

	alive.heard(nodeName);   // whenever a heartbeat arrives
	alive.sweep();           // from the tick
	```

	## On the timeout

	A node declared gone that was only slow is expensive: its keys move,
	whatever held them is rebuilt elsewhere, and it all moves back when the
	node reappears. Set the timeout at several times the heartbeat interval
	rather than close to it.

	This decides on one number, which is the simple thing rather than the
	clever one. An implementation that watched how regular a node's
	heartbeats had been could suspect a node that went quiet early and give a
	reliably-jittery one more room, and `lastHeardFrom` is exposed so that
	can be built on top without this having an opinion about it.
**/
class Membership {
	/** How long a node may go unheard before it is considered gone. **/
	public var timeout(default, null):Float;

	/**
		The most nodes tracked at once.

		A name arrives from outside and nothing here can tell a real node
		from an invented one, so a peer that makes them up would otherwise
		grow this without limit. Past the bound a name that is not already
		known is refused rather than admitted.
	**/
	public var maxNodes(default, null):Int;

	/** How many nodes are currently alive. **/
	public var length(default, null):Int = 0;

	/** Called when a node is heard from that was not alive a moment ago. **/
	public dynamic function onJoin(node:String):Void {}

	/** Called when a node has gone unheard for longer than `timeout`. **/
	public dynamic function onLeave(node:String):Void {}

	private var __lastHeard:Map<String, Float>;
	private var __clock:Void->Float;

	/**
		@param timeout Seconds a node may go unheard before it is gone.
		@param maxNodes The most to track; zero for no limit, which is only
		       safe when the names come from somewhere trusted.
		@param clock Where the time comes from. Supply one in a test.
	**/
	public function new(timeout:Float, maxNodes:Int = 1024, ?clock:Void->Float) {
		if (timeout <= 0) {
			throw new ArgumentError("A membership needs a positive timeout.");
		}

		this.timeout = timeout;
		this.maxNodes = maxNodes < 0 ? 0 : maxNodes;
		this.__clock = clock == null ? function():Float return haxe.Timer.stamp() : clock;
		this.__lastHeard = new Map();
	}

	/**
		Records that a node was heard from.

		@return Whether this is the first time it has been heard from since
		        it was last alive -- which is when `onJoin` fires. Returns
		        false for a name refused by `maxNodes`.
	**/
	public function heard(node:String, ?now:Float):Bool {
		if (node == null || node == "") {
			throw new ArgumentError("A node needs a name.");
		}

		var at:Float = now == null ? __clock() : now;
		var known:Bool = __lastHeard.exists(node);

		if (!known && maxNodes > 0 && length >= maxNodes) {
			return false;
		}

		__lastHeard.set(node, at);

		if (known) {
			return false;
		}

		length++;
		onJoin(node);
		return true;
	}

	/**
		Drops whatever has gone unheard for longer than `timeout`.

		@return How many left.
	**/
	public function sweep(?now:Float):Int {
		var at:Float = now == null ? __clock() : now;
		var gone:Array<String> = null;

		for (node in __lastHeard.keys()) {
			if (at - __lastHeard.get(node) >= timeout) {
				if (gone == null) {
					gone = [];
				}

				gone.push(node);
			}
		}

		if (gone == null) {
			return 0;
		}

		for (node in gone) {
			__lastHeard.remove(node);
			length--;
			onLeave(node);
		}

		return gone.length;
	}

	/** Whether a node is currently alive. **/
	public function has(node:String):Bool {
		return __lastHeard.exists(node);
	}

	/**
		When a node was last heard from, or -1 for one that is not alive.

		For anything wanting to decide about a node before `timeout` does --
		how long it has been quiet is the measurement that decision is made
		from.
	**/
	public function lastHeardFrom(node:String):Float {
		return __lastHeard.exists(node) ? __lastHeard.get(node) : -1;
	}

	/** Everyone currently alive, in no particular order. **/
	public function alive():Array<String> {
		var out:Array<String> = [];

		for (node in __lastHeard.keys()) {
			out.push(node);
		}

		return out;
	}

	/** Drops a node now, without waiting for it to time out. **/
	public function forget(node:String):Bool {
		if (!__lastHeard.exists(node)) {
			return false;
		}

		__lastHeard.remove(node);
		length--;
		onLeave(node);
		return true;
	}

	/** Drops everyone, without reporting any of them as leaving. **/
	public function clear():Void {
		__lastHeard = new Map();
		length = 0;
	}
}
