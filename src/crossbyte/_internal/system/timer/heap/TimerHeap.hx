package crossbyte._internal.system.timer.heap;

import crossbyte.ds.PriorityQueue;
import haxe.Timer as HxTimer;

class TimerHeap implements ITimerScheduler {
	#if precision_tick
	private static inline var EPS:Float = 1e-9;
	#end

	private static inline function comparatorFunc(a:TimerNode, b:TimerNode):Int {
		return a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);
	}

	public var size(get, never):Int;
	public var isEmpty(get, never):Bool;
	public var time(get, never):Float;
	public final startTime:Float = HxTimer.stamp();

	private final queue:PriorityQueue<TimerNode> = new PriorityQueue(comparatorFunc);
	private var nodes:Array<TimerNode> = [];
	private var gens:Array<Int> = [];
	private var free:Array<Int> = [];

	private var __now:Float = 0.0;

	private inline function get_size():Int {
		return queue.size;
	}

	private inline function get_isEmpty():Bool {
		return queue.isEmpty;
	}

	public inline function get_time():Float {
		return __now;
	}

	public function new() {}

	public inline function setTimeout(delay:Float, callback:TimerHandle->Void):TimerHandle {
		return createTimer(__now + delay, 0, callback);
	}

	public inline function setTimeoutVoid(delay:Float, callback:Void->Void):TimerHandle {
		return createTimer(__now + delay, 0, (handle:Int) -> callback());
	}

	public inline function setInterval(delay:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return createTimer(__now + delay, interval, callback);
	}

	public inline function setIntervalVoid(delay:Float, interval:Float, callback:Void->Void):TimerHandle {
		#if debug
		if (interval <= 0) {
			throw "interval must be > 0";
		}
		#end
		return createTimer(__now + delay, interval, (handle:TimerHandle) -> callback());
	}

	public function clear(handle:TimerHandle, immediate:Bool = false):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		if (immediate) {
			queue.remove(node);
			freeSlot(node.id);
		} else {
			node.enabled = false;
		}
		return true;
	}

	public inline function isActive(handle:TimerHandle):Bool {
		return isLive(handle);
	}

	public inline function schedule(time:Float, callback:TimerHandle->Void):TimerHandle {
		final delay:Float = time - this.time;
		return this.setTimeout(delay, callback);
	}

	public inline function scheduleVoid(time:Float, callback:Void->Void):TimerHandle {
		final delay:Float = time - this.time;
		return this.setTimeoutVoid(delay, callback);
	}

	public function reschedule(handle:TimerHandle, time:Float):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		node.time = time;
		queue.update(node);
		return true;
	}

	public function delay(handle:TimerHandle, dt:Float):Bool {
		if (!isLive(handle)) {
			return false;
		}

		if (dt < 0) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		node.time += dt;
		queue.update(node);
		return true;
	}

	public function setEnabled(handle:TimerHandle, enabled:Bool, policy:ResumePolicy = KeepPhase, time:Float = 0.0):Bool {
		if (!isLive(handle)) {
			return false;
		}

		var node:TimerNode = nodes[handle.id()];
		if (node.enabled == enabled) {
			return true;
		}

		var t:Float = (time != 0.0) ? time : __now;

		if (!enabled) {
			node.enabled = false;
			node.pausedAt = t;
			queue.remove(node);
			return true;
		}

		node.enabled = true;
		switch (policy) {
			case KeepPhase:
				if (node.pausedAt != 0.0) {
					var pausedDur = t - node.pausedAt;
					if (pausedDur != 0.0) {
						node.time += pausedDur;
					}

					node.pausedAt = 0.0;
				}
			case FromNow:
				node.time = (node.interval > 0) ? (t + node.interval) : t;
				node.pausedAt = 0.0;
		}
		queue.update(node);
		return true;
	}

	public inline function nextDue():Null<Float> {
		var t:TimerNode = queue.peek();
		return (t != null) ? t.time : null;
	}

	public inline function advanceTime(dt:Float, maxFires:Int = 256):Int {
		__now += dt;
		var fired:Int = 0;

		if (!isEmpty) {
			var top:TimerNode = queue.peek();

			while (top != null && top.enabled && top.time <= __now #if precision_tick + EPS #end && fired < maxFires) {
				queue.dequeue();
				var node:TimerNode = top;

				if (!node.enabled) {
					freeSlot(node.id);
				} else {
					var gen:Int = gens[node.id];

					#if timer_burst_catchup
					if (node.interval > 0) {
						var steps:Int = Std.int(Math.floor((_now - node.time) / node.interval)) + 1;
						if (steps < 1) {
							steps = 1;
						}

						var budget:Int = maxFires - fired;
						var fires:Int = (steps <= budget) ? steps : budget;

						var i:Int = 0;
						while (i < fires && node.enabled) {
							node.callback(new TimerHandle(node.id, gen));
							i++;
							fired++;
						}

						if (node.enabled) {
							node.time += fires * node.interval;
							queue.enqueue(node);
						} else {
							freeSlot(node.id);
						}
					} else {
						node.callback(new TimerHandle(node.id, gen));
						fired++;
						freeSlot(node.id);
					}
					#else
					node.callback(new TimerHandle(node.id, gen));
					fired++;

					if (node.enabled && node.interval > 0) {
						node.time += node.interval;
						queue.enqueue(node);
					} else {
						freeSlot(node.id);
					}
					#end
				}

				top = queue.peek();
			}
		}
		return fired;
	}

	private inline function createTimer(absoluteTime:Float, interval:Float, callback:TimerHandle->Void):TimerHandle {
		var id:Int;
		if (free.length > 0) {
			id = free.shift();
		} else {
			id = nodes.length;
			nodes.push(null);
			gens.push(0);
		}
		var n:TimerNode = new TimerNode(id, absoluteTime, interval, callback);
		nodes[id] = n;
		queue.enqueue(n);
		return new TimerHandle(id, gens[id]);
	}

	private inline function freeSlot(id:Int):Void {
		nodes[id] = null;
		gens[id] = (gens[id] + 1) & TimerHandle.GEN_MASK;
		free.push(id);
	}

	private inline function isLive(handle:TimerHandle):Bool {
		var id:Int = handle.id();
		return id >= 0 && id < nodes.length && nodes[id] != null && gens[id] == handle.gen();
	}
}
