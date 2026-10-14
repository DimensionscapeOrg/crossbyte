package crossbyte.db.kv;

#if (cpp || php)
import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.db.kv.KVStoreChecks.text;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.errors.ArgumentError;
import crossbyte.test.Require;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import utest.Assert;

/**
	`SQLiteKVStore`, natively and on PHP, where SQLite opens a database: what
	every store does (`KVStoreChecks`) on a database in memory, and on files,
	what only a database on disk shows: a reopen, several connections, the
	table made once, a stored value past the limit.
**/
class SQLiteKVStoreTest extends utest.Test {
	private var __paths:Array<String> = [];

	static function make(options:KVOptions):KVStore {
		return SQLiteKVStore.open(null, options);
	}

	public function teardown():Void {
		for (path in __paths) {
			for (suffix in ["", "-journal", "-wal", "-shm"]) {
				try {
					if (FileSystem.exists(path + suffix)) {
						FileSystem.deleteFile(path + suffix);
					}
				} catch (_:Dynamic) {}
			}
		}

		__paths = [];
	}

	public function testWritesAndReads():Void {
		KVStoreChecks.writesAndReads(make);
	}

	public function testValuesAreTheCallersOwn():Void {
		KVStoreChecks.valuesAreTheCallersOwn(make);
	}

	public function testCompareAndSetWritesOnlyAtTheRevision():Void {
		KVStoreChecks.compareAndSetWritesOnlyAtTheRevision(make);
	}

	public function testDeletesLeaveTombstones():Void {
		KVStoreChecks.deletesLeaveTombstones(make);
	}

	public function testARevisionFromBeforeADeleteIsNotTheNextValues():Void {
		KVStoreChecks.aRevisionFromBeforeADeleteIsNotTheNextValues(make);
	}

	public function testCompareAndDeleteDeletesOnlyAtTheRevision():Void {
		KVStoreChecks.compareAndDeleteDeletesOnlyAtTheRevision(make);
	}

	public function testScansAreInCodePointOrder():Void {
		KVStoreChecks.scansAreInCodePointOrder(make);
	}

	public function testScansReadAPrefixOrARange():Void {
		KVStoreChecks.scansReadAPrefixOrARange(make);
	}

	public function testPagesReadEveryKeyOnce():Void {
		KVStoreChecks.pagesReadEveryKeyOnce(make);
	}

	public function testScansSkipTombstonesUnlessAsked():Void {
		KVStoreChecks.scansSkipTombstonesUnlessAsked(make);
	}

	public function testAPageEndsAtItsBytes():Void {
		KVStoreChecks.aPageEndsAtItsBytes(make);
	}

	public function testRefusesWhatItWouldNotHold():Void {
		KVStoreChecks.refusesWhatItWouldNotHold(make);
	}

	public function testPurgeRemovesOnlyOldTombstones():Void {
		KVStoreChecks.purgeRemovesOnlyOldTombstones(make);
	}

	public function testARollbackDiscardsEveryWrite():Void {
		KVStoreChecks.aRollbackDiscardsEveryWrite(make);
	}

	public function testACommitKeepsEveryWrite():Void {
		KVStoreChecks.aCommitKeepsEveryWrite(make);
	}

	public function testAClosedStoreRefuses():Void {
		KVStoreChecks.aClosedStoreRefuses(make);
	}

	public function testRecordsOutliveTheConnection():Void {
		var path = __path("reopen");
		var store = SQLiteKVStore.open(path);
		store.put("k", bytes("kept"));
		store.put("k", bytes("kept again"));
		store.put("gone", bytes("x"));
		store.delete("gone");
		store.close();

		var again = SQLiteKVStore.open(path);
		var record = Require.notNull(again.get("k"));
		Assert.equals("kept again", text(record));
		Assert.equals(2.0, record.revision);
		Assert.isNull(again.get("gone"));
		Assert.equals(3.0, again.put("gone", bytes("y")).revision, "the tombstone outlived the connection too");
		again.close();
	}

	public function testTheTableIsMadeOnceAndRecorded():Void {
		var path = __path("migrations");
		SQLiteKVStore.open(path).close();
		SQLiteKVStore.open(path).close();

		var connection = new SQLiteConnection();
		connection.open(path);
		var applied = [for (row in connection.request("SELECT version FROM kv_migrations")) Std.int(row.version)];
		Assert.same([1], applied);
		connection.close();

		// A table of its own beside it, and its records apart.
		var users = SQLiteKVStore.open(path, {table: "users"});
		var kv = SQLiteKVStore.open(path);
		users.put("a", bytes("user"));
		kv.put("a", bytes("kv"));
		Assert.equals("user", text(users.get("a")));
		Assert.equals("kv", text(kv.get("a")));
		users.close();
		kv.close();
	}

	public function testStoresOnOneFileSeeEachOthersWrites():Void {
		var path = __path("shared");
		var one = SQLiteKVStore.open(path);
		var two = SQLiteKVStore.open(path);

		var read = one.put("k", bytes("a"));
		Assert.equals("a", text(two.get("k")));

		// The other connection writes in between: the write from the stale
		// read loses, whichever connection makes it.
		Require.notNull(two.compareAndSet("k", bytes("b"), read.revision));
		Assert.isNull(one.compareAndSet("k", bytes("c"), read.revision));
		Assert.equals("b", text(one.get("k")));
		one.close();
		two.close();
	}

