package crossbyte._internal.net;

import crossbyte.http.HTTPCancelToken;
import crossbyte.net.NetPump;
import utest.Assert;
import utest.Async;
#if target.threaded
import sys.net.Host;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
	What a lookup can cost, process-wide: the threads it takes, how long its
	caller waits, how many names queue, and how often one name is asked of
	the system.

	Each lookup was a thread started for it, with no cap, no answer kept and
	nothing ending a wait the system did not: ten thousand connects by name
	were ten thousand threads, and a wedged resolver held every one of them,
	and its caller, for as long as it stayed wedged. A real resolver cannot be
	made to wedge, or to answer a name a set number of times, so these cases
	put a lookup of their own in the system's place (`Resolver.__system`), and
	a clock of their own (`Resolver.__clock`). The resolver is shared by the
	whole process, so every case puts back what it changed, and lets go of any
	lookup it wedged before it ends, a thread left wedged would be one of the
	four the rest of the suite looks names up on.

	The names are under `.test`, which RFC 6761 keeps for testing, and fresh
	each run, so an answer kept by one case is never another's.
**/
class ResolverTest extends utest.Test {
	#if target.threaded
	private var __savedSystem:String->Host;
	private var __savedClock:Void->Float;
	private var __savedTimeout:Float;

	public function setup():Void {
		__savedSystem = Resolver.__system;
		__savedClock = Resolver.__clock;
		__savedTimeout = Resolver.__timeout;
	}

	public function teardown():Void {
		Resolver.__system = __savedSystem;
		Resolver.__clock = __savedClock;
		Resolver.__timeout = __savedTimeout;
	}

	public function testAnAnswerIsKeptForItsTimeToLive():Void {
		var now:Float = 1000.0;
		Resolver.__clock = () -> now;
		var system = new FakeSystem();
		Resolver.__system = system.lookUp;
		var name:String = __name();

		var first:Host = Resolver.lookup(name, 5);
		Assert.equals("127.0.0.1", first.toString());
		Assert.equals(1, system.calls(name));

		// Within the time to live: what was kept, without asking the system.
		now += Resolver.TTL - 1;
		var again:Host = Resolver.lookup(name, 5);
		Assert.equals("127.0.0.1", again.toString());
		Assert.equals(1, system.calls(name), "a name looked up a moment ago was asked of the system again");

		// Past it: asked again, so a host that moved is found.
		now += 2;
		Resolver.lookup(name, 5);
		Assert.equals(2, system.calls(name), "an answer was kept past its time to live");
	}

	public function testAFailureIsKeptBrieflyAndThenTriedAgain():Void {
		var now:Float = 2000.0;
		Resolver.__clock = () -> now;
		var system = new FakeSystem();
		system.failing = true;
		Resolver.__system = system.lookUp;
		var name:String = __name();

		var first:String = __failureOf(name);
		Assert.notNull(first, "a name that does not resolve was answered");
		Assert.isTrue(first != null && first.indexOf("no such name") >= 0, "the system's reason was lost: " + first);

		// A reconnect loop asking again at once is told the same, without the
		// broken resolver being asked again.
		Assert.notNull(__failureOf(name));
		Assert.equals(1, system.calls(name), "a failure was asked of the system again at once");

		now += Resolver.NEGATIVE_TTL + 0.5;
		system.failing = false;
		var after:Null<String> = __failureOf(name);
		Assert.isNull(after, "a name was refused after it began to resolve: " + after);
		Assert.equals(2, system.calls(name), "a failure was kept past its time");
	}

	public function testCallersAskingAtOnceShareOneLookup():Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;
		var name:String = __name();

		var answers = new sys.thread.Deque<String>();
		for (_ in 0...6) {
			Thread.create(() -> {
				try {
					answers.add(Resolver.lookup(name, 10).toString());
				} catch (e:Dynamic) {
					answers.add("failed: " + Std.string(e));
				}
			});
		}

		Assert.isTrue(system.awaitEntered(1, 5.0), "the name was never looked up");
		// Every caller filed before the one lookup is let go.
		__sleep(0.2);
		system.unwedge();

