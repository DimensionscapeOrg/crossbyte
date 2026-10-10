package stress;

import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Reads category levels on several threads while another sets them.
 *
 * Invariant: a category whose level never changes always reads as that
 * level, and no read throws or brings the process down.
 *
 * `Logger.setLevel` is how an operator quiets a category while a server
 * runs, and every runtime's thread reads the levels as it logs, `LogCategory`
 * after each change. The levels are a map, and a map read while another
 * thread grows it is not safe: unguarded, a lookup during a resize crashed
 * the process natively in 3 runs of 3, and on the jvm read a level that
 * never changed as another, once a run.
 */
class LogLevelsStress implements StressCase {
	private static inline final READERS:Int = 3;
	private static inline final ROUNDS:Int = 100;
	private static inline final NAMES:Int = 300;

	public function new() {}

	public function run():StressResult {
		Logger.setLevel("stress.fixed", LogLevel.ERROR);

		var guard:Mutex = new Mutex();
		var stop:Bool = false;
		var reads:Int = 0;
		var wrong:Int = 0;
		var thrown:Int = 0;
		var done:Lock = new Lock();

		for (r in 0...READERS) {
			Thread.create(function() {
				var mine:Int = 0;
				var mineWrong:Int = 0;
				var mineThrown:Int = 0;
				while (true) {
					guard.acquire();
					var stopping:Bool = stop;
					guard.release();
					if (stopping) {
						break;
					}
					try {
						if (Logger.levelOf("stress.fixed.sub" + (mine & 7)) != LogLevel.ERROR) {
							mineWrong++;
						}
						// A name the writer is setting and clearing, so the
						// lookups land on the map while it grows and shrinks.
						Logger.levelOf("stress.w" + (mine % NAMES) + ".x");
					} catch (e:Dynamic) {
						mineThrown++;
					}
					mine++;
				}
				guard.acquire();
				reads += mine;
				wrong += mineWrong;
				thrown += mineThrown;
				guard.release();
				done.release();
			});
		}

		for (round in 0...ROUNDS) {
			for (i in 0...NAMES) {
				Logger.setLevel("stress.w" + i, LogLevel.DEBUG);
			}
			for (i in 0...NAMES) {
				Logger.setLevel("stress.w" + i, null);
			}
		}

		guard.acquire();
		stop = true;
		guard.release();
		for (r in 0...READERS) {
			done.wait();
		}
		Logger.setLevel("stress.fixed", null);

		return {
			name: "Category levels read while set",
			passed: wrong == 0 && thrown == 0,
			details: [
				'readers=$READERS writes=${ROUNDS * NAMES * 2} reads=$reads',
				'a fixed level read as another=$wrong (expected 0)',
				'reads that threw=$thrown (expected 0)'
			]
		};
	}
}
