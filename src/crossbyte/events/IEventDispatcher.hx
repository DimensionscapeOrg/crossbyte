package crossbyte.events;

/**
	What an event can be dispatched on: `emitter.IEmitter`, which every
	`EventDispatcher` is, and a class that holds one and hands its calls on
	(a `Future`) implements. An event's `target` and `currentTarget` are
	typed by it.

	It declares `events`, the emitter's verbs (`events.dispatch(event)`
	and the rest): a class holding a dispatcher answers with that
	dispatcher's, and offers the ActionScript names as its own.
**/
typedef IEventDispatcher = emitter.IEmitter;
