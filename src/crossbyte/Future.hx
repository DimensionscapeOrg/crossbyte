package crossbyte;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IEventDispatcher;
import crossbyte.events.TickEvent;
import crossbyte.utils.Logger;
#if (target.threaded && !cpp)
import sys.thread.Mutex;
#end

/**
 * The eventual result of something that has not finished yet: a value that
 * arrives later, callbacks for the two ways that can go, and events for anyone
 * who would rather observe than be called. It is CrossByte's one way of saying
 * "later". `crossbyte.rpc.RPCResponse` extends it with the two fields that are
 * about RPC.
 *
 * Resolution is deliberately not public. A `Future` handed to a caller is
 * something they read; the code that created it keeps the ability to complete
 * it through `@:allow`. A future anyone can resolve is a future nobody can
 * trust. Code outside CrossByte that makes a promise of its own does the same
 * with a `Completer`: it hands out the completer's `future` and keeps the
 * completer.
 *
 * ## `then` adds a handler; it does not replace one
 *
 * `f.then(a); f.then(b);` runs both, in that order, and so does
 * `f.then(a).then(b)`, so a future observed by two places (a caller and a
 * logger, a handler and a metric) reaches both. `then` means "also do this".
 * For "do this to the value", see `map`, and for "then start this other
 * thing", `flatMap`.
 */
@:allow(crossbyte)
class Future<T> implements IEventDispatcher {
	/** Dispatched, once, when the value arrives. */
	public static inline final RESULT:String = "futureResult";

	/** Dispatched, once, when it will not. */
	public static inline final ERROR:String = "futureError";

	/** `true` once this has either resolved or failed. */
	public var completed(default, null):Bool = false;

	/** `true` only when it resolved. */
	public var succeeded(default, null):Bool = false;

	/** The value, when `succeeded`. */
	public var result(default, null):Null<T>;

	/** Why not, when it did not. */
	public var error(default, null):String;

	/**
	 * What went wrong, as the thing itself rather than as prose.
	 *
	 * `error` is a message for a human. This is for the code that has to
	 * decide something: code that decides from a message ends up matching on its
	 * wording, and breaks the day somebody rewords an exception.
	 *
	 * Null when the failure had nothing structured to offer.
	 */
	public var cause(default, null):Null<Dynamic>;

	// Where this stands (0 pending, 1 succeeded, 2 failed), stored as the
	// last thing completing does, with a barrier, and read with one: a reader
	// that sees it complete sees everything written before it. A field and not
	// an AtomicInt, which on cpp is an array: two allocations on every future,
	// and so on every RPC request. See __stateNow.
	#if cpp
	@:noCompletion private var __published:Int = 0;
	#elseif (java || jvm)
	@:volatile @:noCompletion private var __published:Int = 0;
	#end
	// The handlers registered, in order: the first of each kind in a field of
	// its own, since most futures have one, and any after it in a list made
	// only then, so a future nobody registers on allocates no list.
	@:noCompletion private var __onResult1:Null<T->Void> = null;
	@:noCompletion private var __onError1:Null<String->Void> = null;
	@:noCompletion private var __onResultMore:Null<Array<T->Void>> = null;
	@:noCompletion private var __onErrorMore:Null<Array<String->Void>> = null;
	@:noCompletion private var __dispatcher:Null<EventDispatcher>;

	// Whether anyone has said what to do if this fails. Only used to decide
	// whether a failure disappeared without trace; see __reportIfUnhandled.
	@:noCompletion private var __failureObserved:Bool = false;

