package crossbyte.events;

import haxe.ds.StringMap;
import crossbyte.Function;

/**
 * ...
 * @author Christopher Speciale
 */

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
 *
 * @author Christopher Speciale
 */
@:access(crossbyte.events.Event)
class EventDispatcher implements IEventDispatcher {
	@:noCompletion private var __eventMap:StringMap<Array<Function>>;
	@:noCompletion private var __targetDispatcher:IEventDispatcher;

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
		__eventMap = new StringMap();
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

		var list:Null<Array<Function>> = __eventMap.get(type);
		if (list == null) {
			__eventMap.set(type, [cast listener]);
			return;
		}

		var idx:Int = priority;
		if (idx < 0) {
			idx = 0;
		} else if (idx > list.length) {
			idx = list.length;
		}

		list.insert(idx, cast listener);
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

		var list:Null<Array<Function>> = __eventMap.get(type);
		if (list == null) {
			return;
		}

		if (list.remove(cast listener) && list.length == 0) {
			__eventMap.remove(type);
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
		}
		event.currentTarget = this;

		return __dispatchEvent(event);
	}

	/**
	 * Checks whether any listeners are registered for the given event `type`.
	 *
	 * @param type The string identifier of the event.
	 * @return `true` if there are listeners for the given type, `false` otherwise.
	 */
	public function hasEventListener(type:String):Bool {
		return __eventMap.get(type) != null;
	}

	/**
	 * Removes **all** event listeners from this dispatcher.
	 *
	 * Use with caution—this clears the entire internal event map.
	 */
	public function removeAllListeners():Void {
		__eventMap.clear();
	}

	private inline function __dispatchEvent(event:Event):Bool {
		var list:Null<Array<Function>> = __eventMap.get(event.type);
		if (list == null) {
			return false;
		}

		var len:Int = list.length;
		if (len == 0) {
			return false;
		}

		if (len == 1) {
			list[0](event);
			return true;
		}

		var snapshot:Array<Function> = list.copy();
		for (i in 0...snapshot.length) {
			snapshot[i](event);
		}
		return true;
	}
}
