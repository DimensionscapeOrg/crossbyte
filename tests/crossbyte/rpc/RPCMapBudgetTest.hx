package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.ds.SequenceRing;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.utils.Hash;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
	Map patches within a budget: entries carried in the caller's order of
	priority until the patch is a given size, the rest left out and owed,
	and a baseline recording what the observer holds once the patch
	arrives, which the next patch is diffed against.
**/
class RPCMapBudgetTest extends utest.Test {
	public function testABudgetThatFitsEverythingIsTheUnbudgetedPatch():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final plain = new RPCMapPatch(codec);
		final within = new RPCMapPatch(codec);
		final random = new Random(11);
		var differ:Int = 0;
		var tight:Int = 0;
		for (round in 0...150) {
			final c = Case.random(random, round % 7 == 0);
			final expected:String = hexOf(plain.diffKeys(c.full ? null : c.baseValues, c.full ? null : c.baseKeys, c.values, c.keys));
			// Far more room than it needs: everything, measuring nothing.
			final sent = new RPCMapBaseline<BudgetShip>();
			within.diffKeysWithin(c.full ? null : c.baseValues, c.full ? null : c.base, c.values, c.keys, 1 << 20, sent);
			if (hexOf(within) != expected || within.isPartial || sent.staleCount != 0 || !holdsExactly(sent, c.keys)) {
				differ++;
			}
			// Exactly its size, which every entry has to be weighed to find:
			// still everything.
			final size:Int = Std.int(expected.length / 2);
			within.diffKeysWithin(c.full ? null : c.baseValues, c.full ? null : c.base, c.values, c.keys, size, new RPCMapBaseline());
			if (hexOf(within) != expected || within.isPartial) {
				tight++;
			}
		}
		Assert.equals(0, differ, "a budget that fits everything did not write diffKeys' bytes");
		Assert.equals(0, tight, "a budget of exactly the patch's size left something out");
	}

	public function testABudgetCarriesTheFirstThatFitAndListsTheRest():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final world = new IntMap<BudgetShip>();
		for (key in 1...11) {
			world.set(key, ship(key, key, 1));
		}
		// Nearest first: 7, 2, 9, ... Every entry is added from nothing: a key
		// of a byte, a mask, two floats and a byte, 11 bytes; the head 3.
		final order = ids([7, 2, 9, 4, 1, 10, 3, 8, 6, 5]);
		final patch = new RPCMapPatch(codec);
		final sent = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(null, null, world, order, 3 + 3 * 11, sent);
		Assert.isTrue(patch.isFull);
		Assert.isTrue(patch.isPartial);
		Assert.equals(3, patch.addedCount);
		Assert.equals("2,7,9", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.equals("4,1,10,3,8,6,5", patch.deferred.toArray().join(","));
		Assert.equals(3 + 3 * 11, bytesOf(patch).length);
		// The observer holds what was carried, and nothing else.
		Assert.equals("2,7,9", [for (i in 0...sent.length) sent.keyAt(i)].join(","));
		Assert.isFalse(sent.has(4));
		// Room for one whole entry and a little: the second does not fit, and
		// fills the budget. The third, smaller, waits behind it rather than
		// go ahead of an entry ranked higher.
		final small = new IntMap<BudgetShip>();
		small.set(1, ship(1, 1, 1));
		small.set(2, ship(2, 2, 1));
		small.set(3, new BudgetShip()); // the default: only its key and mask
		patch.diffKeysWithin(null, null, small, ids([1, 2, 3]), 3 + 11 + 5, new RPCMapBaseline());
		Assert.equals("1", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.equals("2,3", patch.deferred.toArray().join(","));
		patch.diffKeysWithin(null, null, small, ids([1, 3, 2]), 3 + 11 + 5, new RPCMapBaseline());
		Assert.equals("1,3", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.equals("2", patch.deferred.toArray().join(","));
		// A key given twice counts where it first is.
		patch.diffKeysWithin(null, null, small, ids([3, 1, 3, 2, 1]), 1 << 10, new RPCMapBaseline());
		Assert.isFalse(patch.isPartial);
		Assert.equals(3, patch.addedCount);
		patch.diffKeysWithin(null, null, small, ids([1, 2, 2, 3, 1]), 3 + 11 + 2, new RPCMapBaseline());
		Assert.equals("1", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.equals("2,3", patch.deferred.toArray().join(","), "a key left out is listed once");
	}

	public function testAnUpdateLeftOutKeepsTheValueTheObserverHas():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final frames = new SequenceRing<IntMap<BudgetShip>>(8);
		final t0 = world([1 => ship(1, 0, 9), 2 => ship(2, 0, 9)]);
		frames.put(0, t0);
		final patch = new RPCMapPatch(codec);
		final b0 = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(null, null, t0, ids([1, 2]), 1 << 10, b0);
		// Both move; room for one update.
		final t1 = world([1 => ship(1, 5, 9), 2 => ship(2, 5, 9)]);
		frames.put(1, t1);
		final b1 = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(t0, b0, t1, ids([2, 1]), 3 + 1 + 5, b1);
		Assert.equals(1, patch.updatedCount);
		Assert.equals(2, patch.updatedKey(0));
		Assert.equals("1", patch.deferred.toArray().join(","));
		Assert.isTrue(b1.isStale(1));
		Assert.isFalse(b1.isStale(2));
		Assert.equals(0.0, (b1.valueIn(1, t1).y : Float), "the observer still holds key 1's old value");
		Assert.equals(5.0, (b1.valueIn(2, t1).y : Float));
		Assert.isFalse(b1.valueIn(1, t1) == t0.get(1), "a stale value is the baseline's own copy");
		// Next tick, against b1 (acknowledged): key 1 is owed, and 2 has not changed.
		final t2 = world([1 => ship(1, 5, 9), 2 => ship(2, 5, 9)]);
		frames.put(2, t2);
		final b2 = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(t1, b1, t2, ids([2, 1]), 3 + 1 + 5, b2);
		Assert.equals(1, patch.updatedCount);
		Assert.equals(1, patch.updatedKey(0));
		Assert.isFalse(patch.isPartial);
		Assert.equals(0, b2.staleCount);
		// A world that went back to what the observer holds owes nothing.
		final b1again = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(t1, b1, world([1 => ship(1, 0, 9), 2 => ship(2, 5, 9)]), ids([2, 1]), 0, b1again);
		Assert.isTrue(patch.isEmpty);
		Assert.equals(0, b1again.staleCount);
		// A base given with a frame other than its own is refused.
		Assert.raises(() -> patch.diffKeysWithin(t2, b1, t2, ids([1]), 100, new RPCMapBaseline()), ArgumentError);
	}

	public function testRemovalsAlwaysGo():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final before = world([for (key in 0...40) key * 2 => ship(key, 0, 1)]);
		final b0 = new RPCMapBaseline<BudgetShip>();
		final patch = new RPCMapPatch(codec);
		patch.diffKeysWithin(null, null, before, ids([for (key in 0...40) key * 2]), 1 << 12, b0);
		// Half of them gone, the rest moved, and new ones: a budget of nothing.
		final after = new IntMap<BudgetShip>();
		final view = new IdList();
		for (key in 0...40) {
			if (key % 2 == 0) {
				after.set(key * 2, ship(key, 1, 1));
				view.push(key * 2);
			}
		}
		after.set(1001, ship(1, 1, 1));
		view.push(1001);
		final b1 = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(before, b0, after, view, 0, b1);
		Assert.equals(20, patch.removedCount);
		Assert.equals(0, patch.addedCount);
		Assert.equals(0, patch.updatedCount);
		Assert.equals(21, patch.deferred.length);
		// The head and the removed keys alone, over the budget they pass.
		Assert.equals(3 + 1 + 19 * 1, bytesOf(patch).length);
		// The observer holds the twenty kept, at their old values, and not the new one.
		Assert.equals(20, b1.length);
		Assert.equals(20, b1.staleCount);
		Assert.isFalse(b1.has(1001));
		Assert.isFalse(b1.has(2));
		// With room for the removals and one more: the first in the order.
		patch.diffKeysWithin(before, b0, after, view, 3 + 1 + 19 + 1 + 5, new RPCMapBaseline());
		Assert.equals(1, patch.updatedCount);
		Assert.equals(0, patch.updatedKey(0));
	}

	public function testThePatchKeepsWithinItsBudgetExactly():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final patch = new RPCMapPatch(codec);
		final again = new RPCMapPatch(codec);
		final random = new Random(23);
		var over:Int = 0;
		var unbounded:Int = 0;
		var inexact:Int = 0;
		var partial:Int = 0;
		for (round in 0...300) {
			final c = Case.random(random, round % 9 == 0);
			final budget:Int = random.next(120);
			final sent = new RPCMapBaseline<BudgetShip>();
			patch.diffKeysWithin(c.full ? null : c.baseValues, c.full ? null : c.base, c.values, c.keys, budget, sent);
			final bytes:Bytes = bytesOf(patch);
			final floor:Int = removalsOnly(patch);
			if (bytes.length > (budget > floor ? budget : floor)) {
				over++;
			}
			if (patch.sizeBound() < bytes.length) {
				unbounded++;
			}
			if (patch.isPartial) {
				partial++;
			}
			// Given exactly what it took, the same choice: nothing it counted
			// was more than it wrote.
			if (bytes.length >= floor) {
				again.diffKeysWithin(c.full ? null : c.baseValues, c.full ? null : c.base, c.values, c.keys, bytes.length, new RPCMapBaseline());
				if (bytesOf(again).toHex() != bytes.toHex() || again.deferred.toArray().join(",") != patch.deferred.toArray().join(",")) {
					inexact++;
				}
			}
		}
		Assert.equals(0, over, "a patch passed its budget");
		Assert.equals(0, unbounded, "sizeBound() was below a budgeted patch");
		Assert.equals(0, inexact, "a budget of exactly what a patch took chose differently");
		Assert.isTrue(partial > 100, 'only $partial of the patches left anything out');
	}

	public function testKeysFarApartAreWeighedAsTheyWillBeCoded():Void {
		// A key goes as its distance from the one before it, so adding one
		// between two far apart can make the pair cheaper: what fits depends
		// on the neighbours, whichever order they are chosen in.
		final codec = RPCCodecs.of(BudgetShip);
		final keys:Array<Int> = [-2000000000, 2000000000, 0, -1, 1, 70000, -70000, 0x7FFFFFFF, -0x7FFFFFFF - 1, 5];
		final values = new IntMap<BudgetShip>();
		for (key in keys) {
			values.set(key, new BudgetShip());
		}
		final patch = new RPCMapPatch(codec);
		final again = new RPCMapPatch(codec);
		final random = new Random(5);
		var wrong:Int = 0;
		for (_ in 0...200) {
			final order:Array<Int> = keys.copy();
			for (i in 0...order.length) {
				final j:Int = random.next(order.length);
				final held:Int = order[i];
				order[i] = order[j];
				order[j] = held;
			}
			final budget:Int = 3 + random.next(40);
			patch.diffKeysWithin(null, null, values, ids(order), budget, new RPCMapBaseline());
			final bytes:Bytes = bytesOf(patch);
			again.diffKeysWithin(null, null, values, ids(order), bytes.length, new RPCMapBaseline());
			if (bytes.length > budget || bytesOf(again).toHex() != bytes.toHex()) {
				wrong++;
			}
		}
		Assert.equals(0, wrong);
	}

	public function testCountsPastABytesWorthAreWeighedToo():Void {
		// Past 127 entries of a kind its count takes a second byte, and past
		// 63 removals the head does: both counted as the entries are chosen.
		final codec = RPCCodecs.of(BudgetShip);
		final before = new IntMap<BudgetShip>();
		final beforeKeys = new IdList();
		for (key in 0...100) {
			before.set(1000 + key, new BudgetShip());
			beforeKeys.push(1000 + key);
		}
		final base = new RPCMapBaseline<BudgetShip>();
		final patch = new RPCMapPatch(codec);
		patch.diffKeysWithin(null, null, before, beforeKeys, 1 << 20, base);
		final values = new IntMap<BudgetShip>();
		final order = new IdList();
		for (key in 0...300) {
			values.set(key * 3, ship(0, 0, key % 3 == 0 ? 0 : 1));
			order.push(((key * 7) % 300) * 3);
		}
		final again = new RPCMapPatch(codec);
		var wrong:Int = 0;
		for (budget in [200, 255, 256, 257, 258, 300, 383, 384, 385, 386, 600, 900]) {
			patch.diffKeysWithin(before, base, values, order, budget, new RPCMapBaseline());
			final bytes:Bytes = bytesOf(patch);
			again.diffKeysWithin(before, base, values, order, bytes.length, new RPCMapBaseline());
			if (bytes.length > budget || bytesOf(again).toHex() != bytes.toHex()) {
				wrong++;
			}
		}
		Assert.equals(0, wrong);
		patch.diffKeysWithin(before, base, values, order, 600, new RPCMapBaseline());
		Assert.equals(100, patch.removedCount);
		Assert.isTrue(patch.addedCount > 128, 'only ${patch.addedCount} added');
	}

	public function testLeftOutEntriesArriveUntilTheObserverHasTheWorld():Void {
		for (lossy in [false, true]) {
			final sim = new BudgetSim(lossy);
			var mismatches:Int = 0;
			var partialTicks:Int = 0;
			for (tick in 1...160) {
				// The world moves for 100 ticks, then holds still.
				sim.step(tick, tick <= 100);
				if (sim.server.patch.isPartial) {
					partialTicks++;
				}
				mismatches += sim.checkClientMatchesBaseline(tick);
			}
			Assert.equals(0, mismatches, 'lossy $lossy: the client did not hold what its baseline says it was sent');
			Assert.isTrue(partialTicks > 50, 'lossy $lossy: only $partialTicks ticks left anything out');
			// Still: everything owed has arrived, and nothing more is sent.
			Assert.isFalse(sim.server.patch.isPartial, 'lossy $lossy: still owed ' + sim.server.patch.deferred.toArray().join(","));
			Assert.isTrue(sim.server.patch.isEmpty, 'lossy $lossy: a still world still sent something');
			Assert.isTrue(sim.clientHoldsTheWorld(), 'lossy $lossy: the client never caught up with the world');
		}
	}

	public function testABaselineCanBeItsOwnBaseOverAReliableConnection():Void {
		// Reliable: the base is always the last sent, kept in one baseline.
		final codec = RPCCodecs.of(BudgetShip);
		final random = new Random(3);
		final patch = new RPCMapPatch(codec);
		final reading = new RPCMapPatch(codec);
		final held = new RPCMapBaseline<BudgetShip>();
		final frames:Array<IntMap<BudgetShip>> = [new IntMap(), new IntMap()];
		final clientValues = new IntMap<BudgetShip>();
		final clientKeys = new IdList();
		final out = new ByteArray();
		var wrong:Int = 0;
		for (tick in 0...120) {
			final frame:IntMap<BudgetShip> = frames[tick & 1];
			final view = new IdList();
			for (key in 0...30) {
				if (tick < 90 && random.next(5) == 0) {
					frame.remove(key);
					continue;
				}
				var value:Null<BudgetShip> = frame.get(key);
				if (value == null) {
					value = new BudgetShip();
					frame.set(key, value);
				}
				final was:Null<BudgetShip> = frames[(tick + 1) & 1].get(key);
				if (was != null) {
					codec.copy(was, value);
				}
				if (tick < 90 && random.next(2) == 0) {
					value.x = random.next(100);
				}
				view.push(key);
			}
			patch.diffKeysWithin(tick == 0 ? null : frames[(tick + 1) & 1], tick == 0 ? null : held, frame, view, 40, held);
			out.position = 0;
			out.length = 0;
			patch.write(out);
			out.position = 0;
			reading.read(out).applyKeys(clientValues, clientKeys, clientValues, clientKeys, true);
			for (i in 0...held.length) {
				final key:Int = held.keyAt(i);
				if (!clientValues.exists(key) || !codec.equals(clientValues.get(key), held.valueIn(key, frame))) {
					wrong++;
				}
			}
			if (clientKeys.length != held.length) {
				wrong++;
			}
		}
		Assert.equals(0, wrong);
		Assert.isFalse(patch.isPartial);
		Assert.equals(0, held.staleCount);
	}

	public function testNestedStructuresArePatchedAgainstWhatTheObserverHolds():Void {
		// A nested structure goes as a patch against the base's: the base of
		// each update carried has to stay its own as those left out drop away.
		final codec = RPCCodecs.of(BudgetBody);
		final random = new Random(9);
		final frames = new SequenceRing<IntMap<BudgetBody>>(8);
		final sent = new SequenceRing<RPCMapBaseline<BudgetBody>>(8);
		final patch = new RPCMapPatch(codec);
		final reading = new RPCMapPatch(codec);
		final clientValues = new SequenceRing<IntMap<BudgetBody>>(8);
		final clientKeys = new SequenceRing<IdList>(8);
		final out = new ByteArray();
		final view = new IdList();
		var wrong:Int = 0;
		var partial:Int = 0;
		for (tick in 1...200) {
			var frame:Null<IntMap<BudgetBody>> = frames.get(tick - frames.capacity);
			if (frame == null) {
				frame = new IntMap();
			}
			final previous:Null<IntMap<BudgetBody>> = frames.get(tick - 1);
			view.clear();
			for (key in 0...24) {
				var value:Null<BudgetBody> = frame.get(key);
				if (value == null) {
					value = new BudgetBody();
					frame.set(key, value);
				}
				if (previous != null) {
					codec.copy(previous.get(key), value);
				}
				if (tick < 150) {
					switch (random.next(4)) {
						case 0:
							value.pos.x = random.next(9);
						case 1:
							value.pos.y = random.next(9);
						case 2:
							value.hp = random.next(3);
						default:
					}
				}
				view.push((key * 5 + tick) % 24);
			}
			frames.put(tick, frame);
			final acked:Int = tick - 1;
			final base:Null<RPCMapBaseline<BudgetBody>> = sent.get(acked);
			var slot:Null<RPCMapBaseline<BudgetBody>> = sent.get(tick - sent.capacity);
			if (slot == null) {
				slot = new RPCMapBaseline();
			}
			patch.diffKeysWithin(base == null ? null : frames.get(acked), base, frame, view, 40, slot);
			sent.put(tick, slot);
			if (patch.isPartial) {
				partial++;
			}
			out.position = 0;
			patch.write(out);
			out.position = 0;
			reading.read(out);
			var into:Null<IntMap<BudgetBody>> = clientValues.get(tick - clientValues.capacity);
			var intoKeys:Null<IdList> = clientKeys.get(tick - clientKeys.capacity);
			if (into == null) {
				into = new IntMap();
				intoKeys = new IdList();
			}
			reading.applyKeys(clientValues.get(acked), clientKeys.get(acked), into, intoKeys, true);
			clientValues.put(tick, into);
			clientKeys.put(tick, intoKeys);
			for (i in 0...slot.length) {
				final key:Int = slot.keyAt(i);
				if (!into.exists(key) || !codec.equals(into.get(key), slot.valueIn(key, frame))) {
					wrong++;
				}
			}
		}
		Assert.equals(0, wrong, "the client's nested values were not what its baseline says");
		Assert.isTrue(partial > 100, 'only $partial left anything out');
		Assert.isFalse(patch.isPartial);
	}

	public function testAnotherDiffLeavesNothingDeferred():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final patch = new RPCMapPatch(codec);
		final values = world([1 => ship(1, 1, 1), 2 => ship(2, 2, 2)]);
		patch.diffKeysWithin(null, null, values, ids([1, 2]), 3, new RPCMapBaseline());
		Assert.isTrue(patch.isPartial);
		patch.diffKeys(null, null, values, ids([1, 2]));
		Assert.isFalse(patch.isPartial);
		Assert.equals(0, patch.deferred.length);
		Assert.isFalse(new RPCMapPatch(codec).isPartial);
	}

	public function testWhatABudgetedDiffCannotUseIsRefused():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final patch = new RPCMapPatch(codec);
		final values = world([1 => ship(1, 1, 1)]);
		Assert.raises(() -> patch.diffKeysWithin(null, null, values, ids([1]), -1, new RPCMapBaseline()), ArgumentError);
		Assert.raises(() -> patch.diffKeysWithin(null, null, values, ids([1]), 10, null), ArgumentError);
		Assert.raises(() -> patch.diffKeysWithin(null, null, null, ids([1]), 10, new RPCMapBaseline()), ArgumentError);
		Assert.raises(() -> patch.diffKeysWithin(null, null, values, ids([1, 2]), 10, new RPCMapBaseline()), ArgumentError);
		// A baseline no diff has written is no base.
		Assert.raises(() -> patch.diffKeysWithin(values, new RPCMapBaseline(), values, ids([1]), 10, new RPCMapBaseline()), ArgumentError);
		// A refused diff leaves the baseline it was given as it was.
		final sent = new RPCMapBaseline<BudgetShip>();
		patch.diffKeysWithin(null, null, values, ids([1]), 100, sent);
		Assert.raises(() -> patch.diffKeysWithin(null, null, values, ids([1, 9]), 100, sent), ArgumentError);
		Assert.equals(1, sent.length);
		Assert.isTrue(sent.valueIn(1, values) == values.get(1));
	}

	public function testOverACallTheClientAppliesItAsAnyPatch():Void {
		final fixture = new BudgetFixture();
		final codec = RPCCodecs.of(BudgetShip);
		final t0 = world([for (key in 0...6) key => ship(key + 1, 1, 1)]);
		final view = ids([5, 4, 3, 2, 1, 0]);
		final sent = new RPCMapBaseline<BudgetShip>();
		final patch = new RPCMapPatch(codec).diffKeysWithin(null, null, t0, view, 3 + 2 * 11, sent);
		Assert.equals("3,2,1,0", patch.deferred.toArray().join(","));
		final frame = new IntMap<BudgetShip>();
		final keys = new IdList();
		fixture.handler.inCall.test(() -> fixture.commands.ships(0, 0, patch), () -> {
			final received = fixture.handler.lastShips;
			Assert.isTrue(received.isFull);
			Assert.isFalse(received.isPartial, "a patch that arrived owes nothing: that is the sender's to know");
			received.applyKeys(null, null, frame, keys, true);
		});
		Assert.equals("4,5", keys.toArray().join(","));
		Assert.equals(5.0, (frame.get(4).x : Float));
	}

	public function testABudgetedDiffAllocatesNothing():Void {
		if (!crossbyte.test.AllocationMeter.SUPPORTED) {
			Assert.pass();
			return;
		}
		// Against acknowledged baselines in a ring, and against the last sent
		// in one baseline, as over a reliable connection.
		for (reliable in [false, true]) {
			final loop = new BudgetLoop(reliable);
			// Warm: every list, and every baseline's values, at its largest.
			for (_ in 0...400) {
				loop.step();
			}
			Assert.isTrue(loop.partial > 300, 'reliable $reliable: only ${loop.partial} of the diffs left anything out');
			final reading = crossbyte.test.AllocationMeter.measure(loop.step, 200);
			Assert.isTrue(reading.perOperation == 0, 'reliable $reliable: a budgeted diff allocated $reading');
		}
	}

	public function testStringKeys():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final patch = new RPCStringMapPatch(codec);
		final plain = new RPCStringMapPatch(codec);
		final t0 = new StringMap<BudgetShip>();
		for (name in ["ann", "bob", "cy", "dee", "\u{E9}t\u{E9}"]) {
			t0.set(name, ship(name.length, 0, 1));
		}
		final order:Array<String> = ["dee", "ann", "\u{E9}t\u{E9}", "bob", "cy"];
		// Everything: diffKeys' bytes.
		final all = new RPCStringMapBaseline<BudgetShip>();
		patch.diffKeysWithin(null, null, t0, order, 1 << 10, all);
		Assert.equals(hexOfStrings(plain.diffKeys(null, null, t0, order)), hexOfStrings(patch));
		Assert.equals(5, all.length);
		// Room for two: the first two in the order, keys whole and in wire
		// order. Each is its key (a count and three bytes) and its patch (a
		// mask, x and hp).
		final two = new RPCStringMapBaseline<BudgetShip>();
		final size:Int = 3 + (1 + 3 + 1 + 4 + 1) + (1 + 3 + 1 + 4 + 1);
		patch.diffKeysWithin(null, null, t0, order, size, two);
		Assert.equals("ann,dee", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.same(["\u{E9}t\u{E9}", "bob", "cy"], patch.deferred);
		Assert.isTrue(patch.isPartial);
		Assert.equals(size, bytesOfStrings(patch).length);
		// The rest arrive on the next tick, against what was carried.
		final t1 = new StringMap<BudgetShip>();
		for (name => value in t0) {
			t1.set(name, value);
		}
		t1.remove("ann");
		final next = new RPCStringMapBaseline<BudgetShip>();
		patch.diffKeysWithin(t0, two, t1, ["cy", "bob", "dee", "\u{E9}t\u{E9}"], 1 << 10, next);
		Assert.same(["ann"], patch.removed);
		Assert.equals("bob,cy,\u{E9}t\u{E9}", [for (i in 0...patch.addedCount) patch.addedKey(i)].join(","));
		Assert.equals(0, patch.updatedCount);
		Assert.isFalse(patch.isPartial);
		Assert.equals(4, next.length);
		// An update left out keeps the value the observer has.
		final t2 = new StringMap<BudgetShip>();
		for (name => value in t1) {
			t2.set(name, ship(value.x, 7, 1));
		}
		// An update is its key (3 bytes) and its patch (a mask and y): room for one.
		final stale = new RPCStringMapBaseline<BudgetShip>();
		patch.diffKeysWithin(t1, next, t2, ["cy", "bob", "dee", "\u{E9}t\u{E9}"], 3 + 3 + 5, stale);
		Assert.equals("cy", patch.updatedKey(0));
		Assert.equals(1, patch.updatedCount);
		Assert.equals(3, stale.staleCount);
		Assert.isTrue(stale.isStale("bob"));
		Assert.isFalse(stale.isStale("cy"));
		Assert.equals(0.0, (stale.valueIn("bob", t2).y : Float));
		Assert.equals(7.0, (stale.valueIn("cy", t2).y : Float));
		Assert.raises(() -> patch.diffKeysWithin(t1, stale, t2, ["cy"], 10, new RPCStringMapBaseline()), ArgumentError);
	}

	public function testStringKeysKeepWithinTheirBudget():Void {
		final codec = RPCCodecs.of(BudgetShip);
		final patch = new RPCStringMapPatch(codec);
		final again = new RPCStringMapPatch(codec);
		final random = new Random(41);
		final names:Array<String> = [for (i in 0...40) (i % 3 == 0 ? "\u{E9}" : "") + "n" + i];
		var wrong:Int = 0;
		var partial:Int = 0;
		var base:Null<RPCStringMapBaseline<BudgetShip>> = null;
		var baseValues:Null<StringMap<BudgetShip>> = null;
		for (_ in 0...200) {
			final values = new StringMap<BudgetShip>();
			final order:Array<String> = [];
			for (name in names) {
				if (random.next(3) != 0) {
					values.set(name, ship(random.next(4), random.next(4), 1));
					order.push(name);
				}
			}
			final budget:Int = random.next(90);
			final sent = new RPCStringMapBaseline<BudgetShip>();
			patch.diffKeysWithin(baseValues, base, values, order, budget, sent);
			final bytes:Bytes = bytesOfStrings(patch);
			if (patch.isPartial) {
				partial++;
			}
			final floor:Int = Std.int(hexOfStringRemovals(patch).length / 2);
			if (bytes.length > (budget > floor ? budget : floor) || patch.sizeBound() < bytes.length) {
				wrong++;
			}
			if (bytes.length >= floor) {
				again.diffKeysWithin(baseValues, base, values, order, bytes.length, new RPCStringMapBaseline());
				if (bytesOfStrings(again).toHex() != bytes.toHex()) {
					wrong++;
				}
			}
			base = sent;
			baseValues = values;
		}
		Assert.equals(0, wrong);
		Assert.isTrue(partial > 50, 'only $partial left anything out');
	}

	// ------------------------------------------------------------------

	static function ship(x:Float, y:Float, hp:Int):BudgetShip {
		final s = new BudgetShip();
		s.x = x;
		s.y = y;
		s.hp = hp;
		return s;
	}

	static function world(values:Map<Int, BudgetShip>):IntMap<BudgetShip> {
		final map = new IntMap<BudgetShip>();
		for (key => value in values) {
			map.set(key, value);
		}
		return map;
	}

	public static function ids(values:Array<Int>):IdList {
		final list = new IdList();
		for (value in values) {
			list.push(value);
		}
		return list;
	}

	static function holdsExactly(baseline:RPCMapBaseline<BudgetShip>, keys:IdList):Bool {
		final sorted:Array<Int> = [];
		for (key in keys) {
			if (sorted.indexOf(key) < 0) {
				sorted.push(key);
			}
		}
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return [for (i in 0...baseline.length) baseline.keyAt(i)].join(",") == sorted.join(",");
	}

	static function bytesOf(patch:RPCMapPatch<BudgetShip>):Bytes {
		final out = new ByteArray();
		patch.write(out);
		return (out : Bytes).sub(0, out.length);
	}

	static function hexOf(patch:RPCMapPatch<BudgetShip>):String {
		return bytesOf(patch).toHex();
	}

	static function bytesOfStrings(patch:RPCStringMapPatch<BudgetShip>):Bytes {
		final out = new ByteArray();
		patch.write(out);
		return (out : Bytes).sub(0, out.length);
	}

	static function hexOfStrings(patch:RPCStringMapPatch<BudgetShip>):String {
		return bytesOfStrings(patch).toHex();
	}

	/** The bytes of the head and the removed keys alone: what any budget carries. **/
	static function removalsOnly(patch:RPCMapPatch<BudgetShip>):Int {
		var size:Int = 2 + crossbyte.rpc._internal.RPCBudget.varUIntSize((patch.removedCount << 1) | (patch.isFull ? 1 : 0));
		final removed = new IdList();
		for (i in 0...patch.removedCount) {
			removed.push(patch.removed.get(i));
		}
		return size + crossbyte.rpc._internal.RPCBudget.keysSize(removed);
	}

	static function hexOfStringRemovals(patch:RPCStringMapPatch<BudgetShip>):String {
		final out = new ByteArray();
		final frame = new crossbyte.rpc._internal.RPCFrame(64);
		frame.beginScratch();
		frame.putVarUInt(patch.removed.length << 1);
		frame.putVarUInt(0);
		frame.putVarUInt(0);
		for (key in patch.removed) {
			frame.putString(key);
		}
		out.writeBytes(frame, 0, frame.position);
		return (out : Bytes).sub(0, out.length).toHex();
	}
}

