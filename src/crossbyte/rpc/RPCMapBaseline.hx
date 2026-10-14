package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.errors.RangeError;
import crossbyte.rpc._internal.RPCKeys;
import haxe.ds.IntMap;

/**
	What one observer holds of a keyed map, as the patches sent to it made
	it: the keys it holds, and for each whose update a budget deferred, the
	older value it still has. `RPCMapPatch.diffKeysWithin` diffs against the
	baseline an observer acknowledged and writes the one it sends, so what a
	server keeps for an observer is what it sent, never the view it meant to
	send: an entry left out is still owed, and goes in a later patch.

	The rest of what the observer holds is read from the frame of values the
	baseline was made against (the `currentValues` of the diff that wrote
	it), so baselines are kept beside frames, as Quake 3 keeps a client's
	snapshots beside the world's: a ring of baselines per observer, and a
	ring of frames shared by every observer, at least as long. A stale value
	is a copy the baseline owns, kept for reuse, so a deferred entry stays
	right however long it waits and however the frames are reused.

	```haxe
	import crossbyte.ds.SequenceRing;
	import crossbyte.rpc.RPCMapBaseline;

	class ViewedShip implements RPCStruct {
		public var x:Float32 = 0;
		public var y:Float32 = 0;

		public function new() {}
	}

	class Observer {
		// What it was sent, by tick: a baseline per tick, reused as the ring turns.
		public final sent = new SequenceRing<RPCMapBaseline<ViewedShip>>(32);
		public var acked:Int = 0;

		public function new() {}
	}
	```

	```haxe
	// Given observer:Observer, tick:Int.
	final base:Null<RPCMapBaseline<ViewedShip>> = observer.sent.get(observer.acked);
	final kept:Null<RPCMapBaseline<ViewedShip>> = observer.sent.get(tick - observer.sent.capacity);
	final slot:RPCMapBaseline<ViewedShip> = kept != null ? kept : new RPCMapBaseline();
	```

	Only a budgeted diff writes one. One baseline is one observer's at one
	tick: two observers never share one.

	**Threading.** None.
**/
@:access(crossbyte.ds.IdList)
final class RPCMapBaseline<V> {
	/** How many keys the observer holds. **/
	public var length(get, never):Int;

	/** How many of them hold a value older than their frame's, their last update deferred. **/
	public var staleCount(get, never):Int;

	@:noCompletion public final __keys:IdList = new IdList();
	@:noCompletion public final __staleKeys:IdList = new IdList();
	@:noCompletion public final __staleValues:Array<V> = [];
	// Values the baseline made and no longer holds, for the next stale ones.
	@:noCompletion public final __spare:Array<V> = [];
	@:noCompletion public var __spareCount:Int = 0;
	// The values it was made against: a diff against it must be given them.
	@:noCompletion public var __frame:Null<IntMap<V>> = null;

	public function new() {}

	/**
		The `index`-th key the observer holds, ascending.

		@throws RangeError If `index` is not below `length`.
	**/
	public function keyAt(index:Int):Int {
		return __keys.get(index);
	}

	/** Whether the observer holds `key`. **/
	public function has(key:Int):Bool {
		return RPCKeys.indexOf(__keys, key) >= 0;
	}

	/** Whether the observer holds `key` at a value older than the frame's: its update was deferred. **/
	public function isStale(key:Int):Bool {
		return RPCKeys.indexOf(__staleKeys, key) >= 0;
	}

	/**
		The value the observer holds under `key`: its stale value, or
		`frame`'s, the frame of values the baseline was made against; `null`
		when it holds none. A stale value is the baseline's own: copy what is
		kept.

		@throws ArgumentError When `frame` is not the one it was made against.
	**/
	public function valueIn(key:Int, frame:IntMap<V>):Null<V> {
		if (frame != __frame) {
			throw new crossbyte.errors.ArgumentError("This baseline was made against another frame of values: give the frame of the tick it was sent at.");
		}
		if (RPCKeys.indexOf(__keys, key) < 0) {
			return null;
		}
		final stale:Int = RPCKeys.indexOf(__staleKeys, key);
		return stale >= 0 ? __staleValues[stale] : frame.get(key);
	}

	/** Takes a value the baseline no longer holds, or makes one. **/
	@:noCompletion public inline function __take(codec:RPCCodec<V>):V {
		if (__spareCount > 0) {
			__spareCount--;
			final value:V = __spare[__spareCount];
			__spare[__spareCount] = null;
			return value;
		}
		return codec.make();
	}

	/** Keeps `value`, which the baseline no longer holds, for a later stale one. **/
	@:noCompletion public inline function __keep(value:V):Void {
		if (__spareCount < __spare.length) {
			__spare[__spareCount] = value;
		} else {
			__spare.push(value);
		}
		__spareCount++;
	}

	private inline function get_length():Int {
		return __keys.length;
	}

	private inline function get_staleCount():Int {
		return __staleKeys.length;
	}
}
