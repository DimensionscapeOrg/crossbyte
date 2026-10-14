package crossbyte.db.kv;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/** A clock a test moves by hand. **/
class TestClock {
	public var now:Float = 1760000000.25;

	public function new() {}

	public function read():Float {
		return now;
	}
}

/**
	What every `KVStore` does alike, each check given a way to make a fresh
	store from options: `MemoryKVStoreTest`, `SQLiteKVStoreTest` and
	`PostgresKVStoreTest` run each against their backend. Not a test itself,
	so each backend's class names the checks it runs.
**/
class KVStoreChecks {
	public static function bytes(text:String):Bytes {
		return Bytes.ofString(text);
	}

	public static function text(record:Null<KVRecord>):Null<String> {
		return record == null ? null : record.value.toString();
	}

	/** The `KVError` `run` throws, or null when it throws none or something else. **/
	public static function kvError(run:Void->Void):Null<KVError> {
		try {
			run();
		} catch (e:KVError) {
			return e;
		} catch (_:Dynamic) {}

		return null;
	}

	public static function writesAndReads(make:KVOptions->KVStore):Void {
		var clock = new TestClock();
		var store = make({clock: clock.read});

		Assert.isNull(store.get("users/alice"));

		var first = store.put("users/alice", bytes("one"));
		Assert.equals("users/alice", first.key);
		Assert.equals(1.0, first.revision);
		Assert.equals(clock.now, first.createdAt);
		Assert.equals(clock.now, first.updatedAt);
		Assert.isFalse(first.tombstone);
		Assert.equals(0, first.schema);

		var made:Float = clock.now;
		clock.now += 10;
		var second = store.put("users/alice", bytes("two"), 77);
		Assert.equals(2.0, second.revision);
		Assert.equals(made, second.createdAt, "a write keeps when the record was made");
		Assert.equals(clock.now, second.updatedAt);
		Assert.equals(77, second.schema);

		var read = Require.notNull(store.get("users/alice"));
		Assert.equals("two", text(read));
		Assert.equals(2.0, read.revision);
		Assert.equals(made, read.createdAt);
		Assert.equals(clock.now, read.updatedAt);
		Assert.equals(77, read.schema);

		// An empty value is a value.
		store.put("empty", Bytes.alloc(0));
		Assert.equals(0, Require.notNull(store.get("empty")).value.length);

		// A schema is any Int: an RPCStruct layout is a 32-bit hash, half of
		// them negative.
		store.put("layout", bytes("x"), -1965589011);
		Assert.equals(-1965589011, Require.notNull(store.get("layout")).schema);
		Assert.equals(-1965589011, store.scan({prefix: "layout"}).items[0].schema);
		store.close();
	}

	public static function valuesAreTheCallersOwn(make:KVOptions->KVStore):Void {
		var store = make({});
		var buffer = bytes("abc");
		store.put("k", buffer);
		// The caller reuses its buffer, as a socket's reader does.
		buffer.set(0, "z".code);
		Assert.equals("abc", text(store.get("k")));

		var read = Require.notNull(store.get("k"));
		read.value.set(0, "y".code);
		Assert.equals("abc", text(store.get("k")), "what a read hands back is a copy");

		var page = store.scan();
		page.items[0].value.set(1, "x".code);
		Assert.equals("abc", text(store.get("k")));
		store.close();
	}

	public static function compareAndSetWritesOnlyAtTheRevision(make:KVOptions->KVStore):Void {
		var store = make({});

		// 0: only if there is none.
		var created = Require.notNull(store.compareAndSet("k", bytes("a"), 0));
		Assert.equals(1.0, created.revision);
		Assert.isNull(store.compareAndSet("k", bytes("b"), 0), "a second create lost");
		Assert.equals("a", text(store.get("k")));

		// At the revision read: written; at a stale one: refused, unchanged.
		var updated = Require.notNull(store.compareAndSet("k", bytes("c"), 1, 5));
		Assert.equals(2.0, updated.revision);
		Assert.equals(5, updated.schema);
		Assert.isNull(store.compareAndSet("k", bytes("d"), 1));
		Assert.isNull(store.compareAndSet("k", bytes("d"), 3), "a revision not reached yet");
		var now = Require.notNull(store.get("k"));
		Assert.equals("c", text(now));
		Assert.equals(2.0, now.revision);

		// A revision of a key that has none.
		Assert.isNull(store.compareAndSet("missing", bytes("x"), 1));
		Assert.isNull(store.get("missing"));

		Assert.raises(() -> store.compareAndSet("k", bytes("x"), -1), ArgumentError);
		Assert.raises(() -> store.compareAndSet("k", bytes("x"), 1.5), ArgumentError);
		Assert.raises(() -> store.compareAndSet("k", bytes("x"), Math.NaN), ArgumentError);
		store.close();
	}