/** Three fields: a key, a mask byte and nine bytes when every one differs. **/
class BudgetShip implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var hp:UInt8 = 0;

	public function new() {}
}

class BudgetVec implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;

	public function new() {}
}

/** A nested structure, patched field by field against the base's. **/
class BudgetBody implements RPCStruct {
	public var pos:BudgetVec = new BudgetVec();
	public var hp:UInt8 = 0;

	public function new() {}
}

/** The same LCG as the other RPC fuzz tests: the same numbers on every target. **/
class Random {
	var seed:Int;

	public function new(seed:Int) {
		this.seed = seed;
	}

	public function next(bound:Int):Int {
		seed = (Hash.mul32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
		return (seed >>> 8) % bound;
	}
}

/** A random base, as a baseline and as keys, and a view of it moved on. **/
class Case {
	public final baseValues = new IntMap<BudgetShip>();
	public final baseKeys = new IdList();
	public final base = new RPCMapBaseline<BudgetShip>();
	public final values = new IntMap<BudgetShip>();
	public final keys = new IdList();
	public var full:Bool = false;

	public function new() {}

	public static function random(random:Random, full:Bool):Case {
		final c = new Case();
		final codec = RPCCodecs.of(BudgetShip);
		c.full = full;
		for (_ in 0...random.next(24)) {
			final key:Int = random.next(4) == 0 ? random.next(2000000) - 1000000 : random.next(80);
			if (!c.baseValues.exists(key)) {
				final s = new BudgetShip();
				s.x = random.next(50);
				s.y = random.next(50);
				c.baseValues.set(key, s);
				c.baseKeys.push(key);
			}
		}
		// The baseline of that base, as a diff within no limit writes it.
		new RPCMapPatch(codec).diffKeysWithin(null, null, c.baseValues, c.baseKeys, 1 << 20, c.base);
		for (key in c.baseKeys) {
			if (random.next(4) != 0) {
				final value = codec.copy(c.baseValues.get(key), new BudgetShip());
				switch (random.next(4)) {
					case 0:
						value.x = random.next(50);
					case 1:
						value.hp = random.next(4);
					default:
				}
				c.values.set(key, value);
				c.keys.push(key);
			}
		}
		for (_ in 0...random.next(8)) {
			final key:Int = random.next(120);
			if (!c.values.exists(key)) {
				final s = new BudgetShip();
				s.y = random.next(3);
				c.values.set(key, s);
				c.keys.push(key);
			}
		}
		// In an order of priority that is not the keys' own, a few given twice.
		final n:Int = c.keys.length;
		final order:Array<Int> = c.keys.toArray();
		for (i in 0...n) {
			final j:Int = random.next(n);
			final held:Int = order[i];
			order[i] = order[j];
			order[j] = held;
		}
		if (n > 0 && random.next(3) == 0) {
			order.push(order[random.next(n)]);
		}
		c.keys.clear();
		for (key in order) {
			c.keys.push(key);
		}
		return c;
	}
}

interface BudgetContract {
	function ships(tick:VarUInt, base:VarUInt, ships:RPCMapPatch<BudgetShip>):Void;
}

@:rpcContract(BudgetContract)
private class BudgetCommands extends RPCCommands {
	public function new() {}
}

/** A client: its frames by tick, values and keys, applied as each patch arrives, inside the call. **/
private class BudgetClient extends RPCHandler implements BudgetContract {
	public var lastShips:Null<RPCMapPatch<BudgetShip>> = null;
	public final inCall = new InCall();
	public final values:SequenceRing<IntMap<BudgetShip>> = new SequenceRing(32);
	public final keys:SequenceRing<IdList> = new SequenceRing(32);
	public var applied:Int = -1;
	public var skipped:Int = 0;

