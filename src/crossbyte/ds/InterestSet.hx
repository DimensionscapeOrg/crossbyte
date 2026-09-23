package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;

/**
 * What came into view and what left it, round to round.
 *
 * Each round -- a tick, for one observer -- add every id in view, however
 * that is decided: a `QuadTree` query, a grid, a line of sight. `commit`
 * then reports what was not in view last round and what no longer is, and
 * the round just gathered becomes the view. It is how a server learns what
 * to spawn and despawn on each client without comparing whole worlds.
 *
 * ```haxe
 * // For each observer, every tick.
 * found.resize(0);
 * world.queryCircle(observer.x, observer.y, VIEW_RADIUS, found);
 * for (node in found) {
 * 	observer.interest.add(node.value.slot);
 * }
 * observer.interest.commit(
 * 	slot -> spawnOn(observer, slot),
 * 	slot -> despawnOn(observer, slot));
 * ```
 *
 * **Ids** are small non-negative integers -- entity slots, say -- held as
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
	// commit, so the list is walked with the bits as the judge.
	private var __view:BitSet;
	private var __viewIds:Array<Int> = [];
	private var __next:BitSet;
	private var __nextIds:Array<Int> = [];

	private var __left:Array<Int> = [];
	private var __entered:Array<Int> = [];
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
			__nextIds.push(id);
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
		__left.resize(0);
		__entered.resize(0);
		for (id in __viewIds) {
			if (__view.get(id) && !__next.get(id)) {
				__left.push(id);
			}
		}
		for (id in __nextIds) {
			if (!__view.get(id)) {
				__entered.push(id);
			}
		}

		// The gathered round becomes the view. The old view's bits are
		// cleared id by id, through its own list, so the cost follows the
		// size of the view and not the highest id ever seen.
		for (id in __viewIds) {
			__view.clear(id);
		}
		var emptied:BitSet = __view;
		__view = __next;
		__next = emptied;

		var emptiedIds:Array<Int> = __viewIds;
		__viewIds = __nextIds;
		__nextIds = emptiedIds;
		__nextIds.resize(0);
		length = __viewIds.length;

		if (left == null && entered == null) {
			return;
		}

		__committing = true;
		try {
			if (left != null) {
				for (id in __left) {
					left(id);
				}
			}
			if (entered != null) {
				for (id in __entered) {
					entered(id);
				}
			}
		} catch (e:haxe.Exception) {
			__committing = false;
			throw e;
		}
		__committing = false;
	}

	/**
	 * Takes `id` out of the committed view without reporting it -- for when
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
		for (id in __viewIds) {
			__view.clear(id);
		}
		for (id in __nextIds) {
			__next.clear(id);
		}
		__viewIds.resize(0);
		__nextIds.resize(0);
		length = 0;
	}

	/**
	 * Iterates the ids in the committed view, in the order they were added.
	 */
	public function iterator():Iterator<Int> {
		return [for (id in __viewIds) if (__view.get(id)) id].iterator();
	}
}