	/**
		Guards the completion state and the handler lists.

		A future exists to be finished by one piece of code and read by another,
		and nothing in that shape keeps the two on one thread: resolving from a
		worker and calling `then` from the runtime thread is the obvious way to
		use this. Without a lock those two race. `then` pushes onto a handler
		array while resolution walks it, and a push that grows the array frees
		the buffer the walk is still reading, which corrupts the heap.

		Handlers never run while it is held. They are the caller's code, they
		are allowed to call back into this future (registering from inside a
		handler is expected here), and holding a lock across code we do not
		control invites a deadlock. So state changes under the lock, the handler
		list is swapped out, and the calls happen after the release.

		On cpp it is a word of this object's own, taken with an atomic
		compare-and-swap and let go with an atomic store; see `__acquire`. A
		`sys.thread.Mutex` would be an object with a finalizer made for every
		future, and so for every RPC request, at about 250ns a time to take,
		since taking one enters and leaves a GC-free zone.
	**/
	#if cpp
	@:noCompletion private var __lockWord:Int = 0;
	#elseif target.threaded
	@:noCompletion private final __lock:Mutex = new Mutex();
	#end

	public function new() {}

	/**
	 * Registers what to do with the value, and optionally with a failure.
	 *
	 * Additive: every handler registered runs, in the order registered.
	 *
	 * Safe to call after the fact: a future that has already completed calls
	 * back immediately rather than silently never calling. That asymmetry,
	 * where registering a moment too late means never hearing, is the
	 * classic way an asynchronous API loses a result.
	 */
	public function then(onResult:T->Void, ?onError:String->Void):Future<T> {
		__acquire();

		if (onError != null) {
			__failureObserved = true;
		}

		if (completed) {
			// Fired now and not retained. Retaining it would double-call if a
			// handler registered from inside another handler, since the
			// notification loop is still walking the list.
			//
			// Read out under the lock and fired after it: the value cannot
			// change once completed, but reading it while another thread is
			// still writing it can.
			var wasSuccessful:Bool = succeeded;
			var value:Null<T> = result;
			var failure:String = error;
			__release();

			if (wasSuccessful) {
				if (onResult != null) {
					__runResult(onResult, value);
				}
			} else if (onError != null) {
				__runError(onError, failure);
			}

			return this;
		}

		if (onResult != null) {
			__addResult(onResult);
		}

		if (onError != null) {
			__addError(onError);
		}

		__release();
		return this;
	}

	/** Registers `handler`, under the lock. **/
	@:noCompletion private inline function __addResult(handler:T->Void):Void {
		if (__onResult1 == null && __onResultMore == null) {
			__onResult1 = handler;
		} else {
			if (__onResultMore == null) {
				__onResultMore = [];
			}
			__onResultMore.push(handler);
		}
	}

	/** Registers `handler`, under the lock. **/
	@:noCompletion private inline function __addError(handler:String->Void):Void {
		if (__onError1 == null && __onErrorMore == null) {
			__onError1 = handler;
		} else {
			if (__onErrorMore == null) {
				__onErrorMore = [];
			}
			__onErrorMore.push(handler);
		}
	}

	/**
	 * Registers what to do only if this fails.
	 *
	 * `then(handler, onError)` can say the same thing, but only by supplying a
	 * success handler it does not want.
	 */
	public function catchError(onError:String->Void):Future<T> {
		if (onError == null) {
			return this;
		}

		__acquire();
		__failureObserved = true;

		if (completed) {
			var wasSuccessful:Bool = succeeded;
			var failure:String = error;
			__release();

			if (!wasSuccessful) {
				__runError(onError, failure);
			}

			return this;
		}

		__addError(onError);
		__release();
		return this;
	}

	/**
	 * A future for `transform` applied to this one's value.
	 *
	 * Failure passes straight through, message and cause intact, because a
	 * transformation has nothing to say about why the thing it was going to
	 * transform never arrived. A `transform` that throws fails the new future
	 * rather than escaping, for the same reason handlers are isolated.
	 */
	public function map<U>(transform:T->U):Future<U> {
		var mapped = new Future<U>();

		then(function(value:T):Void {
			try {
				mapped.__resolve(transform(value));
			} catch (e:Dynamic) {
				mapped.__fail("The transformation on this value threw: " + Std.string(e), e);
			}
		}, (message:String) -> mapped.__fail(message, cause));

		return mapped;
	}