	public function new() {}

	public function ships(tick:VarUInt, base:VarUInt, ships:RPCMapPatch<BudgetShip>):Void {
		lastShips = ships;
		if (!ships.isFull && values.get(base) == null) {
			// Its base has aged out here: keep acknowledging, and a full one comes.
			skipped++;
			inCall.run();
			return;
		}
		var into:Null<IntMap<BudgetShip>> = values.get((tick : Int) - values.capacity);
		var intoKeys:Null<IdList> = keys.get((tick : Int) - keys.capacity);
		if (into == null) {
			into = new IntMap();
			intoKeys = new IdList();
		}
		if (ships.isFull) {
			ships.applyKeys(null, null, into, intoKeys, true);
		} else {
			ships.applyKeys(values.get(base), keys.get(base), into, intoKeys, true);
		}
		values.put(tick, into);
		keys.put(tick, intoKeys);
		applied = tick;
		inCall.run();
	}
}

private class BudgetFixture {
	public final link = LinkedConnection.pair();
	public final commands = new BudgetCommands();
	public final handler = new BudgetClient();
	public final client:RPCSession<BudgetCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<BudgetCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** The server's side: the world's frames by tick, and one observer's baselines and patch. **/
private class BudgetServer {
	public final codec = RPCCodecs.of(BudgetShip);
	public final frames:SequenceRing<IntMap<BudgetShip>> = new SequenceRing(32);
	public final sent:SequenceRing<RPCMapBaseline<BudgetShip>> = new SequenceRing(32);
	public final patch = new RPCMapPatch(RPCCodecs.of(BudgetShip));
	public var acked:Int = 0;
	public var everAcked:Bool = false;

