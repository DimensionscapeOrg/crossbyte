package crossbyte;

import crossbyte.Future;
import crossbyte.errors.ArgumentError;
import utest.Assert;
import crossbyte.test.Require;

/**
 * `crossbyte.Future`.
 *
 * There were no tests for this class at all, which is not incidental to what
 * they found: `then` replaced the previous handler instead of adding to it, a
 * throwing handler escaped into whoever resolved the future and stopped every
 * other handler and every event listener with it, and `f.then(a).then(b)` --
 * the shape the fluent return type advertises -- ran only `b`. All four are
 * one-line demonstrations, and none of them had one.
 *
 * Needs no socket and no filesystem, so it runs on every target including the
 * browser. One case is the exception and says why: a future is finished by one
 * piece of code and read by another, and nothing in that shape keeps the two on
 * the same thread, so the threaded targets check that it survives being used
 * that way.
 */
@:access(crossbyte.Future)
class FutureTest extends utest.Test {
	public function testEveryRegisteredHandlerRuns():Void {
		// `then` adds; it does not replace. It replaced, silently, so a future
		// observed by a caller and by a logger lost one of them at random --
		// whichever registered first.
		var future = new Future<Int>();
		var seen:Array<String> = [];

		future.then(_ -> seen.push("first"));
		future.then(_ -> seen.push("second"));
		future.then(_ -> seen.push("third"));
		future.__resolve(1);

		Assert.same(["first", "second", "third"], seen);
	}

	public function testChainedThenCallsRunInOrder():Void {
		// `then` returns the future, which invites this. It used to run only
		// the last one, so the expression the API's own shape suggested was
		// the expression that lost handlers.
		var future = new Future<Int>();
		var seen:Array<String> = [];

		future.then(_ -> seen.push("a")).then(_ -> seen.push("b"));
		future.__resolve(1);

		Assert.same(["a", "b"], seen);
	}

	public function testAHandlerRegisteredAfterCompletionStillRuns():Void {
		var future = Future.resolved(7);
		var got:Int = -1;

		future.then(value -> got = value);

		Assert.equals(7, got);
	}

	public function testAThrowingHandlerIsContained():Void {
		// Three failures in one: the throw escaped into the resolver -- which
		// for the PHP bridge is the runtime tick, where an escape costs every
		// other connection -- it stopped the handlers after it, and it skipped
		// the event dispatch, so anyone observing by RESULT never heard.
		var future = new Future<Int>();
		var afterRan = false;
		var listenerRan = false;

		future.addEventListener(Future.RESULT, _ -> listenerRan = true);
		future.then(_ -> throw "the handler exploded");
		future.then(_ -> afterRan = true);

		var escaped = false;
		try {
			future.__resolve(1);
		} catch (_:Dynamic) {
			escaped = true;
		}

		Assert.isFalse(escaped, "a throwing handler escaped into the resolver");
		Assert.isTrue(afterRan, "a throwing handler stopped the one registered after it");
		Assert.isTrue(listenerRan, "a throwing handler suppressed the RESULT listeners");
	}

	public function testResolvingTwiceKeepsTheFirstValue():Void {
		var future = new Future<Int>();
		var values:Array<Int> = [];

		future.then(value -> values.push(value));
		future.__resolve(1);
		future.__resolve(2);

		Assert.same([1], values);
		Assert.equals(1, future.result);
	}

	public function testFailureCarriesItsCause():Void {
		// The reason this field exists: code that has to decide something from
		// a failure was reading the message to do it. `HTTPRequestHandler`
		// picked 504 over 502 by searching for "did not respond within", so
		// rewording an exception would have changed a status code.
		var boom = new ArgumentError("no");
		var future = Future.failed("it went wrong", boom);

		Assert.isFalse(future.succeeded);
		Assert.equals("it went wrong", future.error);
		Assert.isTrue(future.cause == boom);
	}

	public function testCatchErrorRunsOnlyOnFailure():Void {
		var failed = new Future<Int>();
		var caught:String = null;
		failed.catchError(message -> caught = message);
		failed.__fail("nope", null);
		Assert.equals("nope", caught);

		var fine = new Future<Int>();
		var ran = false;
		fine.catchError(_ -> ran = true);
		fine.__resolve(1);
		Assert.isFalse(ran);
	}

	public function testMapTransformsTheValue():Void {
		var source = new Future<Int>();
		var mapped = source.map(value -> value * 2);
		var got:Int = -1;

		mapped.then(value -> got = value);
		source.__resolve(21);

		Assert.equals(42, got);
	}

	public function testMapPassesFailureThroughWithItsCause():Void {
		var boom = new ArgumentError("underlying");
		var source = new Future<Int>();
		var mapped = source.map(value -> value * 2);
		var caught:String = null;

		mapped.catchError(message -> caught = message);
		source.__fail("the source failed", boom);

		Assert.equals("the source failed", caught);
		// The cause survives the hop: a transformation has nothing to say
		// about why the value it was going to transform never arrived.
		Assert.isTrue(mapped.cause == boom);
	}