	/**
	 * A future for the future `next` starts from this one's value.
	 *
	 * The difference from `map` is what the function returns: `map` produces a
	 * value, this produces something else that has not finished either. Without
	 * it, one asynchronous step after another nests one indentation level per
	 * step.
	 */
	public function flatMap<U>(next:T->Future<U>):Future<U> {
		var chained = new Future<U>();

		then(function(value:T):Void {
			var inner:Future<U> = null;

			try {
				inner = next(value);
			} catch (e:Dynamic) {
				chained.__fail("The continuation for this value threw: " + Std.string(e), e);
				return;
			}

			if (inner == null) {
				chained.__fail("The continuation for this value returned no future.", null);
				return;
			}

			inner.then(v -> chained.__resolve(v), (message:String) -> chained.__fail(message, inner.cause));
		}, (message:String) -> chained.__fail(message, cause));

		return chained;
	}

	/**
	 * One future for several, resolved with their values in the order given.
	 *
	 * Fails as soon as any of them fails, carrying that failure: there is no
	 * partial success to report, because the caller asked for all of them.
	 * An empty list resolves immediately, which is the answer to "wait for
	 * nothing" that does not require the caller to special-case it.
	 */
	public static function all<T>(futures:Array<Future<T>>):Future<Array<T>> {
		var joined = new Future<Array<T>>();

		if (futures == null || futures.length == 0) {
			joined.__resolve([]);
			return joined;
		}

		var values:Array<T> = [for (_ in futures) null];
		var remaining:Int = futures.length;

		for (i in 0...futures.length) {
			var index:Int = i;
			var future:Future<T> = futures[i];

			if (future == null) {
				joined.__fail("Future.all was given a null future at index " + index + ".", null);
				return joined;
			}

			future.then(function(value:T):Void {
				if (joined.completed) {
					return;
				}

				// By index, not by arrival: the caller's order is the only one
				// they can match their inputs against.
				values[index] = value;
				remaining--;

				if (remaining == 0) {
					joined.__resolve(values);
				}
			}, (message:String) -> joined.__fail(message, future.cause));
		}

		return joined;
	}

	/**
		Where this stands: `0` still pending, `1` succeeded, `2` failed. Once
		it has said `1` or `2`, `result`, `error` and `cause` are safe to read
		on the asking thread, whichever thread completed this.

		For code that looks before deciding whether to wait, as an RPC
		handler's generated dispatch does, on every call. Reading `completed`
		or `succeeded` plainly can see one set before `result` is, while
		another thread is completing this. The state is published with a
		barrier after everything else and read with one, which costs an atomic
		load where a lock would cost about 250ns on cpp, since acquiring a Mutex
		there enters and leaves a GC-free zone.
	**/
	@:noCompletion public function __stateNow():Int {
		#if cpp
		return untyped __cpp__("_hx_atomic_load(&{0})", __published);
		#elseif (java || jvm)
		return __published;
		#elseif (neko || hl)
		__acquire();
		final state:Int = !completed ? 0 : (succeeded ? 1 : 2);
		__release();
		return state;
		#else
		// One thread, or no lock to take: a plain read is all there is.
		return !completed ? 0 : (succeeded ? 1 : 2);
		#end
	}

	@:noCompletion private inline function __publish(state:Int):Void {
		#if cpp
		untyped __cpp__("_hx_atomic_store(&{0}, {1})", __published, state);
		#elseif (java || jvm)
		__published = state;
		#end
	}

	/** A future that has already succeeded. */
	public static function resolved<T>(value:T):Future<T> {
		var future = new Future<T>();
		future.__resolve(value);
		return future;
	}

	/** A future that has already failed. */
	public static function failed<T>(message:String, ?cause:Dynamic):Future<T> {
		var future = new Future<T>();
		future.__fail(message, cause);
		return future;
	}

	public inline function addEventListener<U>(type:EventType<U>, listener:U->Void, priority:Int = 0):Void {
		if (type == ERROR) {
			__failureObserved = true;
		}

		__ensureDispatcher().addEventListener(type, listener, priority);
	}

