package crossbyte;

import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.IEventDispatcher;
import crossbyte.events.TickEvent;
import crossbyte.utils.Logger;
#if (cpp || neko || hl || java || jvm)
import sys.thread.Mutex;
#end

/**
 * The eventual result of something that has not finished yet.
 *
 * This was `crossbyte.rpc.RPCResponse`, and nothing about it was ever
 * RPC-specific: a value that arrives later, callbacks for the two ways that can
 * go, and events for anyone who would rather observe than be called. Promoting
 * it is not tidying. It is the difference between a framework with one way of
 * saying "later" and a framework with four -- events on `URLLoader`, threads on
 * `Task`, `then` on RPC, and whatever the next asynchronous API invented for
 * itself.
 *
 * `RPCResponse` remains, extending this and adding the two fields that really
 * are about RPC, so nothing on that side moves.
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
 * This is worth stating because the first version of this class did replace,
 * and did it silently. `f.then(a); f.then(b);` ran only `b`, so a future
 * observed by two places -- a caller and a logger, a handler and a metric --
 * quietly lost one of them. Worse, `then` returns the future, which invites
 * `f.then(a).then(b)`, and that expression ran only `b` as well: the shape the
 * API advertised was the shape it punished.
 *
 * `then` now means "also do this". For "do this to the value", see `map`, and
 * for "then start this other thing", `flatMap`.
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
	 * decide something -- and code that has to decide something from a message
	 * ends up matching on its wording, which is how a `504 Gateway Timeout`
	 * turns into a `502 Bad Gateway` the day somebody rewords an exception.
	 * That exact match existed here before this field did.
	 *
	 * Null when the failure had nothing structured to offer.
	 */
	public var cause(default, null):Null<Dynamic>;

	// Where this stands -- 0 pending, 1 succeeded, 2 failed -- stored as the
	// last thing completing does, with a barrier, and read with one: a reader
	// that sees it complete sees everything written before it. A field and not
	// an AtomicInt, which on cpp is an array: two allocations on every future,
	// and so on every RPC request. See __stateNow.
	#if cpp
	@:noCompletion private var __published:Int = 0;
	#elseif (java || jvm)
	@:volatile @:noCompletion private var __published:Int = 0;
	#end
	@:noCompletion private var __onResult:Array<T->Void> = [];
	@:noCompletion private var __onError:Array<String->Void> = [];
	@:noCompletion private var __dispatcher:Null<EventDispatcher>;

	// Whether anyone has said what to do if this fails. Only used to decide
	// whether a failure disappeared without trace; see __reportIfUnhandled.
	@:noCompletion private var __failureObserved:Bool = false;

	/**
		Guards the completion state and the handler lists.

		A future exists to be finished by one piece of code and read by another,
		and there is nothing in that shape which keeps the two on one thread --
		resolving from a worker and calling `then` from the runtime thread is
		the obvious way to use this. Without a lock those two race: `then`
		pushes onto a handler array while resolution walks it, and a push that
		grows the array frees the buffer the walk is still reading. That is not
		a lost callback, it is heap corruption.

		Handlers never run while it is held. They are the caller's code, they
		are allowed to call back into this future -- registering from inside a
		handler is expected here -- and holding a lock across code we do not
		control invites a deadlock. So state changes under the lock, the handler
		list is swapped out, and the calls happen after the release.
	**/
	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private final __lock:Mutex = new Mutex();
	#end

	public function new() {}

	/**
	 * Registers what to do with the value, and optionally with a failure.
	 *
	 * Additive: every handler registered runs, in the order registered.
	 *
	 * Safe to call after the fact: a future that has already completed calls
	 * back immediately rather than silently never calling. That asymmetry --
	 * where registering a moment too late means never hearing -- is the
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
					__safely(() -> onResult(value), "result");
				}
			} else if (onError != null) {
				__safely(() -> onError(failure), "error");
			}

			return this;
		}

		if (onResult != null) {
			__onResult.push(onResult);
		}

		if (onError != null) {
			__onError.push(onError);
		}

		__release();
		return this;
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
				__safely(() -> onError(failure), "error");
			}

			return this;
		}

		__onError.push(onError);
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
	 *
	 * `Store.getString` was this written by hand -- make a future, forward one
	 * arm through a conversion and the other arm unchanged -- and so is every
	 * function that adapts one asynchronous result into another.
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
	 * step, which is how `StoreTest` ended up five deep.
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
	 * Fails as soon as any of them fails, carrying that failure -- there is no
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
		load; taking the lock instead cost an RPC call about 250ns on cpp,
		where acquiring a Mutex enters and leaves a GC-free zone.
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

		var handlers = __onResult;
		__onResult = [];
		__onError = [];
		__release();

		for (handler in handlers) {
			__safely(() -> handler(value), "result");
		}

		if (hasEventListener(RESULT)) {
			dispatchEvent(new Event(RESULT));
		}
		return true;
	}

	@:noCompletion private inline function __reject(message:String):Void {
		__fail(message, null);
	}

	/**
		Fails without the unheard-failure report.

		A deliberate close is not an unhandled error. Whoever registered a
		handler still has to be told -- that is the whole point of settling on
		close -- but whoever did not register one was not waiting for anything,
		and warning them says only that they closed something. Left as an
		ordinary failure it made every teardown noisy: twenty-six extra lines in
		one native suite run, measured, and invisible on jvm because the classes
		that close futures are skipped there.
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

		var handlers = __onError;
		__onResult = [];
		__onError = [];
		var observed:Bool = __failureObserved;
		__release();

		for (handler in handlers) {
			__safely(() -> handler(message), "error");
		}

		if (hasEventListener(ERROR)) {
			dispatchEvent(new Event(ERROR));
		}

		if (!observed) {
			__reportIfUnhandled();
		}
		return true;
	}

	/**
	 * Runs a handler without letting it take anything else down with it.
	 *
	 * Three things went wrong without this, and all three were silent. A
	 * throwing handler escaped into whoever resolved the future -- which for
	 * the PHP bridge is the runtime tick, where an escape costs every other
	 * connection rather than the one. It stopped the handlers registered after
	 * it from running at all. And it skipped the event dispatch below, so
	 * anyone observing by `RESULT` instead of by callback simply never heard.
	 *
	 * Reported rather than swallowed: the handler is the caller's code and the
	 * bug is theirs to see.
	 */
	@:noCompletion private inline function __acquire():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __release():Void {
		#if (cpp || neko || hl || java || jvm)
		__lock.release();
		#end
	}

	@:noCompletion private function __safely(run:Void->Void, phase:String):Void {
		try {
			run();
		} catch (e:Dynamic) {
			Logger.error("A Future " + phase + " handler threw and was contained: " + Std.string(e));
		}
	}

	/**
	 * Complains, one tick later, about a failure nobody was listening for.
	 *
	 * A future that fails with no error handler and no `ERROR` listener loses
	 * the failure completely: no log, no exception, no return value anybody
	 * checks. That is the worst way for an asynchronous API to behave, because
	 * the symptom is a thing that simply never happens.
	 *
	 * A tick later, not immediately, because failing before the caller can
	 * attach is legitimate and happens in this codebase -- `PHPBridge.execute`
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
