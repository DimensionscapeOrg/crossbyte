package crossbyte.net._internal.reliable;

/**
	The process's allowance of resets: the FINs reliable datagram servers
	send to addresses that hold no session with them. A token bucket, one
	for the whole process, as `ReliableDatagramServerSocket.maxResetsPerSecond`
	describes: it holds up to one second's worth, and fills at that rate.

	One for the process rather than one a server, because what it bounds is
	what the process can be made to send to an address it has never heard
	from, a source a sender writes for itself, and a process with many
	servers is one source to whoever is on the receiving end.

	Taken under a lock where there are threads: a reset is sent only to a
	stranger, never per packet of a session, and the lock is uncontended
	unless several runtimes are resetting at once.
**/
@:noCompletion
final class ResetBudget {
	// Tokens in the bucket, -1 until the first is asked for (a full bucket);
	// and when it was last filled.
	@:noCompletion private static var __tokens:Float = -1;
	@:noCompletion private static var __filledAt:Float = 0;

	#if target.threaded
	@:noCompletion private static final __lock:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	/**
		Takes one reset from the allowance, and says whether there was one.

		@param perSecond The rate, and the bucket's size: negative is no
		       limit, and 0 allows none.
		@param now `haxe.Timer.stamp()`.
	**/
	public static function take(perSecond:Int, now:Float):Bool {
		if (perSecond < 0) {
			return true;
		}
		if (perSecond == 0) {
			return false;
		}
		#if target.threaded
		__lock.acquire();
		#end
		var tokens:Float = __tokens;
		if (tokens < 0) {
			tokens = perSecond;
		} else if (now > __filledAt) {
			tokens += (now - __filledAt) * perSecond;
		}
		// Held to the rate as it is now, which may have been lowered.
		if (tokens > perSecond) {
			tokens = perSecond;
		}
		// From now, whichever way the clock went: hl, neko and the
		// interpreter read the time of day, which can be set back, and a fill
		// time ahead of the clock would refill nothing until it was passed.
		__filledAt = now;
		var granted:Bool = tokens >= 1;
		if (granted) {
			tokens -= 1;
		}
		__tokens = tokens;
		#if target.threaded
		__lock.release();
		#end
		return granted;
	}

	/** For tests: the bucket full again. **/
	public static function refill():Void {
		#if target.threaded
		__lock.acquire();
		#end
		__tokens = -1;
		#if target.threaded
		__lock.release();
		#end
	}
}
