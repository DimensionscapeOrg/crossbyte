package crossbyte._internal.net;

// Not built for JavaScript: Node resolves names itself, asynchronously, and a
// page has no resolver to offer.
#if !js
import crossbyte.core.CrossByte;
import crossbyte.http.HTTPCancelToken;
import sys.net.Host;
#if target.threaded
import crossbyte._internal.http.h2.H2Wake;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
	Host names looked up off the runtime's thread.

	A lookup can take as long as the network's resolver likes, a second is
	ordinary for a name that does not exist, and a broken resolver makes every
	lookup wait out its timeout, and done on the runtime's thread that is
	how long every socket and timer on it waits too. Measured: a failing lookup
	held the loop for 1,020 ms. A reconnect loop made it worse, retrying
	exactly while the resolver was broken.

	So a name is looked up on one of a few threads kept for it, and the answer
	is handed back on the runtime's thread through its post queue, where the
	socket that asked can act on it. An address needs no lookup and is taken
	as it is. On hxcpp the lookup itself runs outside the collector, so a slow
	one holds up nothing but the thread doing it.

	Every socket's connect by name comes through here, so what lookups can
	cost is bounded for the whole process:

	- **Threads.** `MAX_THREADS` lookups run at once, at most, each on a
	  thread kept for lookups; the rest wait their turn, first come first
	  served. Each lookup was a thread started for it alone, with no cap: ten
	  thousand connects by name were ten thousand threads. A system lookup
	  cannot be stopped once it has started, so this is also the most threads
	  a wedged resolver can hold. A thread with nothing to do ends after
	  `IDLE_SECONDS`.
	- **The wait.** A caller waits `TIMEOUT` seconds for its answer at most,
	  and is then told the lookup timed out, whether it was still waiting for
	  a thread or the system had not answered. The system call carries on on
	  its own thread, and its answer is kept for whoever asks next. Nothing
	  ended a lookup the system did not.
	- **The queue.** `MAX_QUEUED` names, at most, wait for a thread; a name
	  asked for past that fails at once.
	- **Repeats.** A caller asking for a name already being looked up waits
	  for that lookup rather than start another, and an answer is kept and
	  handed to whoever asks for `TTL` seconds, a failure for
	  `NEGATIVE_TTL`: for `MAX_CACHED` names at most. The system's lookup
	  says nothing of how long its answer lives, so `TTL` is a fixed time,
	  the jvm's own default: short enough that a host that moved is found
	  within half a minute, long enough that a burst of connects to one host
	  costs one lookup. Most systems keep answers too, by their real time to
	  live, so a name looked up again is usually answered at once.
**/
class Resolver {
	/** Lookups at once, at most: the threads making system lookups. **/
	public static inline var MAX_THREADS:Int = 4;

	/** Names, at most, waiting for a thread to look them up. **/
	public static inline var MAX_QUEUED:Int = 256;

	/** Names whose answers are kept, at most. **/
	public static inline var MAX_CACHED:Int = 256;

	/** Seconds a name's address is reused before the name is looked up again. **/
	public static inline var TTL:Float = 30;

	/** Seconds a failed lookup is reported again before the name is tried again. **/
	public static inline var NEGATIVE_TTL:Float = 5;

	/** Seconds a caller waits for an answer, at most. **/
	public static inline var TIMEOUT:Float = 30;

	/** Seconds a lookup thread with nothing to do waits for more before it ends. **/
	public static inline var IDLE_SECONDS:Float = 30;

	/**
		How many lookups have been asked for, on every runtime, whether what
		was kept answered them or the system did: how a caller that keeps
		answers of its own can be seen to. Counted without a lock, so two
		runtimes asking at the same moment may count once.
	**/
	@:noCompletion public static var __started:Int = 0;

	/** How many lookups the system was asked to make: what keeping answers saves. **/
	@:noCompletion public static var __queried:Int = 0;

	/**
		The system's lookup, which a test replaces with one it controls, a
		resolver cannot be made to wedge on demand. Called on a lookup thread;
		throws for a name that does not resolve.
	**/
	@:noCompletion public static var __system:String->Host = __systemLookup;

	/** The clock answers are kept by, which a test moves. **/
	@:noCompletion public static var __clock:Void->Float = __stamp;

	/** `TIMEOUT`, which a test shortens. **/
	@:noCompletion public static var __timeout:Float = TIMEOUT;

	// Answers kept, by name, and how many.
	private static var __kept:Map<String, Answer> = new Map();
	private static var __keptCount:Int = 0;