		var got:Array<String> = [];
		var deadline:Float = haxe.Timer.stamp() + 10;
		while (got.length < 6 && haxe.Timer.stamp() < deadline) {
			var answer:Null<String> = answers.pop(false);
			if (answer == null) {
				__sleep(0.005);
				continue;
			}
			got.push(answer);
		}
		Assert.equals(6, got.length, "not every caller was answered: " + got);
		for (answer in got) {
			Assert.equals("127.0.0.1", answer);
		}
		Assert.equals(1, system.calls(name), "six callers asking at once made " + system.calls(name) + " lookups");
	}

	public function testNoMoreThanMaxThreadsLookUpAtOnce():Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;

		var asked:Int = Resolver.MAX_THREADS * 3;
		var answers = new sys.thread.Deque<String>();
		for (i in 0...asked) {
			var name:String = __name();
			Thread.create(() -> {
				try {
					answers.add(Resolver.lookup(name, 10).toString());
				} catch (e:Dynamic) {
					answers.add("failed: " + Std.string(e));
				}
			});
		}

		Assert.isTrue(system.awaitEntered(Resolver.MAX_THREADS, 5.0), "fewer lookups ran at once than the resolver allows");
		// Time for a thread past the limit to have started, had one been.
		__sleep(0.3);
		Assert.equals(Resolver.MAX_THREADS, system.inside(), '$asked names at once held ' + system.inside() + " threads in the system's lookup");
		Assert.isTrue(Resolver.__threadCount() <= Resolver.MAX_THREADS, "the resolver started " + Resolver.__threadCount() + " threads");

		system.unwedge();
		var got:Int = 0;
		var failures:Array<String> = [];
		var deadline:Float = haxe.Timer.stamp() + 10;
		while (got < asked && haxe.Timer.stamp() < deadline) {
			var answer:Null<String> = answers.pop(false);
			if (answer == null) {
				__sleep(0.005);
				continue;
			}
			got++;
			if (answer != "127.0.0.1") {
				failures.push(answer);
			}
		}
		Assert.equals(asked, got, "the names queued behind the first four were not all answered");
		Assert.same([], failures);
		Assert.equals(asked, system.total(), "a name was looked up other than once");
	}

	/**
		The wait ends at its timeout though the system call does not: the
		caller is told, and the thread stays in the call until it returns,
		its answer kept for whoever asks next.
	**/
	public function testAWedgedLookupEndsTheWaitButNotTheCall():Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;
		var name:String = __name();

		var started:Float = haxe.Timer.stamp();
		var failure:String = null;
		try {
			Resolver.lookup(name, 0.3);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		var took:Float = haxe.Timer.stamp() - started;

		Assert.notNull(failure, "a lookup that never returned was answered");
		Assert.isTrue(failure != null && failure.indexOf("timed out") >= 0 && failure.indexOf(name) >= 0, "the failure does not say what timed out: " + failure);
		Assert.isTrue(took >= 0.25 && took < 3.0, 'a 0.3 s wait took $took s');
		Assert.equals(1, system.inside(), "the system call ended with the wait");

		// Its answer, when it comes, is kept: the next caller has it at once.
		system.unwedge();
		Assert.isTrue(system.awaitLeft(1, 5.0), "the wedged call never returned");
		var later:Host = null;
		for (_ in 0...200) {
			try {
				later = Resolver.lookup(name, 2);
				break;
			} catch (_:Dynamic) {
				__sleep(0.01);
			}
		}
		Assert.notNull(later);
		Assert.equals(1, system.calls(name), "the answer the wedged call came back with was not kept");
	}

	@:timeout(15000)
	public function testAnAnswerHandedToARuntimeEndsAtTheTimeoutToo(async:Async):Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;
		Resolver.__timeout = 0.4;
		var name:String = __name();

		var answered:Int = 0;
		var failure:String = null;
		var inCall:Bool = true;
		var started:Float = haxe.Timer.stamp();
		Resolver.resolve(name, (host, why) -> {
			answered++;
			Assert.isFalse(inCall, "answered inside resolve()");
			Assert.isNull(host);
			failure = why;
		});
		inCall = false;

		NetPump.until(() -> answered > 0, 8.0, _ -> {
			var took:Float = haxe.Timer.stamp() - started;
			Assert.equals(1, answered, "a lookup that never returned was not answered once");
			Assert.isTrue(failure != null && failure.indexOf("timed out") >= 0, "the failure does not say it timed out: " + failure);
			Assert.isTrue(took < 5.0, 'a 0.4 s limit took $took s');
			system.unwedge();
			// And the late answer does not reach the caller a second time.
			NetPump.until(() -> system.left() > 0, 5.0, _ -> {
				NetPump.wait(0.2, () -> {
					Assert.equals(1, answered, "the wedged call's answer reached a caller that had been told it timed out");
					async.done();
				});
			});
		});
	}

	public function testACancelEndsTheWait():Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;
		var name:String = __name();
		var token = new HTTPCancelToken();

		Thread.create(() -> {
			__sleep(0.2);
			token.cancel();
		});
		var started:Float = haxe.Timer.stamp();
		var failure:String = null;
		try {
			Resolver.lookup(name, 20, token);
		} catch (e:Dynamic) {
			failure = Std.string(e);
		}
		var took:Float = haxe.Timer.stamp() - started;

		Assert.isTrue(failure != null && failure.indexOf("cancelled") >= 0, "a cancelled lookup did not say so: " + failure);
		Assert.isTrue(took < 5.0, 'a lookup cancelled after 0.2 s waited $took s');
		system.unwedge();
		Assert.isTrue(system.awaitLeft(1, 5.0), "the wedged call never returned");
	}

	@:timeout(20000)
	public function testAFullQueueRefusesAtOnce(async:Async):Void {
		var system = new FakeSystem();
		system.wedged = true;
		Resolver.__system = system.lookUp;

		// Every thread wedged first, then the queue filled behind them.
		var answers:Int = 0;
		var failures:Array<String> = [];
		var answer = (host:Null<Host>, why:Null<String>) -> {
			answers++;
			if (host == null) {
				failures.push(why);
			}
		};
		for (_ in 0...Resolver.MAX_THREADS) {
			Resolver.resolve(__name(), answer);
		}

		NetPump.until(() -> system.inside() >= Resolver.MAX_THREADS, 5.0, _ -> {
			for (_ in 0...Resolver.MAX_QUEUED) {
				Resolver.resolve(__name(), answer);
			}
			var asked:Int = Resolver.MAX_THREADS + Resolver.MAX_QUEUED;

			// Past the queue's end: refused, and told so without waiting.
			var started:Float = haxe.Timer.stamp();
			var refused:String = null;
			Resolver.resolve(__name(), (host, why) -> refused = why);
			NetPump.until(() -> refused != null, 2.0, _ -> {
				Assert.isTrue(refused != null && refused.indexOf("refused") >= 0, "a name past a full queue was not refused: " + refused);
				Assert.isTrue(haxe.Timer.stamp() - started < 1.5, "the refusal waited");
				Assert.equals(0, answers, "a queued name was answered while every thread was wedged");
				system.unwedge();
				NetPump.until(() -> answers >= asked, 15.0, _ -> {
					Assert.equals(asked, answers, "the queued names were not all answered once the resolver was free");
					Assert.same([], failures);
					async.done();
				});
			});
		});
	}

	/** What was kept is still handed back later, never inside the call. **/
	@:timeout(10000)
	public function testAKeptAnswerIsStillHandedBackLater(async:Async):Void {
		var system = new FakeSystem();
		Resolver.__system = system.lookUp;
		var name:String = __name();
		Resolver.lookup(name, 5);

		var inCall:Bool = true;
		var host:Host = null;
		var asked:Int = Resolver.__started;
		Resolver.resolve(name, (found, _) -> {
			Assert.isFalse(inCall, "a kept answer was handed back inside resolve()");
			host = found;
		});
		inCall = false;
		Assert.equals(asked + 1, Resolver.__started, "an ask answered from what was kept was not counted");

		NetPump.until(() -> host != null, 5.0, _ -> {
			Assert.notNull(host);
			Assert.equals(1, system.calls(name));
			async.done();
		});
	}

	/**
		A name a lookup thread answers at once, while its caller is still
		inside `lookup` or `resolve`, between filing the ask and starting
		to wait, is answered once, and with the answer.

		The caller read whether its ask had been answered without the lock,
		to catch a full queue's refusal, and the thread answering sets that
		before what the answer is: a caller that looked in between threw
		`null` for a name that had resolved (natively on Linux and on the
		jvm in CI, 2026-10-05), and `resolve` called back twice, with `null`
		and no reason first.
	**/
	@:timeout(60000)
	public function testANameAnsweredAtOnceIsAnsweredOnceAndRight(async:Async):Void {
		var system = new FakeSystem();
		Resolver.__system = system.lookUp;

		var wrong:Array<String> = [];
		for (_ in 0...ROUNDS) {
			try {
				var host:Host = Resolver.lookup(__name(), 5);
				if (host == null || host.toString() != "127.0.0.1") {
					wrong.push("lookup answered " + host);
				}
			} catch (e:Dynamic) {
				wrong.push("lookup threw " + Std.string(e));
			}
			if (wrong.length >= 3) {
				break;
			}
		}

		// In batches the queue takes whole: past MAX_QUEUED waiting, a name
		// is refused, rightly.
		var answers:Map<String, Array<String>> = new Map();
		var names:Array<String> = [];
		function batch(left:Int):Void {
			if (left <= 0) {
				// A while longer, for a second answer to arrive.
				NetPump.wait(0.2, () -> {
					for (name in names) {
						var those:Array<String> = answers.get(name);
						if (those.length != 1 || those[0] != "127.0.0.1") {
							wrong.push("resolve answered " + those);
							if (wrong.length >= 6) {
								break;
							}
						}
					}
					Assert.same([], wrong, "a name answered at once was answered wrongly: " + wrong);
					async.done();
				});
				return;
			}
			var these:Array<String> = [for (_ in 0...BATCH) __name()];
			for (name in these) {
				var those:Array<String> = [];
				answers.set(name, those);
				names.push(name);
				Resolver.resolve(name, (host, why) -> those.push(host != null ? host.toString() : "failed: " + why));
			}
			NetPump.until(() -> Lambda.foreach(these, name -> answers.get(name).length > 0), 10.0, _ -> batch(left - BATCH));
		}
		batch(ROUNDS);
	}

	// Asks of each kind: the race wants many, and each costs a hand-off to
	// a lookup thread and back.
	private static inline var ROUNDS:Int = 3000;
	private static inline var BATCH:Int = 100;

	private static function __failureOf(name:String):Null<String> {
		try {
			Resolver.lookup(name, 5);
			return null;
		} catch (e:Dynamic) {
			return Std.string(e);
		}
	}

	private static function __name():String {
		return "crossbyte-" + Std.random(0x3FFFFFFF) + "-" + Std.random(0x3FFFFFFF) + ".test";
	}

	private static inline function __sleep(seconds:Float):Void {
		crossbyte.sys.System.sleep(seconds);
	}
	#else
	public function testNothingToTestWithoutThreads():Void {
		Assert.pass();
	}
	#end
}

