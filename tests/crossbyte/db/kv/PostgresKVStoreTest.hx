package crossbyte.db.kv;

#if cpp
import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.db.kv.KVStoreChecks.text;
import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	`PostgresKVStore` against the stand-in libpq the bridge's own tests use
	(`fakepq/fake_libpq.c`), which keeps one key/value table for the process
	and answers the store's statements as a server would: what every store
	does (`KVStoreChecks`), bound values, and several connections at once.
	`PostgresIntegrationTest` runs the same checks against a real server, in
	the CI job that has one.
**/
@:buildXml('<include name="${haxelib:crossbyte}/tests/crossbyte/db/fakepq/FakeLibPQBuild.xml"/>')
class PostgresKVStoreTest extends utest.Test {
	public static function config():PostgresConfig {
		return {
			host: "localhost",
			port: 5432,
			user: "tester",
			password: "secret",
			database: "fake",
			libraryPath: switch (Sys.systemName().toLowerCase()) {
				case "windows": "crossbyte_fakepq.dll";
				case "mac": "crossbyte_fakepq.dylib";
				default: "crossbyte_fakepq.dso";
			}
		};
	}

	/** A store on a new connection, the stand-in's table emptied first. **/
	static function make(options:KVOptions):KVStore {
		var store = PostgresKVStore.open(config(), options);
		store.connection.request("fake:kv-clear");
		return store;
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

	public function testAValueGoesAsItsBytes():Void {
		// Bound as binary: a NUL, bytes that are no UTF-8, and a quote, which
		// a value written into the SQL would have to survive.
		var store = make({});
		var value = Bytes.ofHex("00ff27c3285c78");
		store.put("blob", value);
		Assert.equals("00ff27c3285c78", Require.notNull(store.get("blob")).value.toHex());
		Assert.equals("00ff27c3285c78", store.scan().items[0].value.toHex());
		store.close();
	}

	public function testAStoredValuePastTheLimitIsRefusedUnread():Void {
		var writer = make({});
		writer.put("a", Bytes.alloc(10));
		writer.put("b", Bytes.alloc(100));
		writer.put("c", Bytes.alloc(10));

		var reader = PostgresKVStore.open(config(), {maxValueBytes: 50, maxPageBytes: 15});
		Assert.equals(10, Require.notNull(reader.get("a")).value.length);
		var refused:KVError = Require.notNull(KVStoreChecks.kvError(() -> reader.get("b")));
		Assert.equals(KVErrorKind.TooLarge, refused.kind);

		var first = reader.scan();
		Assert.same(["a"], [for (r in first.items) r.key]);
		Assert.notNull(KVStoreChecks.kvError(() -> reader.scan({startAfter: first.next})));
		Assert.isTrue(reader.delete("b"));
		Assert.same(["c"], [for (r in reader.scan({startAfter: "a"}).items) r.key]);
		reader.close();
		writer.close();
	}

	public function testStoresOnTwoConnectionsSeeEachOthersWrites():Void {
		var one = make({});
		var two = PostgresKVStore.open(config());

		var read = one.put("k", bytes("a"));
		Assert.equals("a", text(two.get("k")));
		Require.notNull(two.compareAndSet("k", bytes("b"), read.revision));
		Assert.isNull(one.compareAndSet("k", bytes("c"), read.revision));
		Assert.equals("b", text(one.get("k")));
		one.close();
		two.close();
	}

	public function testCompareAndSetRacesAcrossConnectionsLoseWithoutLosingAWrite():Void {
		var setup = make({});
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
					var store = PostgresKVStore.open(config());

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
			Assert.isTrue(done.wait(60), "a thread did not finish");
		}

		Assert.same([], failures, failures.join("; "));
		var check = PostgresKVStore.open(config());
		var counter = Require.notNull(check.get("counter"));
		Assert.equals(Std.string(threads * each), text(counter));
		Assert.equals(threads * each + 1.0, counter.revision);
		check.close();
	}

	public function testAPoolRollsBackAStoreLeftInATransaction():Void {
		make({}).close();
		var pool = new ConnectionPool<KVStore>({
			factory: () -> PostgresKVStore.open(config()),
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
		Assert.raises(() -> new PostgresKVStore(null), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new PostgresKVStore(new PostgresConnection()), crossbyte.errors.ArgumentError);
	}
}
#end
