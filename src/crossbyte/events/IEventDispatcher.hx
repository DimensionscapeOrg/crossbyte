package crossbyte.events;

/**
	What an event can be dispatched on: `emitter.IEmitter`, which every
	`EventDispatcher` is, and a class that holds one and hands its calls on
	(a `Future`) implements. An event's `target` and `currentTarget` are
	typed by it.

	It declares `dispatch` alone. Listening goes through the dispatcher's
	own methods (`addEventListener` and the rest), which a class holding a
	dispatcher offers as its own.
**/
typedef IEventDispatcher = emitter.IEmitter;
