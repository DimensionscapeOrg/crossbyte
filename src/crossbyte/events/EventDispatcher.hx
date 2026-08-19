package crossbyte.events;

import haxe.ds.StringMap;
import crossbyte.Function;

 /**
 * A basic event dispatcher that implements `IEventDispatcher` for managing listeners and dispatching events.
 *
 * `EventDispatcher` provides a lightweight system for registering typed event listeners, dispatching
 * events, and optionally proxying `target` references via delegation. It supports priority-ordered
 * listener insertion, automatic event target resolution, and listener snapshotting during dispatch.
 *
 * ## Features
 * - Generic `EventType<T>` support for strongly-typed listener registration.
 * - Priority-based listener ordering with deterministic dispatch behavior.
 * - Automatic `target` and `currentTarget` assignment during `dispatchEvent()`.
 * - Safe listener snapshotting to avoid issues when mutating listeners during dispatch.
 * - Optional delegation model (via `target:IEventDispatcher`) for composed event targets.
 *
 * ## Usage Example
 * ```haxe
 * final dispatcher = new EventDispatcher();
 * dispatcher.addEventListener(MyEvent.TYPE, function(e:MyEvent) {
 *     trace('Handled: ' + e.data);
 * });
 * dispatcher.dispatchEvent(new MyEvent(MyEvent.TYPE, "Hello"));
 * ```
 *
 * ## Target Delegation
 * If a dispatcher is constructed with a non-null `target:IEventDispatcher`, then any event dispatched
 * through it will have its `event.target` set to that instance (unless explicitly pre-set on the event).
 * This enables `EventDispatcher` to act as an internal helper for classes that expose their own event target.
 *
 * @see EventType
 * @see Event
 * @see IEventDispatcher
 */
@:access(crossbyte.events.Event)
class EventDispatcher implements IEventDispatcher {
	@:noCompletion private var __eventMap:Null<StringMap<Array<ListenerEntry>>>;
	@:noCompletion private var __targetDispatcher:IEventDispatcher;
	@:noCompletion private var __nextListenerOrder:Int;

	/**
	 * Creates a new `EventDispatcher`, optionally bound to a target dispatcher.
	 *
	 * This class provides basic event listener management and event propagation.
	 * It can be used standalone or as a delegate to another dispatcher.
	 *
	 * @param target Optional `IEventDispatcher` that acts as the `target` of events dispatched from this instance.
	 */
	public function new(target:IEventDispatcher = null) {
		__targetDispatcher = target;
		__eventMap = null;
		__nextListenerOrder = 0;
	}

	/**
	 * Adds an event listener for the specified event `type`.
	 *
	 * Listeners are stored in an ordered list and invoked in order of their priority.
	 * Lower priority values are inserted earlier (i.e. called later).
	 * 
	 * If `priority` is out of bounds, it will be clamped to `[0, listeners.length]`.
	 * 
	 * @param type The `EventType<T>` representing the string type of the event (e.g. `EventType.create<T>("my_event")`)
	 * @param listener A callback of type `T -> Void` to be invoked when the event is dispatched.
	 * @param priority Optional insertion index for ordering. Defaults to `0` (append).
	 * @throws String If `listener` is null.
	 *
	 * @example
	 * ```haxe
	 * dispatcher.addEventListener(MyEvent.TYPE, function(e:MyEvent) {
	 *     trace('Got event: ' + e.data);
	 * });
	 * ```
	 */
	public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		if (listener == null) {
			throw "listener must not be null";
		}

		var entry:ListenerEntry = {
			listener: cast listener,
			priority: priority,
			order: __nextListenerOrder++
		};

		var eventMap = __eventMap;
		if (eventMap == null) {
			eventMap = new StringMap();
			__eventMap = eventMap;
		}

		var list:Null<Array<ListenerEntry>> = eventMap.get(type);
		if (list == null) {
			eventMap.set(type, [entry]);
			return;
		}

		var idx = list.length;
		for (i in 0...list.length) {
			var current = list[i];
			if (priority > current.priority) {
				idx = i;
				break;
			}
		}