#if target.threaded
/**
	A system lookup a test controls: answers 127.0.0.1, or fails, and while
	`wedged` holds every call until `unwedge()`. Counts calls by name, and
	how many are inside at once.
**/
private class FakeSystem {
	public var failing:Bool = false;
	public var wedged:Bool = false;

	private final __lock:Mutex = new Mutex();
	private final __gate:Lock = new Lock();
	private var __calls:Map<String, Int> = new Map();
	private var __total:Int = 0;
	private var __inside:Int = 0;
	private var __left:Int = 0;
	private var __released:Bool = false;

	public function new() {}

	public function lookUp(name:String):Host {
		if (!StringTools.endsWith(name, ".test")) {
			// Some other case's name, queued before this one began: the real
			// lookup, so nothing false is kept for it.
			return new Host(name);
		}
		__lock.acquire();
		__calls.set(name, (__calls.exists(name) ? __calls.get(name) : 0) + 1);
		__total++;
		__inside++;
		var wait:Bool = wedged && !__released;
		__lock.release();

		if (wait) {
			// Released once per waiter by unwedge(); a bound, in case a case
			// fails before it lets go, so no thread stays here for good.
			__gate.wait(30.0);
		}

		__lock.acquire();
		__inside--;
		__left++;
		var fail:Bool = failing;
		__lock.release();
		if (fail) {
			throw "no such name";
		}
		return new Host("127.0.0.1");
	}