	public static function deletesLeaveTombstones(make:KVOptions->KVStore):Void {
		var clock = new TestClock();
		var store = make({clock: clock.read});
		store.put("k", bytes("a"));
		store.put("k", bytes("b"));

		clock.now += 5;
		Assert.isTrue(store.delete("k"));
		Assert.isNull(store.get("k"));
		Assert.isFalse(store.delete("k"), "a tombstone is not deleted again");
		Assert.isFalse(store.delete("never"));

		var tombstones = store.scan({includeTombstones: true}).items;
		Assert.equals(1, tombstones.length);
		var tombstone = tombstones[0];
		Assert.isTrue(tombstone.tombstone);
		Assert.equals(3.0, tombstone.revision);
		Assert.equals(0, tombstone.value.length);
		Assert.equals(clock.now, tombstone.updatedAt);

		// A write after it goes on from its revision, as a new life.
		clock.now += 5;
		var again = store.put("k", bytes("c"));
		Assert.equals(4.0, again.revision);
		Assert.equals(clock.now, again.createdAt);
		store.close();
	}

	public static function aRevisionFromBeforeADeleteIsNotTheNextValues(make:KVOptions->KVStore):Void {
		// Read at revision 1, deleted and written again by someone else: the
		// value there now is not the one read, and the write must lose. With
		// the record removed outright it would be back at revision 1.
		var store = make({});
		var read = store.put("k", bytes("old"));
		Assert.isTrue(store.delete("k"));
		store.put("k", bytes("new"));

		Assert.isNull(store.compareAndSet("k", bytes("mine"), read.revision));
		Assert.isFalse(store.compareAndDelete("k", read.revision));
		Assert.equals("new", text(store.get("k")));

		// After a delete, 0 says "only if there is none", and a tombstone is none.
		Assert.isTrue(store.delete("k"));
		var created = Require.notNull(store.compareAndSet("k", bytes("fresh"), 0));
		Assert.equals(5.0, created.revision);
		store.close();
	}

	public static function compareAndDeleteDeletesOnlyAtTheRevision(make:KVOptions->KVStore):Void {
		var store = make({});
		store.put("k", bytes("a"));
		store.put("k", bytes("b"));

		Assert.isFalse(store.compareAndDelete("k", 1));
		Assert.equals("b", text(store.get("k")));
		Assert.isTrue(store.compareAndDelete("k", 2));
		Assert.isNull(store.get("k"));
		Assert.isFalse(store.compareAndDelete("k", 3), "the tombstone's own revision deletes nothing");
		Assert.isFalse(store.compareAndDelete("missing", 1));
		Assert.raises(() -> store.compareAndDelete("k", 0), ArgumentError);
		store.close();
	}

	public static function scansAreInCodePointOrder(make:KVOptions->KVStore):Void {
		var store = make({});
		// U+1F600 is past U+FFFF: as UTF-16 its first unit is below U+FFFD's,
		// and as UTF-8, and by code point, it is above.
		var keys = ["b", "a", "a/b", "a\u{1F600}", "a\u{FFFD}", "A", "a b", "\u{E9}"];

		for (key in keys) {
			store.put(key, bytes(key));
		}

		var order = [for (record in store.scan().items) record.key];
		Assert.same(["A", "a", "a b", "a/b", "a\u{FFFD}", "a\u{1F600}", "b", "\u{E9}"], order);
		Assert.equals("a\u{1F600}", text(store.get("a\u{1F600}")));
		store.close();
	}

	public static function scansReadAPrefixOrARange(make:KVOptions->KVStore):Void {
		var store = make({});

		for (key in ["users/alice", "users/bob", "users/carol", "usersx", "user", "groups/1", "users/"]) {
			store.put(key, bytes(key));
		}

		inline function keysOf(options:KVScanOptions):Array<String> {
			return [for (record in store.scan(options).items) record.key];
		}

		Assert.same(["users/", "users/alice", "users/bob", "users/carol"], keysOf({prefix: "users/"}));
		Assert.same(["users/bob", "users/carol"], keysOf({prefix: "users/", startAt: "users/b"}));
		Assert.same(["users/carol"], keysOf({prefix: "users/", startAfter: "users/bob"}));
		Assert.same(["users/", "users/alice"], keysOf({prefix: "users/", endBefore: "users/b"}));
		Assert.same(["user", "users/", "users/alice"], keysOf({startAt: "user", endBefore: "users/b"}));
		Assert.same([], keysOf({prefix: "nobody/"}));
		Assert.same([], keysOf({startAt: "z", endBefore: "a"}));
		Assert.same(["groups/1", "user"], keysOf({limit: 2}));

		// No case folding: SQL's LIKE would take "Users/" for "users/".
		Assert.same([], keysOf({prefix: "Users/"}));
		// No wildcards either.
		Assert.same([], keysOf({prefix: "users_"}));
		Assert.same([], keysOf({prefix: "users%"}));
		store.close();
	}

