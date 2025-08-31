package crossbyte.utils;

import haxe.ds.ObjectMap;
import sys.thread.Deque;

/**
 * ...
 * @author Christopher Speciale
 */
abstract ObjectRecycler<T>(Deque<T>) {
	public inline function new() {
		this = new Deque();
	}

	public inline function get():T {
		var object:T = this.pop(false);

		return object;
	}

	public inline function recycle(obj:T):Void {
		this.add(obj);
	}

	public inline function empty():Void {
		this = new Deque();
	}
}
