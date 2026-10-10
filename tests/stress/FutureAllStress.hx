package stress;

import crossbyte.Completer;
import crossbyte.Future;
import sys.thread.Lock;
import sys.thread.Thread;

/**
 * Completes every input of a `Future.all` at once, each on its own thread.
 *
 * Invariant: once every input has completed, the joined future has resolved,
 * with each input's value at that input's index.
 *
 * `all` counts down the inputs still to come in a handler each input runs,
 * on the thread that completes it. A count kept outside the joined future's
 * lock lost decrements when two inputs completed together, and the joined
 * future then never resolved, every input completed and nothing to say
 * why: 1 to 31 of 4,000 joins in each of 20 runs, natively and on the jvm.
 * A future completed by one worker and read by another is what `Future` is
 * for, so `all` over the work of several is its ordinary use.
 */
@:access(crossbyte.Future)
class FutureAllStress implements StressCase {
	private static inline final INPUTS:Int = 8;
	private static inline final JOINS:Int = 8000;

	public function new() {}

	public function run():StressResult {
		// One thread per input, kept for the whole run and released together
		// for each join, so the completions land as close together as the
		// scheduler allows: a thread made per join would start too late to
		// race the others.
		var go:Array<Lock> = [for (i in 0...INPUTS) new Lock()];
		var done:Lock = new Lock();
		var current:Array<Completer<Int>> = [];
		var stop:Bool = false;

		for (i in 0...INPUTS) {
			var index:Int = i;
			Thread.create(function() {
				while (true) {
					go[index].wait();
					if (stop) {
						done.release();
						return;
					}
					current[index].complete(index * 10);
					done.release();
				}
			});
		}

		var unresolved:Int = 0;
		var wrong:Int = 0;
		for (join in 0...JOINS) {
			current = [for (i in 0...INPUTS) new Completer<Int>()];
			var joined:Future<Array<Int>> = Future.all([for (completer in current) completer.future]);

			for (i in 0...INPUTS) {
				go[i].release();
			}
			for (i in 0...INPUTS) {
				done.wait();
			}

			// Every input has completed and every handler has returned.
			if (joined.__stateNow() != 1) {
				unresolved++;
			} else {
				var values:Array<Int> = joined.result;
				for (i in 0...INPUTS) {
					if (values[i] != i * 10) {
						wrong++;
						break;
					}
				}
			}
		}

		stop = true;
		for (i in 0...INPUTS) {
			go[i].release();
		}
		for (i in 0...INPUTS) {
			done.wait();
		}

		return {
			name: "Future.all completed from several threads",
			passed: unresolved == 0 && wrong == 0,
			details: [
				'joins=$JOINS inputs=$INPUTS, each completed on its own thread',
				'never resolved=$unresolved (expected 0)',
				'resolved with a wrong value=$wrong (expected 0)'
			]
		};
	}
}