	public inline function removeEventListener<U>(type:EventType<U>, listener:U->Void):Void {
		if (__dispatcher != null) {
			__dispatcher.removeEventListener(type, listener);
		}
	}

	public inline function hasEventListener(type:String):Bool {
		return __dispatcher != null && __dispatcher.hasEventListener(type);
	}

	public inline function removeAllListeners():Void {
		if (__dispatcher != null) {
			__dispatcher.removeAllListeners();
		}
	}

	public inline function dispatchEvent<E:Event>(event:E):Bool {
		return __dispatcher != null && __dispatcher.dispatchEvent(event);
	}

	/** Completes with `value`; `false`, changing nothing, if this had already completed. **/
	@:noCompletion private function __resolve(value:T):Bool {
		__acquire();

		if (completed) {
			__release();
			return false;
		}

		completed = true;
		succeeded = true;
		result = value;
		__publish(1);

		final first = __onResult1;
		final more = __onResultMore;
		__onResult1 = null;
		__onResultMore = null;
		__onError1 = null;
		__onErrorMore = null;
		__release();

		if (first != null) {
			__runResult(first, value);
		}
		if (more != null) {
			for (handler in more) {
				__runResult(handler, value);
			}
		}

		// Contained as a handler is. A listener that threw would escape into
		// whoever completed this: for an RPC response, the session reading its
		// connection, which would take the throw for a frame it could not read,
		// close the connection and fail every other call waiting on it.
		if (hasEventListener(RESULT)) {
			__safely(() -> {
				dispatchEvent(new Event(RESULT));
			}, "result event");
		}
		return true;
	}

	@:noCompletion private inline function __reject(message:String):Void {
		__fail(message, null);
	}

	/**
		Fails without the unheard-failure report.

		A deliberate close is not an unhandled error. Whoever registered a
		handler still has to be told, since that is the point of settling on
		close, but whoever did not register one was not waiting for anything,
		and warning them says only that they closed something. Every teardown
		would be noisy otherwise.
	**/
	@:allow(crossbyte) @:noCompletion private function __cancel(message:String):Void {
		__failureObserved = true;
		__fail(message, null);
	}
	/** Fails with `message` and `cause`; `false`, changing nothing, if this had already completed. **/
	@:noCompletion private function __fail(message:String, ?cause:Dynamic):Bool {
		__acquire();

		if (completed) {
			__release();
			return false;
		}

		completed = true;
		succeeded = false;
		error = message;
		this.cause = cause;
		__publish(2);

		final first = __onError1;
		final more = __onErrorMore;
		__onResult1 = null;
		__onResultMore = null;
		__onError1 = null;
		__onErrorMore = null;
		var observed:Bool = __failureObserved;
		__release();

		if (first != null) {
			__runError(first, message);
		}
		if (more != null) {
			for (handler in more) {
				__runError(handler, message);
			}
		}

		if (hasEventListener(ERROR)) {
			__safely(() -> {
				dispatchEvent(new Event(ERROR));
			}, "error event");
		}

		if (!observed) {
			__reportIfUnhandled();
		}
		return true;
	}

	/**
	 * Runs a handler without letting it take anything else down with it.
	 *
	 * Without this, a throwing handler would escape into whoever resolved the
	 * future (for the PHP bridge, the runtime tick, where an escape costs every
	 * other connection rather than the one), stop the handlers registered after
	 * it from running, and skip the event dispatch below, so anyone observing by
	 * `RESULT` instead of by callback would never hear. All three are silent.
	 *
	 * Reported rather than swallowed: the handler is the caller's code and the
	 * bug is theirs to see.
	 */
	@:noCompletion private function __safely(run:Void->Void, phase:String):Void {
		try {
			run();
		} catch (e:Dynamic) {
			__contained(phase, e);
		}
	}

