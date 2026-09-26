package crossbyte._internal.net;

// Not built for JavaScript: Node resolves names itself, asynchronously, and a
// page has no resolver to offer.
#if !js
import crossbyte.core.CrossByte;
import sys.net.Host;

/**
	Host names looked up off the runtime's thread.

	A lookup can take as long as the network's resolver likes -- a second is
	ordinary for a name that does not exist, and a broken resolver makes every
	lookup wait out its timeout -- and done on the runtime's thread that is
	how long every socket and timer on it waits too. Measured: a failing lookup
	held the loop for 1,020 ms. A reconnect loop made it worse, retrying
	exactly while the resolver was broken.

	So a name is looked up on a thread of its own, and the answer is handed
	back on the runtime's thread through its post queue, where the socket that
	asked can act on it. An address needs no lookup and is taken as it is.
	On hxcpp the lookup itself runs outside the collector, so a slow one holds
	up nothing but the thread doing it.
**/
class Resolver {
	/**
		How many lookups have been started, on every runtime: how a caller that
		caches answers can be seen to. Counted without a lock, so two runtimes
		starting one each at the same moment may count once.
	**/
	@:noCompletion public static var __started:Int = 0;

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
		Looks `host` up on a thread of its own, and calls `then` on the current
		runtime's thread with the answer -- or with `null` and why not. Always
		later, never inside this call.

		The caller must be on a runtime's thread; the answer goes back to it.
		The runtime is taken here, on that thread, before the lookup's own
		thread exists.
	**/
	public static function resolve(host:String, then:(Null<Host>, Null<String>) -> Void):Void {
		var runtime:Null<CrossByte> = runtimeHere();
		if (runtime == null) {
			throw "A name can only be looked up from a CrossByte runtime's thread, which the answer is handed back to.";
		}
		__started++;

		#if target.threaded
		sys.thread.Thread.create(function():Void {
			__answer(runtime, host, then);
		});
		#else
		// No threads to look it up on, so it is looked up here -- but still
		// answered later, so a caller sees the one order on every target.
		__answer(runtime, host, then);
		#end
	}

	private static function __answer(runtime:CrossByte, host:String, then:(Null<Host>, Null<String>) -> Void):Void {
		var resolved:Null<Host> = null;
		var failure:Null<String> = null;

		try {
			resolved = new Host(host);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}

		runtime.__post(function():Void {
			then(resolved, failure);
		});
	}
}
#end
