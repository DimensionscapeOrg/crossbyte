package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import haxe.ds.Vector;

/**
 * What came into view and what left it, round to round.
 *
 * Each round, a tick, for one observer, add every id in view, however
 * that is decided: a `SpatialGrid` or `QuadTree` query, a line of sight.
 * `commit` then reports what was not in view last round and what no longer
 * is, and the round just gathered becomes the view. It is how a server
 * learns what to spawn and despawn on each client without comparing whole
 * worlds.
 *
 * ```haxe
 * // For each observer, every tick.
 * found.clear();
 * grid.queryCircleIds(observer.x, observer.y, VIEW_RADIUS, found);
 * observer.interest.addAll(found);
 * observer.interest.commit(observer.spawn, observer.despawn);
 * ```
 *
 * Nothing here allocates once it has grown to its views, on any target: the
 * lists it keeps are unboxed and keep their storage from round to round,
 * and `found`, an `IdList`, is the same. Kept in `Array<Int>`s, 1,000 views
 * of 50 cost 2.2 MB a tick on the jvm and Node, every id above 127 boxed
 * on the jvm, and every emptied array's store handed back to V8. Callbacks
 * made once, as `spawn` and `despawn` are above, rather than closures made
 * at each commit, keep it that way.
 *
 * **Ids** are small non-negative integers, entity slots, say, held as
 * bits, so an observer costs two bits per possible id. What a round costs
 * is proportional to the views, not to the largest id.
 *
 * **A reused id is not a change.** If the thing behind an id is destroyed
 * and something new takes the id before the next commit, both rounds show
 * the id in view and nothing is reported. Report the old one's departure
 * yourself when it is destroyed, and `forget` the id: the new one is then
 * reported as entering.
 *
 * **Threading.** None.
 */
final class InterestSet {
	/**
	 * Ids in the committed view.
	 */
	public var length(default, null):Int = 0;

	// The committed view, and the round being gathered, each as bits to
	// answer "is it in" and as a list to walk without visiting every bit.
	// A forgotten id leaves the view's bits at once and its list at the next
	// commit, so the list is walked with the bits as the judge. The lists are
	// vectors with counts, emptied by resetting the count.
	private var __view:BitSet;
	private var __viewIds:Vector<Int>;
	private var __viewCount:Int = 0;
	private var __next:BitSet;
	private var __nextIds:Vector<Int>;
	private var __nextCount:Int = 0;

	private var __left:Vector<Int>;
	private var __leftCount:Int = 0;
	private var __entered:Vector<Int>;
	private var __enteredCount:Int = 0;
	private var __committing:Bool = false;

	/**
	 * @param capacity Ids to make room for at the start; either set grows to
	 *        fit a larger one when it is added.
	 */
	public function new(capacity:Int = 64) {
		if (capacity < 0) {
			throw new ArgumentError("capacity cannot be negative.");
		}
		__view = new BitSet(capacity);
		__next = new BitSet(capacity);
		// Filled, so V8 holds them as packed arrays rather than holey ones.
		__viewIds = new Vector<Int>(16, 0);
		__nextIds = new Vector<Int>(16, 0);
		__left = new Vector<Int>(16, 0);
		__entered = new Vector<Int>(16, 0);
	}

	/**
	 * Adds `id` to the round being gathered. Adding it twice in one round is
	 * the same as adding it once.
	 */
	public function add(id:Int):Void {
		if (id < 0) {
			throw new ArgumentError("An id cannot be negative.");
		}
		if (!__next.get(id)) {
			__next.set(id, true);
			if (__nextCount == __nextIds.length) {
				__nextIds = __grown(__nextIds, __nextCount);
			}
			__nextIds[__nextCount++] = id;
		}
	}

	/**
	 * Adds every id in `ids` to the round being gathered, as `add` does each.
	 */
	public function addAll(ids:IdList):Void {
		for (id in ids) {
			add(id);
		}
	}

	/**
	 * Whether `id` is in the committed view: the last round committed, not
	 * the one being gathered.
	 */
	public function has(id:Int):Bool {
		return id >= 0 && __view.get(id);
	}