	public function unwedge():Void {
		__lock.acquire();
		__released = true;
		var waiting:Int = __inside;
		__lock.release();
		// One release per call that may be waiting, and some to spare for one
		// arriving as this runs.
		for (_ in 0...waiting + Resolver.MAX_THREADS) {
			__gate.release();
		}
	}

	public function calls(name:String):Int {
		__lock.acquire();
		var count:Int = __calls.exists(name) ? __calls.get(name) : 0;
		__lock.release();
		return count;
	}

	public function total():Int {
		__lock.acquire();
		var count:Int = __total;
		__lock.release();
		return count;
	}

	public function inside():Int {
		__lock.acquire();
		var count:Int = __inside;
		__lock.release();
		return count;
	}

	public function left():Int {
		__lock.acquire();
		var count:Int = __left;
		__lock.release();
		return count;
	}

	public function awaitEntered(count:Int, timeout:Float):Bool {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (inside() < count) {
			if (haxe.Timer.stamp() >= deadline) {
				return false;
			}
			crossbyte.sys.System.sleep(0.005);
		}
		return true;
	}

	public function awaitLeft(count:Int, timeout:Float):Bool {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (left() < count) {
			if (haxe.Timer.stamp() >= deadline) {
				return false;
			}
			crossbyte.sys.System.sleep(0.005);
		}
		return true;
	}
}
#end