		// Replaced rather than inserted into. Dispatch holds whichever array
		// was current when it began and walks it without copying, so the list
		// it is walking must never change underneath it. Paying for a copy
		// here — where listeners are registered, typically once — instead of
		// there, where events are dispatched forever, is the whole trade.
		var next:Array<ListenerEntry> = list.copy();
		next.insert(idx, entry);
		eventMap.set(type, next);
	}

	/**
	 * Removes a previously registered event listener for the given `type`.
	 *
	 * If the listener does not exist or has already been removed, this is a no-op.
	 *
	 * @param type The `EventType<T>` to remove the listener from.
	 * @param listener The callback to remove. Must match the original reference.
	 */
	public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		if (listener == null) {
			return;
		}

		var eventMap = __eventMap;
		if (eventMap == null) {
			return;
		}

		var list:Null<Array<ListenerEntry>> = eventMap.get(type);
		if (list == null) {
			return;
		}

		for (i in 0...list.length) {
			if (list[i].listener == cast listener) {
				if (list.length == 1) {
					__eventMap.remove(type);
					return;
				}

				// Replaced rather than spliced, for the reason given in
				// addEventListener: a dispatch already walking this list keeps
				// the array it started with, so a listener removed from inside
				// a handler still runs for the event in flight — which is the
				// behaviour the per-dispatch copy used to provide.
				var next:Array<ListenerEntry> = list.copy();
				next.splice(i, 1);
				eventMap.set(type, next);
				return;
			}
		}
	}

	/**
	 * Dispatches an event to all listeners registered for its type.
	 *
	 * Automatically sets the `target` (if not already set) and `currentTarget` to this dispatcher.
	 * Listeners are invoked in the order they were registered (respecting `priority`).
	 *
	 * @param event The event to dispatch. Must be a subclass of `Event`.
	 * @return `true` if the event was handled by one or more listeners, `false` otherwise.
	 *
	 * @example
	 * ```haxe
	 * final event = new MyEvent(MyEvent.TYPE);
	 * dispatcher.dispatchEvent(event);
	 * ```
	 */
	public function dispatchEvent<T:Event>(event:T):Bool {
		if (event == null) {
			return false;
		}

		if (event.target == null) {
			var tgt:IEventDispatcher = (__targetDispatcher != null) ? __targetDispatcher : this;
			event.target = tgt;
			event.currentTarget = tgt;
		} else {
			event.currentTarget = (__targetDispatcher != null) ? __targetDispatcher : this;
		}

		return __dispatchEvent(event);
	}

	/**
	 * Checks whether any listeners are registered for the given event `type`.
	 *
	 * @param type The string identifier of the event.
	 * @return `true` if there are listeners for the given type, `false` otherwise.
	 */
	public function hasEventListener(type:String):Bool {
		return __eventMap != null && __eventMap.get(type) != null;
	}

	/**
	 * Removes **all** event listeners from this dispatcher.
	 *
	 * Use with caution—this clears the entire internal event map.
	 */
	public function removeAllListeners():Void {
		if (__eventMap != null) {
			__eventMap.clear();
		}
	}

	private inline function __dispatchEvent(event:Event):Bool {
		var eventMap = __eventMap;
		if (eventMap == null) {
			return false;
		}

		var list:Null<Array<ListenerEntry>> = eventMap.get(event.type);
		if (list == null) {
			return false;
		}

		var len:Int = list.length;
		if (len == 0) {
			return false;
		}

		if (len == 1) {
			var only = list[0];
			if (only == null || only.listener == null) {
				__compactListeners(event.type, list);
				return false;
			}
			only.listener(event);
			return true;
		}

		// The list captured above *is* the snapshot: `addEventListener` and
		// `removeEventListener` replace the array rather than mutate it, so
		// nothing can change the one being walked here. Listeners added during
		// dispatch are still not invoked until the next dispatch, and a
		// listener removed during dispatch is still invoked for this one —
		// the same contract a per-dispatch copy gave, without allocating an
		// array every time an event is sent.
		for (i in 0...len) {
			var entry = list[i];
			if (entry == null || entry.listener == null) {
				continue;
			}
			entry.listener(event);
		}
		return true;
	}

	private inline function __compactListeners(type:String, list:Array<ListenerEntry>):Void {
		if (__eventMap == null) {
			return;
		}

		// Built fresh rather than spliced, for the same reason add and remove
		// build fresh: a dispatch may be walking this array right now, and
		// removing from underneath it would make it skip entries.
		var kept:Array<ListenerEntry> = [];
		for (i in 0...list.length) {
			var entry = list[i];
			if (entry != null && entry.listener != null) {
				kept.push(entry);
			}
		}

		if (kept.length == 0) {
			__eventMap.remove(type);
			return;
		}

		__eventMap.set(type, kept);
	}
}

private typedef ListenerEntry = {
	listener:Function,
	priority:Int,
	order:Int
}
