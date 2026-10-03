package crossbyte.sys;

/**
	Lightweight background worker that reports progress and completion on the
	owning runtime.

	What the work sends is delivered through the owning runtime's post queue,
	which wakes the runtime for it: one post per batch, when the first message
	of a batch arrives. A worker used to hold a tick listener for as long as it
	ran and poll its queue every tick, so a message waited for the next tick --
	up to a whole frame -- and every idle tick paid for every running worker.

	On JavaScript, which has no threads, the work runs on the one thread there
	is, inside `run()`, holding it for as long as the work takes. What it sends
	is still delivered in a later turn, in order, as from a thread elsewhere, so
	a listener added after `run()` hears it and `state` changes as the messages
	arrive; it was all dispatched inside `run()`.

	This is `TypedWorker<Dynamic, Dynamic, Dynamic>`. A worker whose messages
	have known types is a `TypedWorker` of those types.
**/
class Worker extends TypedWorker<Dynamic, Dynamic, Dynamic> {
	/**
		How many queued messages one worker delivers at a time: every
		worker, `TypedWorker`s too.

		A worker used to deliver exactly one per tick, so a background job
		reporting progress drained at the runtime's tick rate — twelve a second
		under the default `tps`, however often the host pumped — and a job that
		reported faster than that fell further behind the longer it ran.

		Delivery is bounded rather than unbounded so that one talkative worker
		cannot hold the loop in one go: past the bound, the rest are delivered
		in the runtime's next turn at its queue, after whatever else it has to
		do in between. Set it to `0` or less to deliver everything at once.
	**/
	public static var maxMessagesPerTick:Int = 256;

	public function new() {
		super();
	}
}