	public static function pagesReadEveryKeyOnce(make:KVOptions->KVStore):Void {
		var store = make({});
		var expected:Array<String> = [];

		for (i in 0...57) {
			var key = "item/" + StringTools.lpad(Std.string(i), "0", 3);
			expected.push(key);
			store.put(key, bytes(Std.string(i)));
		}

		store.put("other", bytes("x"));

		var seen:Array<String> = [];
		var pages:Int = 0;
		var page = store.scan({prefix: "item/", limit: 10});

		while (true) {
			pages++;

			for (record in page.items) {
				seen.push(record.key);
			}

			if (page.next == null) {
				Assert.isFalse(page.more);
				break;
			}

			Assert.isTrue(page.more);
			Assert.equals(page.items[page.items.length - 1].key, page.next);
			page = store.scan({prefix: "item/", limit: 10, startAfter: page.next});
		}

		Assert.same(expected, seen);
		Assert.equals(6, pages);

		// A page that ends exactly at the range's end says there is no more.
		var exact = store.scan({prefix: "item/0", limit: 57});
		Assert.equals(57, exact.items.length);
		Assert.isFalse(exact.more);
		Assert.isNull(exact.next);
		store.close();
	}

	public static function scansSkipTombstonesUnlessAsked(make:KVOptions->KVStore):Void {
		var store = make({});

		for (key in ["a", "b", "c", "d"]) {
			store.put(key, bytes(key));
		}

		store.delete("b");
		store.delete("c");

		Assert.same(["a", "d"], [for (r in store.scan().items) r.key]);

		// The limit counts what the page holds, not the tombstones passed over.
		var first = store.scan({limit: 1});
		Assert.same(["a"], [for (r in first.items) r.key]);
		var second = store.scan({limit: 1, startAfter: first.next});
		Assert.same(["d"], [for (r in second.items) r.key]);
		Assert.isFalse(second.more);

		var all = store.scan({includeTombstones: true}).items;
		Assert.same(["a", "b", "c", "d"], [for (r in all) r.key]);
		Assert.same([false, true, true, false], [for (r in all) r.tombstone]);
		store.close();
	}

	public static function aPageEndsAtItsBytes(make:KVOptions->KVStore):Void {
		var store = make({maxPageBytes: 25});

		for (i in 0...6) {
			store.put("k" + i, Bytes.alloc(10));
		}

		var first = store.scan();
		Assert.equals(2, first.items.length, "two of 10 bytes fit in 25, a third would not");
		Assert.isTrue(first.more);
		Assert.equals("k1", first.next);

		// A value larger than the page alone still comes, alone.
		store.put("k2", Bytes.alloc(40));
		var big = store.scan({startAfter: "k1"});
		Assert.equals(1, big.items.length);
		Assert.equals(40, big.items[0].value.length);
		Assert.isTrue(big.more);
		store.close();
	}

	public static function refusesWhatItWouldNotHold(make:KVOptions->KVStore):Void {
		var store = make({maxKeyBytes: 8, maxValueBytes: 4, maxScanLimit: 20});

		Assert.raises(() -> store.put("", bytes("a")), ArgumentError);
		Assert.raises(() -> store.put(null, bytes("a")), ArgumentError);
		Assert.raises(() -> store.put("123456789", bytes("a")), ArgumentError);
		// Eight bytes, four characters.
		store.put("\u{E9}\u{E9}\u{E9}\u{E9}", bytes("a"));
		Assert.raises(() -> store.put("\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}", bytes("a")), ArgumentError);
		Assert.raises(() -> store.put("a" + String.fromCharCode(0) + "b", bytes("a")), ArgumentError);
		Assert.raises(() -> store.put("a\u{10FFFF}", bytes("a")), ArgumentError);
		#if (cpp || jvm || js || hl)
		Assert.raises(() -> store.put("a" + String.fromCharCode(0xD800), bytes("a")), ArgumentError);
		Assert.raises(() -> store.put(String.fromCharCode(0xDC00) + "a", bytes("a")), ArgumentError);
		#end
		Assert.raises(() -> store.put("k", bytes("12345")), ArgumentError);
		Assert.raises(() -> store.put("k", null), ArgumentError);
		Assert.raises(() -> store.get("123456789"), ArgumentError);
		Assert.raises(() -> store.delete(""), ArgumentError);
		Assert.raises(() -> store.scan({limit: 0}), ArgumentError);
		Assert.raises(() -> store.scan({limit: 21}), ArgumentError);
		Assert.raises(() -> store.scan({prefix: "123456789"}), ArgumentError);
		Assert.raises(() -> store.scan({startAfter: "a" + String.fromCharCode(0)}), ArgumentError);
		store.scan({limit: 20});
		Assert.isNull(store.get("k"), "nothing refused was written");
		store.close();

		Assert.raises(() -> make({maxKeyBytes: 0}), ArgumentError);
		Assert.raises(() -> make({maxKeyBytes: KVOptions.MOST_KEY_BYTES + 1}), ArgumentError);
		Assert.raises(() -> make({maxScanLimit: 0}), ArgumentError);
		Assert.raises(() -> make({maxPageBytes: 0}), ArgumentError);
		Assert.raises(() -> make({table: "kv; DROP TABLE users"}), ArgumentError);
	}

