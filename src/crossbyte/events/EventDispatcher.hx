package crossbyte.events;

import haxe.ds.StringMap;
import crossbyte.Function;

/**
 * ...
 * @author Christopher Speciale
 */
@:access(crossbyte.events.Event)
class EventDispatcher implements IEventDispatcher {
	@:noCompletion private var __eventMap:StringMap<Array<Function>>;
	@:noCompletion private var __targetDispatcher:IEventDispatcher;

	public function new(target:IEventDispatcher = null):Void {
		if (target != null) {
			__targetDispatcher = target;
		}
		__eventMap = new StringMap();
	}

	public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		// Todo: proper error handling
		if (listener == null)
			throw "listener must not be null";

		if (__eventMap.exists(type)) {
			var list:Array<Function> = __eventMap.get(type);
			list.insert(priority, listener);
		} else {
			__eventMap.set(type, [listener]);
		}
	}

	public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		if (__eventMap == null || listener == null)
			return;

		if (__eventMap.exists(type)) {
			var list:Array<Function> = __eventMap.get(type);

			list.remove(listener);

			if (list.length == 0) {
				__eventMap.remove(type);
			}
		}
	}

	public function dispatchEvent<T:Event>(event:T):Bool {
		if (__targetDispatcher != null) {
			event.target = __targetDispatcher;
		} else {
			event.target = this;
		}

		return __dispatchEvent(event);
	}

	public function hasEventListener(type:String):Bool {
		return __eventMap.exists(type);
	}

	public function removeAllListeners():Void {
		__eventMap.clear();
	}

	private function __dispatchEvent(event:Event):Bool {
		if (event == null)
			return false;

		var type = event.type;

		if (__eventMap.exists(type)) {
			var callbacks:Array<Function> = __eventMap.get(type);

			if (event.target == null) {
				if (__targetDispatcher != null) {
					event.target = __targetDispatcher;
				} else {
					event.target = this;
				}

				event.currentTarget = this;
			}

			for (callback in callbacks) {
				callback(event);
			}
		} else {
			return false;
		}

		return true;
	}
}
