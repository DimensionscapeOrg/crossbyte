package crossbyte.events;

import emitter.Emitter;

/**
	What every CrossByte object that dispatches events is (a socket, a
	server, a runtime, a loader): an `emitter.Emitter`, from Emitter, the
	event library CrossByte is built on, with the names CrossByte's API has
	always used for it.

	```haxe
	import crossbyte.events.Event;
	import crossbyte.events.EventDispatcher;

	var dispatcher = new EventDispatcher();
	dispatcher.addEventListener(Event.COMPLETE, function(event:Event):Void {
		trace("done: " + event.type);
	});
	dispatcher.dispatchEvent(new Event(Event.COMPLETE));
	```

	`addEventListener`, `removeEventListener`, `hasEventListener`,
	`removeAllListeners` and `dispatchEvent` are Emitter's `on`, `off`,
	`has`, `clear` and `dispatch` by their ActionScript names: each is the
	other, inlined, so the two can be mixed freely. Emitter's own names do
	more: `on` and `once` answer with a `Subscription`, which removes that
	listener, a lambda included, with `cancel()`; `once` listens for the next
	event only; `has(type, listener)` asks about one listener.

	## The rules

	- **Order**: listeners of a type run highest `priority` first, and those
	  of one priority in the order they were added.
	- **A listener added again** for a type it already listens for is not
	  added again, as in ActionScript: it keeps its place, and runs once. The
	  runtime (`CrossByte`) is the exception: it holds a `TICK` listener per
	  connection, timer and task, and adding is not a search there, so one
	  added twice runs twice, and each removal takes one.
	- **Changes during a dispatch**: the listeners for a type are taken as
	  they are when a dispatch begins. One removed during it still runs for
	  it; one added waits for the next.
	- **Removal** finds a method read again (`removeEventListener(type,
	  this.onData)`) on every target.
	- **A listener that throws** stops the dispatch and reaches the caller,
	  as it was thrown. The runtime's own events (`TICK`, `INIT`, `EXIT`) and
	  a `Task`'s are contained instead: one listener's failure is reported,
	  and the others still run.
	- **Copy to keep**: an event is valid only during the listener call it
	  is handed to; see `Event`.

	## Target delegation

	A dispatcher made with a `target` (`new EventDispatcher(owner)`) sets
	the events dispatched through it to say `owner` is their `target` and
	`currentTarget`: for a class that keeps a dispatcher inside rather than
	extending one, and hands its calls on.

	@see Event
	@see EventType
**/
class EventDispatcher extends Emitter {
	/**
		@param target What events dispatched here say they were dispatched
		on: the object that holds this dispatcher and hands its calls on.
		This dispatcher itself when null.
	**/
	public function new(?target:IEventDispatcher) {
		super(target);
	}

	/**
		Adds `listener` for events of `type`: Emitter's `on`, without the
		subscription it answers with.

		Listeners run in order of their priority, the highest first, and
		those of one priority in the order they were added; any `Int` is a
		priority, negative ones run after those at `0`. A listener already
		added for `type` is not added again (but on the runtime; see the
		class).

		@param type The type of event, which types the listener.
		@param listener Called with each event of `type`.
		@param priority Where the listener runs among the others for `type`:
			higher runs earlier. Defaults to `0`.
		@throws haxe.exceptions.ArgumentException If `type` or `listener` is null.
	**/
	public inline function addEventListener<T:emitter.Event>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		on(type, listener, priority);
	}

	/**
		Removes `listener` for events of `type`: Emitter's `off`. A method is
		found when it is read again (`removeEventListener(type, this.onData)`);
		a lambda is removed by passing the same function, or by the
		`Subscription` that `on` answers with. Nothing happens if it is not
		there.
	**/
	public inline function removeEventListener<T:emitter.Event>(type:EventType<T>, listener:T->Void):Void {
		off(type, listener);
	}

	/**
		Whether anything listens for events of `type`, now: Emitter's `has`.
		A listener removed during a dispatch is gone from here at once.
	**/
	public inline function hasEventListener(type:String):Bool {
		return has(type);
	}

	/** Removes every listener, for every type: Emitter's `clear`. **/
	public inline function removeAllListeners():Void {
		clear();
	}

	/**
		Sends `event` to the listeners for its type: Emitter's `dispatch`.

		Sets the event's `target` to this dispatcher (or its delegate target)
		when it has none, and its `currentTarget` to the same. An event a
		listener of another dispatcher hands on here keeps its `target`, and
		gets its `currentTarget` back once this dispatch is done. The
		listeners are handed this very object, not a copy.

		A class that changes how its events are dispatched overrides
		`dispatch`, which this calls.

		@return Whether any listener heard it.
	**/
	public inline function dispatchEvent(event:emitter.Event):Bool {
		return dispatch(event);
	}

	/**
		What a contained dispatch (the runtime's and a `Task`'s events) does
		with a listener's failure: logged here; the runtime reports it as
		its own.
	**/
	override private function listenerThrew(error:haxe.Exception, event:emitter.Event):Void {
		crossbyte.utils.Logger.error("A " + event.type + " listener threw: " + Std.string(@:privateAccess error.unwrap()));
	}
}