	/** Runs a result handler as `__safely` runs anything, without a closure made to do it. **/
	@:noCompletion private function __runResult(handler:T->Void, value:T):Void {
		try {
			handler(value);
		} catch (e:Dynamic) {
			__contained("result", e);
		}
	}

	/** Runs an error handler as `__safely` runs anything, without a closure made to do it. **/
	@:noCompletion private function __runError(handler:String->Void, message:String):Void {
		try {
			handler(message);
		} catch (e:Dynamic) {
			__contained("error", e);
		}
	}

	@:noCompletion private static function __contained(phase:String, error:Dynamic):Void {
		Logger.error("A Future " + phase + " handler threw and was contained: " + Std.string(error));
	}

	/**
		Takes the lock. On cpp, the word is set from 0 to 1 by an atomic
		compare-and-swap: one instruction when nobody else holds it, which is
		every time a future is made, observed and completed on one thread.
		Another thread holds it for a handful of instructions (swapping a
		handler list, never running one), so a contended acquire waits for it
		in `__contend`.
	**/
	@:noCompletion private inline function __acquire():Void {
		#if cpp
		if ((untyped __cpp__("_hx_atomic_compare_exchange(&{0}, 0, 1)", __lockWord) : Int) != 0) {
			__contend();
		}
		#elseif target.threaded
		__lock.acquire();
		#end
	}

	/** Lets go of the lock: on cpp an atomic store, which publishes what was written under it. **/
	@:noCompletion private inline function __release():Void {
		#if cpp
		untyped __cpp__("_hx_atomic_store(&{0}, 0)", __lockWord);
		#elseif target.threaded
		__lock.release();
		#end
	}

	#if cpp
	/**
		Waits for another thread to let go of the lock. It may be allocating as
		it holds it (a handler list growing), and a collection waits for every
		thread, so this lets the collector stop it between tries rather than
		spinning where it cannot; and it yields its time slice after a while, in
		case the holder is not running.
	**/
	@:noCompletion private function __contend():Void {
		var tries:Int = 0;
		while ((untyped __cpp__("_hx_atomic_compare_exchange(&{0}, 0, 1)", __lockWord) : Int) != 0) {
			cpp.vm.Gc.safePoint();
			if (++tries >= 64) {
				tries = 0;
				crossbyte._internal.system.Sleep.sleep(0);
			}
		}
	}
	#end

	/**
	 * Complains, one tick later, about a failure nobody was listening for.
	 *
	 * A future that fails with no error handler and no `ERROR` listener loses
	 * the failure completely: no log, no exception, no return value anybody
	 * checks. That is the worst way for an asynchronous API to behave, because
	 * the symptom is a thing that simply never happens.
	 *
	 * A tick later, not immediately, because failing before the caller can
	 * attach is legitimate and happens in this codebase: `PHPBridge.execute`
	 * refuses a traversal and returns an already-failed future, and the caller
	 * attaches to it on the next line. Complaining at failure time would call
	 * that unhandled every time.
	 *
	 * Quiet where there is no runtime to borrow a tick from, which is mostly
	 * unit tests. A diagnostic that throws while diagnosing is worse than one
	 * that is absent.
	 */
	@:noCompletion private function __reportIfUnhandled():Void {
		var runtime:Null<crossbyte.core.CrossByte> = null;

		try {
			runtime = crossbyte.core.CrossByte.current();
		} catch (_:Dynamic) {
			return;
		}

		if (runtime == null) {
			return;
		}

		var onTick:TickEvent->Void = null;
		onTick = function(_:TickEvent):Void {
			runtime.removeEventListener(TickEvent.TICK, onTick);

			if (__failureObserved) {
				return;
			}

			Logger.warn("A Future failed and nothing was listening: " + error);
		};

		runtime.addEventListener(TickEvent.TICK, onTick);
	}

	@:noCompletion private inline function __ensureDispatcher():EventDispatcher {
		if (__dispatcher == null) {
			__dispatcher = new EventDispatcher(cast this);
		}
		return __dispatcher;
	}
}