	public function testAThrowingTransformFailsTheMappedFuture():Void {
		var source = new Future<Int>();
		var mapped = source.map(function(value:Int):Int {
			throw "the transform exploded";
		});
		var caught:String = null;

		mapped.catchError(message -> caught = message);

		var escaped = false;
		try {
			source.__resolve(1);
		} catch (_:Dynamic) {
			escaped = true;
		}

		Assert.isFalse(escaped);
		Require.notNull(caught);
		Assert.isTrue(caught.indexOf("exploded") >= 0, "got " + caught);
	}

	public function testFlatMapSequencesTwoFutures():Void {
		var first = new Future<Int>();
		var second = new Future<String>();
		var chained = first.flatMap(value -> second);
		var got:String = null;

		chained.then(value -> got = value);

		first.__resolve(1);
		Assert.isNull(got, "the chain resolved before its second future did");

		second.__resolve("done");
		Assert.equals("done", got);
	}

	public function testFlatMapReportsAnInnerFailure():Void {
		var first = new Future<Int>();
		var second = new Future<String>();
		var chained = first.flatMap(value -> second);
		var caught:String = null;

		chained.catchError(message -> caught = message);
		first.__resolve(1);
		second.__fail("the second step failed", null);

		Assert.equals("the second step failed", caught);
	}

	public function testFlatMapRefusesAContinuationThatReturnsNothing():Void {
		var first = new Future<Int>();
		var chained = first.flatMap(function(value:Int):Future<String> {
			return null;
		});
		var caught:String = null;

		chained.catchError(message -> caught = message);
		first.__resolve(1);

		Assert.notNull(caught, "a null continuation left the chain pending forever");
	}

	public function testAllResolvesInTheOrderGiven():Void {
		var a = new Future<Int>();
		var b = new Future<Int>();
		var c = new Future<Int>();
		var got:Array<Int> = null;

		Future.all([a, b, c]).then(values -> got = values);

		// Deliberately out of order: the caller matches results against the
		// inputs they passed, not against whichever finished first.
		b.__resolve(2);
		c.__resolve(3);
		Assert.isNull(got, "all resolved before every future had");

		a.__resolve(1);
		Assert.same([1, 2, 3], got);
	}

	public function testAllFailsOnTheFirstFailure():Void {
		var a = new Future<Int>();
		var b = new Future<Int>();
		var caught:String = null;
		var resolved = false;

		Future.all([a, b]).then(_ -> resolved = true, message -> caught = message);

		b.__fail("b failed", null);
		a.__resolve(1);

		Assert.equals("b failed", caught);
		Assert.isFalse(resolved, "all resolved after one of its futures failed");
	}

	public function testAllOfNothingResolvesImmediately():Void {
		var got:Array<Int> = null;
		Future.all([]).then(values -> got = values);

		Require.notNull(got, "waiting for nothing never finished");
		Assert.equals(0, got.length);
	}

	#if (cpp || neko || hl || java || jvm)
	/**
		Handlers attached on one thread while another resolves.

		This is the ordinary way to use a future -- finish it on a worker, read
		it on the runtime thread -- and before `Future` took a lock it was
		unsafe in the worst way. `then` pushes onto a handler array while
		resolution walks that same array, and a push that has to grow it frees
		the buffer the walk is still reading. The symptom is not a lost
		callback; it is heap corruption, surfacing later and somewhere else as a
		collector crash on a pointer that was never an object.

		The functional claim is the observable half: every handler runs exactly
		once, whether it was attached before the resolution or after it.
	**/
	public function testHandlersMayBeAttachedWhileAnotherThreadResolves():Void {
		var attachedPerRound:Int = 40;
		var rounds:Int = 60;

		for (round in 0...rounds) {
			var future = new Future<Int>();
			var finished = new sys.thread.Deque<Int>();
			var start = new sys.thread.Lock();

			// A plain counter under a mutex rather than a Deque of results:
			// `Deque<Int>.pop(false)` cannot signal "empty" as null on a static
			// target, so draining one in a loop never terminates there.
			var guard = new sys.thread.Mutex();
			var fired:Int = 0;
			var wrongValue:Int = 0;

			sys.thread.Thread.create(function():Void {
				// Both threads wait on the same gate, so the resolution lands
				// in the middle of the attaching rather than before or after.
				start.wait();
				@:privateAccess future.__resolve(round);
				finished.add(1);
			});

			start.release();

			for (i in 0...attachedPerRound) {
				future.then(function(value:Int):Void {
					guard.acquire();
					fired++;
					if (value != round) {
						wrongValue++;
					}
					guard.release();
				}, _ -> {});
			}

			finished.pop(true);

			guard.acquire();
			var count:Int = fired;
			var wrong:Int = wrongValue;
			guard.release();

			Assert.equals(attachedPerRound, count);
			Assert.equals(0, wrong);
		}
	}
	#end
}