	public function testAStoredValuePastTheLimitIsRefusedUnread():Void {
		var path = __path("large");
		var writer = SQLiteKVStore.open(path);
		writer.put("a", Bytes.alloc(10));
		writer.put("b", Bytes.alloc(100));
		writer.put("c", Bytes.alloc(10));
		writer.close();

		// The limit lowered since, or the row written by something else.
		var reader = SQLiteKVStore.open(path, {maxValueBytes: 50, maxPageBytes: 15});
		Assert.equals(10, Require.notNull(reader.get("a")).value.length);
		var refused:KVError = Require.notNull(KVStoreChecks.kvError(() -> reader.get("b")));
		Assert.equals(KVErrorKind.TooLarge, refused.kind);
		Assert.equals("b", refused.key);

		// A page that ends before it never reaches it.
		var first = reader.scan();
		Assert.same(["a"], [for (r in first.items) r.key]);
		Assert.raises(() -> reader.scan({startAfter: first.next}), KVError);
		Assert.same(["c"], [for (r in reader.scan({startAfter: "b"}).items) r.key]);

		// It can still be deleted, which reads nothing of it.
		Assert.isTrue(reader.delete("b"));
		Assert.isNull(reader.get("b"));
		reader.close();
	}

	public function testATransactionTakesInTheConnectionsOwnStatements():Void {
		var store = SQLiteKVStore.open(null);
		store.connection.request("CREATE TABLE audit (line TEXT)");

		store.begin();
		store.put("k", bytes("v"));
		store.connection.request("INSERT INTO audit VALUES ('wrote k')");
		store.rollback();

		Assert.isNull(store.get("k"));
		Assert.equals(0, [for (row in store.connection.request("SELECT line FROM audit")) row].length);
		store.close();
	}

	public function testAPoolRollsBackAStoreLeftInATransaction():Void {
		var path = __path("pool");
		SQLiteKVStore.open(path).close();
		var pool = new ConnectionPool<KVStore>({
			factory: () -> SQLiteKVStore.open(path),
			close: store -> store.close(),
			maxSize: 1
		});

		var borrowed = pool.acquire();
		borrowed.begin();
		borrowed.put("k", bytes("never committed"));
		pool.release(borrowed);

		var next = pool.acquire();
		Assert.isFalse(next.inTransaction);
		Assert.isNull(next.get("k"));
		pool.release(next);
		pool.close();
	}

	public function testRefusesAConnectionItCannotUse():Void {
		Assert.raises(() -> new SQLiteKVStore(null), ArgumentError);
		var closed = new SQLiteConnection();
		Assert.raises(() -> new SQLiteKVStore(closed), ArgumentError);
	}

	#if cpp
	public function testCompareAndSetRacesAcrossConnectionsLoseWithoutLosingAWrite():Void {
		// Threads each with their own connection to one file, adding one to a
		// counter by compare-and-set: every add lands once.
		var path = __path("race");
		var setup = SQLiteKVStore.open(path);
		setup.put("counter", bytes("0"));
		setup.close();

		var threads:Int = 4;
		var each:Int = 100;
		var done = new sys.thread.Lock();
		var guard = new sys.thread.Mutex();
		var failures:Array<String> = [];

		for (t in 0...threads) {
			sys.thread.Thread.create(function():Void {
				try {
					var store = SQLiteKVStore.open(path);

					for (i in 0...each) {
						while (true) {
							var read = store.get("counter");
							var next:Int = Std.parseInt(read.value.toString()) + 1;

							if (store.compareAndSet("counter", bytes(Std.string(next)), read.revision) != null) {
								break;
							}
						}
					}

					store.close();
				} catch (e:Dynamic) {
					guard.acquire();
					failures.push(Std.string(e));
					guard.release();
				}

				done.release();
			});
		}

		for (t in 0...threads) {
			Assert.isTrue(done.wait(120), "a thread did not finish");
		}

		Assert.same([], failures, failures.join("; "));
		var check = SQLiteKVStore.open(path);
		var counter = Require.notNull(check.get("counter"));
		Assert.equals(Std.string(threads * each), text(counter));
		Assert.equals(threads * each + 1.0, counter.revision);
		check.close();
	}

	public function testStoresOpeningOnANewFileAtOnceAllOpen():Void {
		// A pool's connections can open together: one makes the table, and
		// the others wait for it and then find it made.
		var path = __path("together");
		var threads:Int = 6;
		var done = new sys.thread.Lock();
		var guard = new sys.thread.Mutex();
		var failures:Array<String> = [];

		for (t in 0...threads) {
			sys.thread.Thread.create(function():Void {
				try {
					var store = SQLiteKVStore.open(path);
					store.put("t" + t, bytes("x"));
					store.close();
				} catch (e:Dynamic) {
					guard.acquire();
					failures.push(Std.string(e));
					guard.release();
				}

				done.release();
			});
		}

		for (t in 0...threads) {
			Assert.isTrue(done.wait(60));
		}

		Assert.same([], failures, failures.join("; "));
		var check = SQLiteKVStore.open(path);
		Assert.equals(threads, check.scan().items.length);
		check.close();
	}
	#end

	private function __path(name:String):String {
		var directory:String = Path.join([Sys.getCwd(), "export"]);

		if (!FileSystem.exists(directory)) {
			FileSystem.createDirectory(directory);
		}

		var path:String = Path.join([directory, "kv-" + name + "-" + Std.random(0x7FFFFFF) + ".db"]);
		__paths.push(path);
		return path;
	}
}
#end