	#if target.threaded
	private static final __lock:Mutex = new Mutex();
	// Released once per lookup queued; each waiting thread takes one.
	private static final __signal:H2Wake = new H2Wake();
	// Names being looked up, or waiting for a thread to be.
	private static var __pending:Map<String, Lookup> = new Map();
	private static var __queue:Array<Lookup> = [];
	private static var __threads:Int = 0;
	private static var __idle:Int = 0;
	#end

	/** Whether `host` is a name to look up, rather than an address. **/
	public static inline function needsLookup(host:String):Bool {
		return !IPv6.isNumericAddress(host);
	}

	/**
		The runtime on this thread, or null where there is none: somewhere to
		hand an answer back to. Asked without throwing, where
		`CrossByte.current()` throws on a thread no runtime is attached to.
	**/
	public static function runtimeHere():Null<CrossByte> {
		try {
			return CrossByte.current();
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
		Looks `host` up off this thread, and calls `then` on the current
		runtime's thread with the answer, or with `null` and why not. Always
		later, never inside this call, and within `TIMEOUT` seconds: the
		lookup's answer, or that it timed out.

		The caller must be on a runtime's thread; the answer goes back to it.
		The runtime is taken here, on that thread, before a lookup thread has
		the name.
	**/
	public static function resolve(host:String, then:(Null<Host>, Null<String>) -> Void):Void {
		var runtime:Null<CrossByte> = runtimeHere();
		if (runtime == null) {
			throw "A name can only be looked up from a CrossByte runtime's thread, which the answer is handed back to.";
		}
		__started++;

		#if target.threaded
		var waiter:Waiter = new Waiter(runtime, then, null);
		var kept:Null<Answer> = __ask(host, waiter);
		if (kept != null || waiter.answered) {
			// What was kept, or the refusal of a full queue: still later,
			// never inside this call, as a lookup's answer is.
			var found:Null<Host> = kept != null ? kept.host : null;
			var failure:Null<String> = kept != null ? kept.failure : waiter.failure;
			runtime.__post(function():Void {
				then(found, failure);
			});
			return;
		}

		// The resolver's own limit on the wait, kept on the runtime that
		// waits: a lookup thread wedged in the system call cannot end it.
		var limit:Float = __timeout;
		waiter.timer = crossbyte.Timer.setTimeout(limit, function():Void {
			waiter.timer = -1;
			if (__withdraw(waiter)) {
				then(null, __timedOut(host, limit));
			}
		});
		#else
		// No threads to look it up on, so it is looked up here, but still
		// answered later, so a caller sees the one order on every target.
		var answer:Answer = __lookUpHere(host);
		runtime.__post(function():Void {
			then(answer.host, answer.failure);
		});
		#end
	}

	/**
		Looks `host` up and waits here for the answer, on a thread that may
		block, `URLLoader`'s, or a connector's, and answers the host, or
		throws a `String` saying why not.

		An address is taken as it is. A name is looked up on the resolver's
		threads, as `resolve` looks one up, so that the wait can end where the
		system call cannot: after `timeout` seconds, `TIMEOUT`, if that is
		sooner or `timeout` is `0` or less, or as soon as `cancel` is
		cancelled.
	**/
	public static function lookup(host:String, timeout:Float = 0, ?cancel:HTTPCancelToken):Host {
		if (!needsLookup(host)) {
			return new Host(host);
		}
		__started++;

		#if target.threaded
		var wake:H2Wake = new H2Wake();
		var waiter:Waiter = new Waiter(null, null, wake);
		var kept:Null<Answer> = __ask(host, waiter);
		if (kept != null) {
			return __hostOf(kept);
		}
		if (waiter.answered) {
			throw waiter.failure;
		}

		var limit:Float = __timeout;
		if (timeout > 0 && timeout < limit) {
			limit = timeout;
		}
		var onCancel:Void->Void = () -> wake.release();
		if (cancel != null) {
			cancel.onCancel(onCancel);
		}
		wake.wait(limit);
		if (cancel != null) {
			cancel.removeHandler(onCancel);
		}

		__lock.acquire();
		var answered:Bool = waiter.answered;
		if (!answered) {
			waiter.answered = true;
			__drop(waiter);
		}
		__lock.release();

		if (answered) {
			if (waiter.host != null) {
				return waiter.host;
			}
			throw waiter.failure;
		}
		if (cancel != null && cancel.cancelled) {
			throw "Looking up " + host + " was cancelled";
		}
		throw __timedOut(host, limit);
		#else
		return __hostOf(__lookUpHere(host));
		#end
	}

	/** Forgets every answer kept. For tests. **/
	@:noCompletion public static function __forget():Void {
		#if target.threaded
		__lock.acquire();
		#end
		__kept = new Map();
		__keptCount = 0;
		#if target.threaded
		__lock.release();
		#end
	}

	/** Lookup threads alive now, working or waiting for work. For tests. **/
	@:noCompletion public static function __threadCount():Int {
		#if target.threaded
		__lock.acquire();
		var count:Int = __threads;
		__lock.release();
		return count;
		#else
		return 0;
		#end
	}

	/** System lookups made so far. For tests. **/
	@:noCompletion public static function __queriedCount():Int {
		#if target.threaded
		__lock.acquire();
		var count:Int = __queried;
		__lock.release();
		return count;
		#else
		return __queried;
		#end
	}

	private static function __hostOf(answer:Answer):Host {
		if (answer.host != null) {
			return answer.host;
		}
		throw answer.failure;
	}

	private static inline function __timedOut(host:String, seconds:Float):String {
		return "looking up " + host + " timed out after " + seconds + " s";
	}

	private static function __systemLookup(name:String):Host {
		return new Host(name);
	}

	private static function __stamp():Float {
		return haxe.Timer.stamp();
	}

	/** The answer kept for `name`, if it is still good. Under the lock. **/
	private static function __keptFor(name:String, now:Float):Null<Answer> {
		var kept:Null<Answer> = __kept.get(name);
		if (kept == null) {
			return null;
		}
		if (now < kept.expires) {
			return kept;
		}
		__kept.remove(name);
		__keptCount--;
		return null;
	}

	/**
		Keeps `answer` for its name, making room if there is none by letting
		go of what has expired, and failing that of whatever would expire
		soonest: a walk of `MAX_CACHED` entries, made only when a new name
		finds them all taken. Under the lock.
	**/
	private static function __keep(name:String, answer:Answer, now:Float):Void {
		if (__kept.exists(name)) {
			__kept.set(name, answer);
			return;
		}
		if (__keptCount >= MAX_CACHED) {
			var soonest:Null<String> = null;
			var soonestAt:Float = Math.POSITIVE_INFINITY;
			var expired:Array<String> = [];
			for (other => kept in __kept) {
				if (kept.expires <= now) {
					expired.push(other);
				} else if (kept.expires < soonestAt) {
					soonestAt = kept.expires;
					soonest = other;
				}
			}
			for (other in expired) {
				__kept.remove(other);
				__keptCount--;
			}
			if (__keptCount >= MAX_CACHED && soonest != null) {
				__kept.remove(soonest);
				__keptCount--;
			}
		}
		__kept.set(name, answer);
		__keptCount++;
	}

	private static function __answer(host:Null<Host>, failure:Null<String>, now:Float):Answer {
		return new Answer(host, host != null ? null : failure, now + (host != null ? TTL : NEGATIVE_TTL));
	}

	#if target.threaded
	/**
		Files `waiter` for `name`. Answers what was kept for it, if anything;
		otherwise adds it to the lookup under way or queues a new one, and
		answers null, having answered `waiter` itself with a refusal if the
		queue is full.
	**/
	private static function __ask(name:String, waiter:Waiter):Null<Answer> {
		var start:Bool = false;
		__lock.acquire();
		var kept:Null<Answer> = __keptFor(name, __clock());
		if (kept != null) {
			__lock.release();
			return kept;
		}

		var lookup:Null<Lookup> = __pending.get(name);
		if (lookup == null) {
			if (__queue.length >= MAX_QUEUED) {
				waiter.answered = true;
				waiter.failure = "looking up " + name + " was refused: " + MAX_QUEUED + " names were already waiting to be looked up";
				__lock.release();
				return null;
			}
			lookup = new Lookup(name);
			__pending.set(name, lookup);
			__queue.push(lookup);
			// A thread is started only when those waiting are too few for what
			// is queued, and never past MAX_THREADS.
			start = __idle < __queue.length && __threads < MAX_THREADS;
			if (start) {
				__threads++;
			}
			__signal.release();
		}
		lookup.waiters.push(waiter);
		waiter.lookup = lookup;
		__lock.release();

		if (start) {
			Thread.create(__work);
		}
		return null;
	}

	/**
		Takes `waiter` off its lookup if it has not been answered, its caller
		having stopped waiting, and says whether it had not.
	**/
	private static function __withdraw(waiter:Waiter):Bool {
		__lock.acquire();
		var waiting:Bool = !waiter.answered;
		if (waiting) {
			waiter.answered = true;
			__drop(waiter);
		}
		__lock.release();
		return waiting;
	}

	/** Takes `waiter` off its lookup's list. Under the lock. **/
	private static inline function __drop(waiter:Waiter):Void {
		if (waiter.lookup != null) {
			waiter.lookup.waiters.remove(waiter);
		}
	}

	/** A lookup thread: takes queued names in turn, until none comes for `IDLE_SECONDS`. **/
	private static function __work():Void {
		while (true) {
			__lock.acquire();
			__idle++;
			__lock.release();

			var woken:Bool = __signal.wait(IDLE_SECONDS);

			__lock.acquire();
			__idle--;
			if (!woken) {
				if (__queue.length == 0) {
					__threads--;
					__lock.release();
					return;
				}
				// A name came as the wait ran out, its release still in the
				// lock: this thread goes back for it.
				__lock.release();
				continue;
			}
			var lookup:Null<Lookup> = __queue.shift();
			if (lookup == null) {
				__lock.release();
				continue;
			}
			if (lookup.waiters.length == 0) {
				// Everyone who asked stopped waiting before a thread was
				// free: there is nobody to look it up for.
				__pending.remove(lookup.name);
				__lock.release();
				continue;
			}
			__queried++;
			__lock.release();

			var host:Null<Host> = null;
			var failure:Null<String> = null;
			try {
				host = __system(lookup.name);
			} catch (e:Dynamic) {
				failure = Std.string(e);
			}
			if (host == null && failure == null) {
				failure = "no address";
			}

			__lock.acquire();
			var answer:Answer = __answer(host, failure, __clock());
			__pending.remove(lookup.name);
			__keep(lookup.name, answer, __clock());
			var waiters:Array<Waiter> = lookup.waiters;
			lookup.waiters = [];
			for (waiter in waiters) {
				waiter.answered = true;
				waiter.host = answer.host;
				waiter.failure = answer.failure;
			}
			__lock.release();

			for (waiter in waiters) {
				__deliver(waiter, answer);
			}
		}
	}

	/** Hands `answer` to `waiter`: on its runtime, or to the thread blocked on it. **/
	private static function __deliver(waiter:Waiter, answer:Answer):Void {
		if (waiter.wake != null) {
			waiter.wake.release();
			return;
		}
		var then:(Null<Host>, Null<String>) -> Void = waiter.then;
		waiter.runtime.__post(function():Void {
			// The resolver's limit, cleared on the runtime that armed it, and
			// only if it has not run: a handle cleared after it ran can name
			// a timer armed since.
			if (waiter.timer >= 0) {
				crossbyte.Timer.clear(waiter.timer);
				waiter.timer = -1;
			}
			then(answer.host, answer.failure);
		});
	}
	#else
	/** A lookup made in the call, kept as the threaded targets keep one. **/
	private static function __lookUpHere(name:String):Answer {
		var kept:Null<Answer> = __keptFor(name, __clock());
		if (kept != null) {
			return kept;
		}
		var host:Null<Host> = null;
		var failure:Null<String> = null;
		__queried++;
		try {
			host = __system(name);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		var answer:Answer = __answer(host, failure != null ? failure : "no address", __clock());
		__keep(name, answer, __clock());
		return answer;
	}
	#end
}

/** What a lookup answered, and until when it is handed out again. **/
private class Answer {
	public final host:Null<Host>;
	public final failure:Null<String>;
	public final expires:Float;

	public function new(host:Null<Host>, failure:Null<String>, expires:Float) {
		this.host = host;
		this.failure = failure;
		this.expires = expires;
	}
}

#if target.threaded
/** A name being looked up, or waiting for a thread to be, and who waits for it. **/
private class Lookup {
	public final name:String;
	public var waiters:Array<Waiter> = [];

	public function new(name:String) {
		this.name = name;
	}
}

/**
	One caller waiting for an answer: a runtime to hand it to, or a thread
	blocked on `wake`. Written under the resolver's lock, but for `timer`,
	which only its runtime touches; every field exists from the start, for
	neko, where one set later can move an object's field table under another
	thread.
**/
private class Waiter {
	public final runtime:Null<CrossByte>;
	public final then:Null<(Null<Host>, Null<String>) -> Void>;
	public final wake:Null<H2Wake>;
	public var lookup:Null<Lookup> = null;
	public var answered:Bool = false;
	public var host:Null<Host> = null;
	public var failure:Null<String> = null;
	// The runtime timer ending the wait, or -1, which no timer is.
	public var timer:Int = -1;

	public function new(runtime:Null<CrossByte>, then:Null<(Null<Host>, Null<String>) -> Void>, wake:Null<H2Wake>) {
		this.runtime = runtime;
		this.then = then;
		this.wake = wake;
	}
}
#end
#end