	/**
	 * Ends the round. Reports every id that left the view, then every id
	 * that entered it, each in the order it was added; the round just
	 * gathered becomes the view, and the next round starts empty.
	 *
	 * The view has already moved on when the callbacks run, so `has` answers
	 * for the new one, and an `add` from inside a callback goes into the
	 * next round. A callback that throws ends that commit's reports there:
	 * the exception reaches the caller, and the ids not yet reported are not
	 * reported later.
	 *
	 * @throws IllegalOperationError If called from inside its own callback.
	 */
	public function commit(?entered:Int->Void, ?left:Int->Void):Void {
		if (__committing) {
			throw new IllegalOperationError("commit() was called from inside one of its own callbacks.");
		}

		// Both lists before anything moves, judged by the bits as they stand.
		// Each can hold at most the list it is drawn from.
		if (__left.length < __viewCount) {
			__left = __roomFor(__viewCount, __left.length);
		}
		if (__entered.length < __nextCount) {
			__entered = __roomFor(__nextCount, __entered.length);
		}
		__leftCount = 0;
		__enteredCount = 0;
		for (i in 0...__viewCount) {
			var id:Int = __viewIds[i];
			if (__view.get(id) && !__next.get(id)) {
				__left[__leftCount++] = id;
			}
		}
		for (i in 0...__nextCount) {
			var id:Int = __nextIds[i];
			if (!__view.get(id)) {
				__entered[__enteredCount++] = id;
			}
		}

		// The gathered round becomes the view. The old view's bits are
		// cleared id by id, through its own list, so the cost follows the
		// size of the view and not the highest id ever seen.
		for (i in 0...__viewCount) {
			__view.clear(__viewIds[i]);
		}
		var emptied:BitSet = __view;
		__view = __next;
		__next = emptied;

		var emptiedIds:Vector<Int> = __viewIds;
		__viewIds = __nextIds;
		__viewCount = __nextCount;
		__nextIds = emptiedIds;
		__nextCount = 0;
		length = __viewCount;

		if (left == null && entered == null) {
			return;
		}

		__committing = true;
		try {
			if (left != null) {
				for (i in 0...__leftCount) {
					left(__left[i]);
				}
			}
			if (entered != null) {
				for (i in 0...__enteredCount) {
					entered(__entered[i]);
				}
			}
		} catch (e:haxe.Exception) {
			__committing = false;
			throw e;
		}
		__committing = false;
	}

	/**
	 * Takes `id` out of the committed view without reporting it, for when
	 * the thing behind it was destroyed or replaced, and its departure has
	 * been said already. If the id is in view at the next commit, it is
	 * reported as entering.
	 *
	 * @return `true` if `id` was in the view.
	 */
	public function forget(id:Int):Bool {
		if (!has(id)) {
			return false;
		}
		__view.clear(id);
		length--;
		return true;
	}

	/**
	 * Forgets the committed view and the round being gathered, reporting
	 * nothing. At the next commit, everything added is reported as entering.
	 */
	public function clear():Void {
		for (i in 0...__viewCount) {
			__view.clear(__viewIds[i]);
		}
		for (i in 0...__nextCount) {
			__next.clear(__nextIds[i]);
		}
		__viewCount = 0;
		__nextCount = 0;
		length = 0;
	}

	/**
	 * Iterates the ids in the committed view, in the order they were added.
	 *
	 * It reads the view as it goes rather than a copy, so a `for` loop over
	 * it allocates nothing; an id forgotten before the loop reaches it is
	 * skipped, and a `commit` or `clear` inside the loop ends what it walks.
	 */
	public inline function iterator():InterestSetIterator {
		return new InterestSetIterator(this);
	}

	// The first position from `i` on whose id is still in the view.
	@:noCompletion private function __stillInView(i:Int):Int {
		while (i < __viewCount && !__view.get(__viewIds[i])) {
			i++;
		}
		return i;
	}

	// Doubling, so a view that keeps growing reallocates a few times rather
	// than at every new largest round.
	private static function __roomFor(needed:Int, had:Int):Vector<Int> {
		var size:Int = had * 2;
		return new Vector<Int>(size < needed ? needed : size, 0);
	}

	private static function __grown(ids:Vector<Int>, count:Int):Vector<Int> {
		var grown:Vector<Int> = new Vector<Int>(ids.length * 2, 0);
		Vector.blit(ids, 0, grown, 0, count);
		return grown;
	}
}

/**
 * Walks the committed view of an `InterestSet`. Made by
 * `InterestSet.iterator()`; a `for` loop over the set is the usual way to use
 * one.
 */
@:access(crossbyte.ds.InterestSet)
class InterestSetIterator {
	private var __set:InterestSet;
	private var __at:Int;

	public inline function new(set:InterestSet) {
		__set = set;
		__at = set.__stillInView(0);
	}

	public inline function hasNext():Bool {
		return __at < __set.__viewCount;
	}

	public inline function next():Int {
		var id:Int = __set.__viewIds[__at];
		__at = __set.__stillInView(__at + 1);
		return id;
	}
}