	public function new() {}
}

/**
	A world of 60 entities, about 40 in an observer's view, moving and
	coming and going, sent within a budget of a third of what the view's
	changes take, over a link that loses some patches and acknowledges two
	ticks late.
**/
private class BudgetSim {
	static inline final ENTITIES:Int = 60;
	static inline final BUDGET:Int = 140;

	public final server = new BudgetServer();
	public final fixture = new BudgetFixture();
	final lossy:Bool;
	final random = new Random(17);
	final xs:Array<Float> = [];
	final hps:Array<Int> = [];
	final alive:Array<Bool> = [];
	final view = new IdList();
	// Whether each of the last 64 ticks was applied, for its acknowledgement.
	final appliedAt:Array<Bool> = [for (_ in 0...64) false];
	var centre:Int = 0;

	public function new(lossy:Bool) {
		this.lossy = lossy;
		for (i in 0...ENTITIES) {
			xs.push(random.next(100));
			hps.push(1 + random.next(5));
			alive.push(random.next(4) != 0);
		}
	}

	/** One tick: the world moved (or not), the observer's patch made and sent (or lost). **/
	public function step(tick:Int, moving:Bool):Void {
		if (moving) {
			// Nearest first, to a point that wanders while the world moves:
			// the order is the caller's.
			centre = (tick * 7) % ENTITIES;
			for (i in 0...ENTITIES) {
				switch (random.next(12)) {
					case 0:
						alive[i] = !alive[i];
					case 1 | 2 | 3 | 4:
						xs[i] = (xs[i] + 1) % 100;
					case 5:
						hps[i] = 1 + random.next(5);
					default:
				}
			}
		}
		// This tick's frame, into the one about to age out.
		var frame:Null<IntMap<BudgetShip>> = server.frames.get(tick - server.frames.capacity);
		if (frame == null) {
			frame = new IntMap();
		}
		view.clear();
		for (i in 0...ENTITIES) {
			if (!alive[i]) {
				frame.remove(i);
				continue;
			}
			var value:Null<BudgetShip> = frame.get(i);
			if (value == null) {
				value = new BudgetShip();
				frame.set(i, value);
			}
			value.x = xs[i];
			value.y = i;
			value.hp = hps[i];
		}
		server.frames.put(tick, frame);
		for (d in 0...ENTITIES) {
			for (side in 0...2) {
				final i:Int = side == 0 ? (centre + d) % ENTITIES : (centre - d + ENTITIES) % ENTITIES;
				if ((d > 0 || side == 0) && alive[i] && d < 22) {
					view.push(i);
				}
			}
		}
		final base:Null<RPCMapBaseline<BudgetShip>> = server.everAcked ? server.sent.get(server.acked) : null;
		final baseValues:Null<IntMap<BudgetShip>> = base == null ? null : server.frames.get(server.acked);
		var slot:Null<RPCMapBaseline<BudgetShip>> = server.sent.get(tick - server.sent.capacity);
		if (slot == null) {
			slot = new RPCMapBaseline();
		}
		server.patch.diffKeysWithin(baseValues, base, frame, view, BUDGET, slot);
		server.sent.put(tick, slot);
		appliedAt[tick & 63] = false;
		if (!lossy || random.next(5) != 0) {
			fixture.commands.ships(tick, baseValues == null ? 0 : server.acked, server.patch);
			appliedAt[tick & 63] = fixture.handler.applied == tick;
		}
		// Acknowledgements two ticks late, and over a lossy link some lost.
		final ack:Int = tick - 2;
		if (ack > 0 && appliedAt[ack & 63] && (!lossy || random.next(4) != 0)) {
			server.acked = ack;
			server.everAcked = true;
		}
	}