	public static function purgeRemovesOnlyOldTombstones(make:KVOptions->KVStore):Void {
		var clock = new TestClock();
		var store = make({clock: clock.read});
		store.put("old", bytes("a"));
		store.put("new", bytes("a"));
		store.put("live", bytes("a"));
		store.delete("old");
		clock.now += 100;
		store.delete("new");

		Assert.equals(1, store.purgeTombstones(clock.now - 50));
		Assert.same(["live", "new"], [for (r in store.scan({includeTombstones: true}).items) r.key]);
		Assert.equals(0, store.purgeTombstones(clock.now - 50));

		// With its tombstone gone the key starts again.
		Assert.equals(1.0, store.put("old", bytes("b")).revision);
		Assert.equals(1, store.purgeTombstones(clock.now + 1));
		Assert.same(["live", "old"], [for (r in store.scan({includeTombstones: true}).items) r.key]);
		store.close();
	}

	public static function aRollbackDiscardsEveryWrite(make:KVOptions->KVStore):Void {
		var store = make({});
		store.put("kept", bytes("before"));
		store.put("gone", bytes("before"));
		store.put("old", bytes("x"));
		store.delete("old");

		Assert.isFalse(store.inTransaction);
		store.begin();
		Assert.isTrue(store.inTransaction);
		store.put("kept", bytes("during"));
		store.put("kept", bytes("during again"));
		store.put("fresh", bytes("during"));
		store.delete("gone");
		// The tombstone from before, and the one just written.
		Assert.equals(2, store.purgeTombstones(1e15));
		Assert.equals("during again", text(store.get("kept")), "a transaction reads its own writes");
		store.rollback();

		Assert.isFalse(store.inTransaction);
		var kept = Require.notNull(store.get("kept"));
		Assert.equals("before", text(kept));
		Assert.equals(1.0, kept.revision);
		Assert.equals("before", text(store.get("gone")));
		Assert.isNull(store.get("fresh"));
		Assert.same(["gone", "kept", "old"], [for (r in store.scan({includeTombstones: true}).items) r.key]);
		Assert.equals(3.0, store.put("old", bytes("y")).revision, "the purged tombstone came back with its revision");

		// A rollback with none open does nothing, for a catch that cannot tell.
		store.rollback();
		store.close();
	}

	public static function aCommitKeepsEveryWrite(make:KVOptions->KVStore):Void {
		var store = make({});
		store.begin();
		store.put("a", bytes("1"));
		store.put("b", bytes("2"));
		Assert.raises(() -> store.begin(), IllegalOperationError);
		Assert.isTrue(store.inTransaction, "a refused begin leaves the transaction open");
		store.commit();

		Assert.isFalse(store.inTransaction);
		Assert.equals("1", text(store.get("a")));
		Assert.equals("2", text(store.get("b")));
		Assert.raises(() -> store.commit(), IllegalOperationError);
		store.close();
	}

	public static function aClosedStoreRefuses(make:KVOptions->KVStore):Void {
		var store = make({});
		store.put("k", bytes("v"));
		store.begin();
		store.put("k", bytes("w"));
		store.close();
		store.close();

		Assert.raises(() -> store.get("k"), IllegalOperationError);
		Assert.raises(() -> store.put("k", bytes("v")), IllegalOperationError);
		Assert.raises(() -> store.scan(), IllegalOperationError);
		Assert.raises(() -> store.begin(), IllegalOperationError);
		// What a pool or a catch asks of it as it is let go of still answers.
		Assert.isFalse(store.inTransaction);
		store.rollback();
	}
}
