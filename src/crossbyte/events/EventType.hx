package crossbyte.events;

/**
	The name of an event, typed by the event it names: a listener added for
	an `EventType<T>` is a `T->Void`, checked when it is added. Emitter's
	`emitter.EventType`, the one type for event names CrossByte and every
	other user of Emitter share.

	```haxe
	import crossbyte.events.Event;
	import crossbyte.events.EventType;

	class ScoreEvent extends Event {
		public static inline var SCORED:EventType<ScoreEvent> = "scored";

		public var points:Int;

		public function new(points:Int) {
			super(SCORED);
			this.points = points;
		}
	}
	```

	At run time it is the `String` it was made from.
**/
typedef EventType<T:emitter.Event> = emitter.EventType<T>;