	/** 1 when the client's frame for `tick` is not what the baseline filed under it says, else 0. **/
	public function checkClientMatchesBaseline(tick:Int):Int {
		if (fixture.handler.applied != tick) {
			return 0;
		}
		final baseline = server.sent.get(tick);
		final frame = server.frames.get(tick);
		final values = fixture.handler.values.get(tick);
		final keys = fixture.handler.keys.get(tick);
		if (keys.length != baseline.length) {
			return 1;
		}
		for (i in 0...baseline.length) {
			final key:Int = baseline.keyAt(i);
			if (keys.get(i) != key || !server.codec.equals(values.get(key), baseline.valueIn(key, frame))) {
				return 1;
			}
		}
		return 0;
	}

	/** Whether the client's newest frame is the view, at the world's values. **/
	public function clientHoldsTheWorld():Bool {
		final tick:Int = fixture.handler.applied;
		final values = fixture.handler.values.get(tick);
		final keys = fixture.handler.keys.get(tick);
		final frame = server.frames.get(tick);
		final sorted:Array<Int> = view.toArray();
		sorted.sort((a, b) -> a - b);
		if (keys.toArray().join(",") != sorted.join(",")) {
			return false;
		}
		for (key in sorted) {
			if (!server.codec.equals(values.get(key), frame.get(key))) {
				return false;
			}
		}
		return true;
	}
}

/**
	The sender alone, for the allocation meter: 60 entities in view, a
	dozen changing each tick, diffed against the baseline of two ticks
	before within a budget of about half the changes, and written.
**/
private class BudgetLoop {
	static inline final ENTITIES:Int = 60;

