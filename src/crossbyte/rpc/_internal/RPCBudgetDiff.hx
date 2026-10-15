package crossbyte.rpc._internal;

import crossbyte.ds.IdList;
import crossbyte.errors.ArgumentError;
import crossbyte.rpc.RPCMapBaseline;
import crossbyte.rpc.RPCMapPatch;
import crossbyte.rpc.RPCStringMapBaseline;
import crossbyte.rpc.RPCStringMapPatch;
import crossbyte.rpc._internal.RPCBudget;
import haxe.ds.IntMap;
import haxe.ds.StringMap;

/**
	The budgeted diffs of `RPCMapPatch.diffKeysWithin` and
	`RPCStringMapPatch.diffKeysWithin`, kept apart from the patch classes so
	that their code, which every patch read and applied runs, is laid out as
	it was: written into them, it cost a received tick about 2% natively, in
	code that had not changed.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCMapPatch)
@:access(crossbyte.rpc.RPCStringMapPatch)
@:access(crossbyte.ds.IdList)
class RPCBudgetDiff {
	/** `RPCMapPatch.diffKeysWithin`, into `patch`. **/
	public static function diffKeys<V>(patch:RPCMapPatch<V>, baseValues:Null<IntMap<V>>, base:Null<RPCMapBaseline<V>>, currentValues:IntMap<V>,
			currentKeys:IdList, maxBytes:Int, sent:RPCMapBaseline<V>):Void {
		if (currentValues == null || currentKeys == null) {
			throw new ArgumentError("RPCMapPatch.diffKeysWithin needs the current values and keys.");
		}
		if (sent == null) {
			throw new ArgumentError("RPCMapPatch.diffKeysWithin needs the baseline to write: what the observer holds once this patch arrives.");
		}
		if (maxBytes < 0) {
			throw new ArgumentError('A budget cannot be negative, not $maxBytes.');
		}
		final full:Bool = baseValues == null || base == null;
		if (!full && base.__frame != baseValues) {
			throw new ArgumentError("The base baseline was made against another frame of values: give the frame of the tick it was sent at.");
		}
		var budget:Null<RPCBudget<V>> = patch.__budget;
		if (budget == null) {
			budget = patch.__budget = new RPCBudget<V>();
		}
		budget.deferred.length = 0;
		patch.__sending = true;
		patch.__received = false;
		patch.isFull = full;
		patch.__baseValues = full ? null : baseValues;
		patch.__currentValues = currentValues;
		patch.removed.length = 0;
		patch.__added.length = 0;
		patch.__updated.length = 0;
		patch.__addedMasks.length = 0;
		patch.__addedMasksHigh.length = 0;
		patch.__updatedMasks.length = 0;
		patch.__updatedMasksHigh.length = 0;
		final cur:IdList = patch.__current.copyFrom(currentKeys);
		RPCKeys.sortUnique(cur);

		// diffKeys' walk, against what the observer holds: a key's stale
		// value where it has one, the frame's where not.
		final fromStale:IdList = budget.fromStale;
		fromStale.length = 0;
		final old:Null<IdList> = full ? null : base.__keys;
		final staleKeys:Null<IdList> = full ? null : base.__staleKeys;
		final staleValues:Null<Array<V>> = full ? null : base.__staleValues;
		final wide:Bool = patch.__wide;
		final initial:V = patch.codec.__default();
		final nc:Int = cur.length;
		final no:Int = full ? 0 : old.length;
		final ns:Int = full ? 0 : staleKeys.length;
		var i:Int = 0;
		var j:Int = 0;
		var s:Int = 0;
		while (i < nc || j < no) {
			final c:Int = i < nc ? cur.__ids[i] : 0;
			final o:Int = j < no ? old.__ids[j] : 0;
			if (j >= no || (i < nc && c < o)) {
				final value:Null<V> = currentValues.get(c);
				if (value == null) {
					throw new ArgumentError('RPCMapPatch: key $c is in the current keys and not in the current values.');
				}
				RPCBudget.keep(patch.__sentAdded, patch.__added.length, value);
				patch.__added.push(c);
				patch.__addedMasks.push(patch.codec.__mask(initial, value));
				if (wide) {
					patch.__addedMasksHigh.push(patch.codec.__maskHigh(initial, value));
				}
				i++;
			} else if (i >= nc || o < c) {
				patch.removed.push(o);
				if (s < ns && staleKeys.__ids[s] == o) {
					s++;
				}
				j++;
			} else {
				var from:Int = -1;
				var was:Null<V> = null;
				if (s < ns && staleKeys.__ids[s] == o) {
					from = s;
					was = staleValues[s];
					s++;
				} else {
					was = baseValues.get(o);
				}
				final value:Null<V> = currentValues.get(c);
				if (was == null || value == null) {
					throw new ArgumentError('RPCMapPatch: key $c is in a list of keys and not in its values.');
				}
				final mask:Int = patch.codec.__mask(was, value);
				final high:Int = wide ? patch.codec.__maskHigh(was, value) : 0;
				if (mask != 0 || high != 0) {
					RPCBudget.keep(patch.__sentBase, patch.__updated.length, was);
					RPCBudget.keep(patch.__sentCurrent, patch.__updated.length, value);
					patch.__updated.push(c);
					patch.__updatedMasks.push(mask);
					if (wide) {
						patch.__updatedMasksHigh.push(high);
					}
					fromStale.push(from);
				}
				i++;
				j++;
			}
		}

		// Everything fits when the values' largest patches do: then nothing is
		// weighed, and the patch is diffKeys'.
		final fixed:Int = RPCBudget.varUIntSize((patch.removed.length << 1) | (full ? 1 : 0)) + RPCBudget.keysSize(patch.removed);
		final candidates:Int = patch.__added.length + patch.__updated.length;
		var all:Bool = candidates == 0;
		final each:Int = patch.codec.__patchBound();
		if (!all && each >= 0) {
			final bound:Float = fixed + RPCBudget.varUIntSize(patch.__added.length) + RPCBudget.varUIntSize(patch.__updated.length)
				+ RPCBudget.keysSize(patch.__added) + RPCBudget.keysSize(patch.__updated) + candidates * 1.0 * each;
			all = bound <= maxBytes;
		}
		budget.leftAdds.length = 0;
		budget.staleKeys.length = 0;
		budget.staleFrom.length = 0;
		if (!all) {
			choose(patch, budget, currentKeys, maxBytes - fixed - 2);
		}
		commit(patch, budget, cur, base, sent, currentValues);
	}

	/**
		Weighs the adds and updates in the priority order of `order` against
		`room` bytes (past the head's empty counts and the removals), each
		exactly: its key as its group will code it, the group's count, and its
		patch, sized by the codec without writing it. The first that does not
		fit fills the budget, as a connection's saturation does in Unreal's
		replication: it and everything after it wait, unweighed, so an entry
		never goes ahead of one its caller ranked higher. Then the lists keep
		only what was chosen, and what was left out is noted for the baseline.
	**/
	static function choose<V>(patch:RPCMapPatch<V>, budget:RPCBudget<V>, order:IdList, room:Int):Void {
		final added:IdList = patch.__added;
		final updated:IdList = patch.__updated;
		final addFlags:IdList = budget.addFlags;
		final updateFlags:IdList = budget.updateFlags;
		RPCBudget.zeroes(addFlags, added.length);
		RPCBudget.zeroes(updateFlags, updated.length);
		final adds:RPCKeyRun = budget.adds;
		final updates:RPCKeyRun = budget.updates;
		adds.begin(added);
		updates.begin(updated);
		final deferred:IdList = budget.deferred;
		// The least an entry's patch can be: its mask.
		final least:Int = (patch.codec.fieldCount + 7) >> 3;
		final initial:V = patch.codec.__default();
		var left:Int = room;
		var filled:Bool = false;
		for (p in 0...order.length) {
			final key:Int = order.__ids[p];
			var at:Int = RPCKeys.indexOf(added, key);
			final isAdd:Bool = at >= 0;
			if (!isAdd) {
				at = RPCKeys.indexOf(updated, key);
				if (at < 0) {
					// Held and the same: nothing to carry.
					continue;
				}
			}
			final flags:IdList = isAdd ? addFlags : updateFlags;
			if (flags.__ids[at] != 0) {
				continue;
			}
			flags.__ids[at] = RPCBudget.SEEN;
			if (filled) {
				deferred.push(key);
				continue;
			}
			final run:RPCKeyRun = isAdd ? adds : updates;
			final keyCost:Int = run.cost(at);
			// Measured only when it might fit.
			final cost:Int = keyCost + least > left ? left + 1 : keyCost + measure(patch, initial, isAdd, at);
			if (cost <= left) {
				left -= cost;
				run.choose(at);
				flags.__ids[at] = RPCBudget.SEEN | RPCBudget.CHOSEN;
			} else {
				filled = true;
				deferred.push(key);
			}
		}

		// The adds chosen, in place; those left out noted.
		final wide:Bool = patch.__wide;
		final leftAdds:IdList = budget.leftAdds;
		var w:Int = 0;
		for (a in 0...added.length) {
			if ((addFlags.__ids[a] & RPCBudget.CHOSEN) == 0) {
				leftAdds.push(added.__ids[a]);
				continue;
			}
			added.__ids[w] = added.__ids[a];
			patch.__addedMasks.__ids[w] = patch.__addedMasks.__ids[a];
			if (wide) {
				patch.__addedMasksHigh.__ids[w] = patch.__addedMasksHigh.__ids[a];
			}
			patch.__sentAdded[w] = patch.__sentAdded[a];
			w++;
		}
		added.length = w;
		patch.__addedMasks.length = w;
		if (wide) {
			patch.__addedMasksHigh.length = w;
		}
		// The updates chosen; those left out become the baseline's stale
		// entries, at the value the observer still holds.
		final staleKeys:IdList = budget.staleKeys;
		final staleFrom:IdList = budget.staleFrom;
		final staleSource:Array<V> = budget.staleSource;
		w = 0;
		for (u in 0...updated.length) {
			if ((updateFlags.__ids[u] & RPCBudget.CHOSEN) == 0) {
				RPCBudget.keep(staleSource, staleKeys.length, patch.__sentBase[u]);
				staleKeys.push(updated.__ids[u]);
				staleFrom.push(budget.fromStale.__ids[u]);
				continue;
			}
			updated.__ids[w] = updated.__ids[u];
			patch.__updatedMasks.__ids[w] = patch.__updatedMasks.__ids[u];
			if (wide) {
				patch.__updatedMasksHigh.__ids[w] = patch.__updatedMasksHigh.__ids[u];
			}
			patch.__sentBase[w] = patch.__sentBase[u];
			patch.__sentCurrent[w] = patch.__sentCurrent[u];
			w++;
		}
		updated.length = w;
		patch.__updatedMasks.length = w;
		if (wide) {
			patch.__updatedMasksHigh.length = w;
		}
	}

	/**
		The bytes the `at`-th add (or update) takes past its key: its patch,
		as the codec's generated size of it says, exactly what it writes.
	**/
	static inline function measure<V>(patch:RPCMapPatch<V>, initial:V, isAdd:Bool, at:Int):Int {
		final wide:Bool = patch.__wide;
		return isAdd ? patch.codec.__patchSize(initial, patch.__sentAdded[at], patch.__addedMasks.__ids[at], wide ? patch.__addedMasksHigh.__ids[at] : 0,
			-1) : patch.codec.__patchSize(patch.__sentBase[at], patch.__sentCurrent[at], patch.__updatedMasks.__ids[at],
				wide ? patch.__updatedMasksHigh.__ids[at] : 0, -1);
	}

	/**
		Writes into `sent` what the observer holds once the patch arrives:
		the view's keys but the adds left out, and a copy of the base value of
		each update left out. Into the base itself, a stale value that stays
		stale is kept where it is.
	**/
	static function commit<V>(patch:RPCMapPatch<V>, budget:RPCBudget<V>, cur:IdList, base:Null<RPCMapBaseline<V>>, sent:RPCMapBaseline<V>,
			currentValues:IntMap<V>):Void {
		// The keys: the view's, less the adds left out (both ascending).
		final keys:IdList = sent.__keys;
		final leftAdds:IdList = budget.leftAdds;
		if (leftAdds.length == 0) {
			keys.copyFrom(cur);
		} else {
			keys.length = 0;
			var l:Int = 0;
			for (k in 0...cur.length) {
				final key:Int = cur.__ids[k];
				if (l < leftAdds.length && leftAdds.__ids[l] == key) {
					l++;
				} else {
					keys.push(key);
				}
			}
		}
		// The stale values. What `sent` held that it keeps: in place, a value
		// staying stale under its key. The rest is kept for the values to come.
		final staleKeys:IdList = budget.staleKeys;
		final staleFrom:IdList = budget.staleFrom;
		final count:Int = staleKeys.length;
		final inPlace:Bool = sent == base;
		final held:Array<V> = sent.__staleValues;
		final heldCount:Int = sent.__staleKeys.length;
		if (count == 0) {
			for (h in 0...heldCount) {
				sent.__keep(held[h]);
				held[h] = null;
			}
			sent.__staleKeys.length = 0;
			sent.__frame = currentValues;
			return;
		}
		final kept:IdList = budget.kept;
		RPCBudget.zeroes(kept, heldCount);
		if (inPlace) {
			for (e in 0...count) {
				final from:Int = staleFrom.__ids[e];
				if (from >= 0) {
					kept.__ids[from] = 1;
				}
			}
		}
		for (h in 0...heldCount) {
			if (kept.__ids[h] == 0) {
				sent.__keep(held[h]);
			}
		}
		final source:Array<V> = budget.staleSource;
		final made:Array<V> = budget.staleMade;
		for (e in 0...count) {
			final from:Int = staleFrom.__ids[e];
			if (inPlace && from >= 0) {
				RPCBudget.keep(made, e, held[from]);
			} else {
				final value:V = sent.__take(patch.codec);
				patch.codec.copy(source[e], value);
				RPCBudget.keep(made, e, value);
			}
		}
		sent.__staleKeys.copyFrom(staleKeys);
		for (e in 0...count) {
			RPCBudget.keep(held, e, made[e]);
		}
		for (e in count...held.length) {
			held[e] = null;
		}
		sent.__frame = currentValues;
	}

	/** `RPCStringMapPatch.diffKeysWithin`, into `patch`. **/
	public static function diffStringKeys<V>(patch:RPCStringMapPatch<V>, baseValues:Null<StringMap<V>>, base:Null<RPCStringMapBaseline<V>>,
			currentValues:StringMap<V>, currentKeys:Array<String>, maxBytes:Int, sent:RPCStringMapBaseline<V>):Void {
		if (currentValues == null || currentKeys == null) {
			throw new ArgumentError("RPCStringMapPatch.diffKeysWithin needs the current values and keys.");
		}
		if (sent == null) {
			throw new ArgumentError("RPCStringMapPatch.diffKeysWithin needs the baseline to write: what the observer holds once this patch arrives.");
		}
		if (maxBytes < 0) {
			throw new ArgumentError('A budget cannot be negative, not $maxBytes.');
		}
		final full:Bool = baseValues == null || base == null;
		if (!full && base.__frame != baseValues) {
			throw new ArgumentError("The base baseline was made against another frame of values: give the frame of the tick it was sent at.");
		}
		var budget:Null<RPCBudget<V>> = patch.__budget;
		if (budget == null) {
			budget = patch.__budget = new RPCBudget<V>();
		}
		budget.deferredStrings.resize(0);
		patch.__sending = true;
		patch.__received = false;
		patch.isFull = full;
		patch.__baseValues = full ? null : baseValues;
		patch.__currentValues = currentValues;
		patch.removed.resize(0);
		patch.__added.resize(0);
		patch.__updated.resize(0);
		patch.__addedMasks.length = 0;
		patch.__addedMasksHigh.length = 0;
		patch.__updatedMasks.length = 0;
		patch.__updatedMasksHigh.length = 0;
		final cur:Array<String> = RPCStringMapPatch.__copy(currentKeys, patch.__current);
		RPCKeys.sortUniqueStrings(cur);

		// diffKeys' walk, against what the observer holds.
		final fromStale:IdList = budget.fromStale;
		fromStale.length = 0;
		final old:Null<Array<String>> = full ? null : base.__keys;
		final staleKeys:Null<Array<String>> = full ? null : base.__staleKeys;
		final staleValues:Null<Array<V>> = full ? null : base.__staleValues;
		final wide:Bool = patch.__wide;
		final initial:V = patch.codec.__default();
		final nc:Int = cur.length;
		final no:Int = full ? 0 : old.length;
		final ns:Int = full ? 0 : staleKeys.length;
		var i:Int = 0;
		var j:Int = 0;
		var s:Int = 0;
		while (i < nc || j < no) {
			final c:Null<String> = i < nc ? cur[i] : null;
			final o:Null<String> = j < no ? old[j] : null;
			if (j >= no || (i < nc && RPCMaps.before(c, o))) {
				final value:Null<V> = currentValues.get(c);
				if (value == null) {
					throw new ArgumentError('RPCStringMapPatch: key "$c" is in the current keys and not in the current values.');
				}
				RPCBudget.keep(patch.__sentAdded, patch.__added.length, value);
				patch.__added.push(c);
				patch.__addedMasks.push(patch.codec.__mask(initial, value));
				if (wide) {
					patch.__addedMasksHigh.push(patch.codec.__maskHigh(initial, value));
				}
				i++;
			} else if (i >= nc || RPCMaps.before(o, c)) {
				patch.removed.push(o);
				if (s < ns && staleKeys[s] == o) {
					s++;
				}
				j++;
			} else {
				var from:Int = -1;
				var was:Null<V> = null;
				if (s < ns && staleKeys[s] == o) {
					from = s;
					was = staleValues[s];
					s++;
				} else {
					was = baseValues.get(o);
				}
				final value:Null<V> = currentValues.get(c);
				if (was == null || value == null) {
					throw new ArgumentError('RPCStringMapPatch: key "$c" is in a list of keys and not in its values.');
				}
				final mask:Int = patch.codec.__mask(was, value);
				final high:Int = wide ? patch.codec.__maskHigh(was, value) : 0;
				if (mask != 0 || high != 0) {
					RPCBudget.keep(patch.__sentBase, patch.__updated.length, was);
					RPCBudget.keep(patch.__sentCurrent, patch.__updated.length, value);
					patch.__updated.push(c);
					patch.__updatedMasks.push(mask);
					if (wide) {
						patch.__updatedMasksHigh.push(high);
					}
					fromStale.push(from);
				}
				i++;
				j++;
			}
		}

		// The head with no entries (two counts of 0, a byte each), and the
		// removed keys: what any budget carries.
		var fixed:Int = RPCSizes.varUInt((patch.removed.length << 1) | (full ? 1 : 0)) + 2;
		for (key in patch.removed) {
			fixed += RPCSizes.string(key);
		}
		final candidates:Int = patch.__added.length + patch.__updated.length;
		var all:Bool = candidates == 0;
		final each:Int = patch.codec.__patchBound();
		if (!all && each >= 0) {
			// Every key whole: its count, and at most three bytes a character.
			var keys:Float = 0.0;
			for (key in patch.__added) {
				keys += 5 + key.length * 3;
			}
			for (key in patch.__updated) {
				keys += 5 + key.length * 3;
			}
			final bound:Float = fixed - 2 + RPCBudget.varUIntSize(patch.__added.length) + RPCBudget.varUIntSize(patch.__updated.length) + keys
				+ candidates * 1.0 * each;
			all = bound <= maxBytes;
		}
		budget.leftAddStrings.resize(0);
		budget.staleStrings.resize(0);
		budget.staleFrom.length = 0;
		if (!all) {
			chooseStrings(patch, budget, currentKeys, maxBytes - fixed);
		}
		commitStrings(patch, budget, cur, base, sent, currentValues);
	}

	/**
		As `choose`: the entries weighed in the order of `order` against
		`room`, each by its size, until one does not fit; the lists kept to
		those chosen.
	**/
	static function chooseStrings<V>(patch:RPCStringMapPatch<V>, budget:RPCBudget<V>, order:Array<String>, room:Int):Void {
		final added:Array<String> = patch.__added;
		final updated:Array<String> = patch.__updated;
		final addFlags:IdList = budget.addFlags;
		final updateFlags:IdList = budget.updateFlags;
		RPCBudget.zeroes(addFlags, added.length);
		RPCBudget.zeroes(updateFlags, updated.length);
		final deferred:Array<String> = budget.deferredStrings;
		// The least an entry can be: a key of no characters and its mask.
		final least:Int = 1 + ((patch.codec.fieldCount + 7) >> 3);
		final initial:V = patch.codec.__default();
		var adds:Int = 0;
		var updates:Int = 0;
		var left:Int = room;
		var filled:Bool = false;
		for (key in order) {
			var at:Int = RPCKeys.indexOfString(added, key);
			final isAdd:Bool = at >= 0;
			if (!isAdd) {
				at = RPCKeys.indexOfString(updated, key);
				if (at < 0) {
					continue;
				}
			}
			final flags:IdList = isAdd ? addFlags : updateFlags;
			if (flags.__ids[at] != 0) {
				continue;
			}
			flags.__ids[at] = RPCBudget.SEEN;
			if (filled) {
				deferred.push(key);
				continue;
			}
			final count:Int = isAdd ? adds : updates;
			final head:Int = RPCBudget.varUIntSize(count + 1) - RPCBudget.varUIntSize(count);
			final cost:Int = head + least > left ? left + 1 : head + measureStrings(patch, initial, isAdd, at);
			if (cost <= left) {
				left -= cost;
				if (isAdd) {
					adds++;
				} else {
					updates++;
				}
				flags.__ids[at] = RPCBudget.SEEN | RPCBudget.CHOSEN;
			} else {
				filled = true;
				deferred.push(key);
			}
		}

		final wide:Bool = patch.__wide;
		final leftAdds:Array<String> = budget.leftAddStrings;
		var w:Int = 0;
		for (a in 0...added.length) {
			if ((addFlags.__ids[a] & RPCBudget.CHOSEN) == 0) {
				leftAdds.push(added[a]);
				continue;
			}
			added[w] = added[a];
			patch.__addedMasks.__ids[w] = patch.__addedMasks.__ids[a];
			if (wide) {
				patch.__addedMasksHigh.__ids[w] = patch.__addedMasksHigh.__ids[a];
			}
			patch.__sentAdded[w] = patch.__sentAdded[a];
			w++;
		}
		added.resize(w);
		patch.__addedMasks.length = w;
		if (wide) {
			patch.__addedMasksHigh.length = w;
		}
		final staleKeys:Array<String> = budget.staleStrings;
		final staleFrom:IdList = budget.staleFrom;
		final staleSource:Array<V> = budget.staleSource;
		w = 0;
		for (u in 0...updated.length) {
			if ((updateFlags.__ids[u] & RPCBudget.CHOSEN) == 0) {
				RPCBudget.keep(staleSource, staleKeys.length, patch.__sentBase[u]);
				staleKeys.push(updated[u]);
				staleFrom.push(budget.fromStale.__ids[u]);
				continue;
			}
			updated[w] = updated[u];
			patch.__updatedMasks.__ids[w] = patch.__updatedMasks.__ids[u];
			if (wide) {
				patch.__updatedMasksHigh.__ids[w] = patch.__updatedMasksHigh.__ids[u];
			}
			patch.__sentBase[w] = patch.__sentBase[u];
			patch.__sentCurrent[w] = patch.__sentCurrent[u];
			w++;
		}
		updated.resize(w);
		patch.__updatedMasks.length = w;
		if (wide) {
			patch.__updatedMasksHigh.length = w;
		}
	}

	/** The bytes the `at`-th add (or update) takes, its key included, as the codec's generated size of its patch says. **/
	static inline function measureStrings<V>(patch:RPCStringMapPatch<V>, initial:V, isAdd:Bool, at:Int):Int {
		final wide:Bool = patch.__wide;
		return isAdd ? RPCSizes.string(patch.__added[at])
			+ patch.codec.__patchSize(initial, patch.__sentAdded[at], patch.__addedMasks.__ids[at], wide ? patch.__addedMasksHigh.__ids[at] : 0,
				-1) : RPCSizes.string(patch.__updated[at])
			+ patch.codec.__patchSize(patch.__sentBase[at], patch.__sentCurrent[at], patch.__updatedMasks.__ids[at],
				wide ? patch.__updatedMasksHigh.__ids[at] : 0, -1);
	}

	/** As `commit`: into `sent` what the observer holds once the patch arrives. **/
	static function commitStrings<V>(patch:RPCStringMapPatch<V>, budget:RPCBudget<V>, cur:Array<String>, base:Null<RPCStringMapBaseline<V>>,
			sent:RPCStringMapBaseline<V>, currentValues:StringMap<V>):Void {
		final keys:Array<String> = sent.__keys;
		final leftAdds:Array<String> = budget.leftAddStrings;
		if (leftAdds.length == 0) {
			RPCStringMapPatch.__copy(cur, keys);
		} else {
			keys.resize(0);
			var l:Int = 0;
			for (key in cur) {
				if (l < leftAdds.length && leftAdds[l] == key) {
					l++;
				} else {
					keys.push(key);
				}
			}
		}
		final staleKeys:Array<String> = budget.staleStrings;
		final staleFrom:IdList = budget.staleFrom;
		final count:Int = staleKeys.length;
		final inPlace:Bool = sent == base;
		final held:Array<V> = sent.__staleValues;
		final heldCount:Int = sent.__staleKeys.length;
		if (count == 0) {
			for (h in 0...heldCount) {
				sent.__keep(held[h]);
				held[h] = null;
			}
			sent.__staleKeys.resize(0);
			sent.__frame = currentValues;
			return;
		}
		final kept:IdList = budget.kept;
		RPCBudget.zeroes(kept, heldCount);
		if (inPlace) {
			for (e in 0...count) {
				final from:Int = staleFrom.__ids[e];
				if (from >= 0) {
					kept.__ids[from] = 1;
				}
			}
		}
		for (h in 0...heldCount) {
			if (kept.__ids[h] == 0) {
				sent.__keep(held[h]);
			}
		}
		final source:Array<V> = budget.staleSource;
		final made:Array<V> = budget.staleMade;
		for (e in 0...count) {
			final from:Int = staleFrom.__ids[e];
			if (inPlace && from >= 0) {
				RPCBudget.keep(made, e, held[from]);
			} else {
				final value:V = sent.__take(patch.codec);
				patch.codec.copy(source[e], value);
				RPCBudget.keep(made, e, value);
			}
		}
		RPCStringMapPatch.__copy(staleKeys, sent.__staleKeys);
		for (e in 0...count) {
			RPCBudget.keep(held, e, made[e]);
		}
		for (e in count...held.length) {
			held[e] = null;
		}
		sent.__frame = currentValues;
	}
}
