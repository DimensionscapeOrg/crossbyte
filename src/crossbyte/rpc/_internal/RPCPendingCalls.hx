package crossbyte.rpc._internal;

import crossbyte.rpc.RPCResponse;
import haxe.ds.IntMap;
import haxe.ds.Vector;

/**
	The calls waiting on their answers, found by request id: the ones past
	the first, which its commands or session hold in a field of its own.

	A caller numbers its calls one after another, so a call's place is its
	id modulo the ring's length, and calls in flight together have places
	of their own: nothing is hashed, and nothing is made for a call, where an
	`IntMap` would make a node for each on hxcpp.

	The ring doubles, up to `MAX` places, when a call finds its place taken
	while at least half of them are; otherwise the call there (still
	waiting a ring's length of calls after it was made, a slow one behind
	many answered) moves to a map of its own.
	A ring that grew keeps its size.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCResponse)
final class RPCPendingCalls {
	static inline final INITIAL:Int = 16;
	static inline final MAX:Int = 1024;

	var __ids:Vector<Int>;
	var __calls:Vector<RPCResponse<Dynamic>>;
	var __held:Int = 0;
	var __overflow:Null<IntMap<RPCResponse<Dynamic>>> = null;
	var __overflowCount:Int = 0;

	/** How many calls are held. **/
	public var count(get, never):Int;

	public function new() {
		__ids = new Vector(INITIAL);
		__calls = new Vector(INITIAL);
	}

	inline function get_count():Int {
		return __held + __overflowCount;
	}

	/** Holds `response` under `id`, which nothing held has. **/
	public function put(id:Int, response:RPCResponse<Dynamic>):Void {
		var at:Int = id & (__calls.length - 1);
		var there:Null<RPCResponse<Dynamic>> = __calls[at];
		if (there != null) {
			if (__held * 2 >= __calls.length && __calls.length < MAX) {
				__grow();
				at = id & (__calls.length - 1);
				there = __calls[at];
			}
			if (there != null) {
				__moveOut(__ids[at], there);
				__held--;
			}
		}
		__ids[at] = id;
		__calls[at] = response;
		__held++;
	}

	/** The call held under `id`, no longer held; `null` if there is none. **/
	public function take(id:Int):Null<RPCResponse<Dynamic>> {
		final at:Int = id & (__calls.length - 1);
		final there:Null<RPCResponse<Dynamic>> = __calls[at];
		if (there != null && __ids[at] == id) {
			__calls[at] = null;
			__held--;
			return there;
		}
		if (__overflowCount > 0) {
			final response:Null<RPCResponse<Dynamic>> = __overflow.get(id);
			if (response != null) {
				__overflow.remove(id);
				__overflowCount--;
				return response;
			}
		}
		return null;
	}

	/** Whether a call is held under `id`. **/
	public function has(id:Int):Bool {
		final at:Int = id & (__calls.length - 1);
		if (__calls[at] != null && __ids[at] == id) {
			return true;
		}
		return __overflowCount > 0 && __overflow.exists(id);
	}

	/**
		Fails every call held, in no particular order. Its
		owner lets go of it first: failing a call runs its handlers, which
		may make more.
	**/
	public function failAll(message:String, cause:Null<Dynamic>):Void {
		final overflow = __overflow;
		__overflow = null;
		__overflowCount = 0;
		__held = 0;
		for (at in 0...__calls.length) {
			final response = __calls[at];
			if (response != null) {
				__calls[at] = null;
				response.__fail(message, cause);
			}
		}
		if (overflow != null) {
			for (response in overflow) {
				response.__fail(message, cause);
			}
		}
	}

	function __moveOut(id:Int, response:RPCResponse<Dynamic>):Void {
		if (__overflow == null) {
			__overflow = new IntMap();
		}
		__overflow.set(id, response);
		__overflowCount++;
	}

	function __grow():Void {
		final ids = __ids;
		final calls = __calls;
		final capacity:Int = calls.length * 2;
		__ids = new Vector(capacity);
		__calls = new Vector(capacity);
		__held = 0;
		for (from in 0...calls.length) {
			final response = calls[from];
			if (response == null) {
				continue;
			}
			final id:Int = ids[from];
			final at:Int = id & (capacity - 1);
			if (__calls[at] != null) {
				__moveOut(id, response);
				continue;
			}
			__ids[at] = id;
			__calls[at] = response;
			__held++;
		}
	}
}