	public var partial:Int = 0;

	final codec = RPCCodecs.of(BudgetShip);
	final frames:SequenceRing<IntMap<BudgetShip>> = new SequenceRing(8);
	final sent:SequenceRing<RPCMapBaseline<BudgetShip>> = new SequenceRing(8);
	final patch = new RPCMapPatch(RPCCodecs.of(BudgetShip));
	final view = new IdList();
	final out = new ByteArray();
	final reliable:Bool;
	final held = new RPCMapBaseline<BudgetShip>();
	var tick:Int = 0;

	public function new(reliable:Bool) {
		this.reliable = reliable;
		for (i in 0...ENTITIES) {
			view.push((i * 37) % ENTITIES);
		}
	}

	public function step():Void {
		tick++;
		var frame:Null<IntMap<BudgetShip>> = frames.get(tick - frames.capacity);
		if (frame == null) {
			frame = new IntMap();
		}
		final previous:Null<IntMap<BudgetShip>> = frames.get(tick - 1);
		for (i in 0...ENTITIES) {
			var value:Null<BudgetShip> = frame.get(i);
			if (value == null) {
				value = new BudgetShip();
				frame.set(i, value);
			}
			if (previous != null) {
				codec.copy(previous.get(i), value);
			}
			if ((i + tick) % 5 == 0) {
				value.x = (tick + i) & 63;
			}
		}
		frames.put(tick, frame);
		if (reliable) {
			patch.diffKeysWithin(tick == 1 ? null : previous, tick == 1 ? null : held, frame, view, 60, held);
			if (patch.isPartial) {
				partial++;
			}
			out.position = 0;
			patch.write(out);
			return;
		}
		final acked:Int = tick - 2;
		final base:Null<RPCMapBaseline<BudgetShip>> = sent.get(acked);
		var slot:Null<RPCMapBaseline<BudgetShip>> = sent.get(tick - sent.capacity);
		if (slot == null) {
			slot = new RPCMapBaseline();
		}
		patch.diffKeysWithin(base == null ? null : frames.get(acked), base, frame, view, 60, slot);
		sent.put(tick, slot);
		if (patch.isPartial) {
			partial++;
		}
		out.position = 0;
		patch.write(out);
	}
}
