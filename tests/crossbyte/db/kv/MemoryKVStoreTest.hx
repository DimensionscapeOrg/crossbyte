package crossbyte.db.kv;

import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.db.kv.KVStoreChecks.text;
import crossbyte.test.Require;
import utest.Assert;
#if target.threaded
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
	`MemoryKVStore`, on every target: what every store does (`KVStoreChecks`),
	and, where there are threads, its calls and transactions from several at
	once.
**/
class MemoryKVStoreTest extends utest.Test {
	static function make(options:KVOptions):KVStore {
		return new MemoryKVStore(options);
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

	public function testManyKeysStayInOrderThroughWritesAndPurges():Void {
		// Past a run of SortedKeys several times over, written out of order,
		// half deleted and purged: the scan still reads every live key once,
		// in order.
		var store = new MemoryKVStore();
		var keys:Array<String> = [];

		for (i in 0...5000) {
			// A step coprime to 5000, so the keys go in out of order.
			keys.push("k" + StringTools.lpad(Std.string((i * 3001) % 5000), "0", 4));
		}

		for (key in keys) {
			store.put(key, bytes(key));
		}

		for (i in 0...5000) {
			if (i % 2 == 1) {
				store.delete(keys[i]);
			}
		}

		Assert.equals(2500, store.purgeTombstones(1e15));
		Assert.equals(2500, store.count());

		var seen:Array<String> = [];
		var page = store.scan({limit: 1000});

		while (true) {
			for (record in page.items) {
				seen.push(record.key);
			}

			if (page.next == null) {
				break;
			}

			page = store.scan({limit: 1000, startAfter: page.next});
		}

		var live:Array<String> = [for (i in 0...5000) if (i % 2 == 0) keys[i]];
		live.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		Assert.same(live, seen);
	}

	public function testCompareAndSetRacesLoseWithoutLosingAWrite():Void {
		#if target.threaded
		// Threads adding one to a counter by reading it and writing it back
		// at the revision read: every add lands once, whatever the
		// interleaving, and the ones that lost a race were told so.
		var store = new MemoryKVStore();
		store.put("counter", bytes("0"));
		var threads:Int = 4;
		var each:Int = #if (eval || neko) 50 #else 500 #end;
		var done = new Lock();
		var guard = new Mutex();
		var lost:Int = 0;
		var failures:Array<String> = [];

		for (t in 0...threads) {
			Thread.create(function():Void {
				var mine:Int = 0;

				try {
					for (i in 0...each) {
						while (true) {
							var read = store.get("counter");
							var next:Int = Std.parseInt(read.value.toString()) + 1;

							if (store.compareAndSet("counter", bytes(Std.string(next)), read.revision) != null) {
								break;
							}

							mine++;
						}
					}
				} catch (e:Dynamic) {
					guard.acquire();
					failures.push(Std.string(e));
					guard.release();
				}

				guard.acquire();
				lost += mine;
				guard.release();
				done.release();
			});
		}

		for (t in 0...threads) {
			Assert.isTrue(done.wait(60), "a thread did not finish");
		}

		Assert.same([], failures);
		var counter = Require.notNull(store.get("counter"));
		Assert.equals(Std.string(threads * each), text(counter));
		Assert.equals(threads * each + 1.0, counter.revision);
		Assert.isTrue(lost >= 0);
		#else
		Assert.pass();
		#end
	}

	public function testATransactionHoldsTheStoreForItsThread():Void {
		#if target.threaded
		// Another thread's write waits for the transaction to end, so it
		// neither lands inside it nor is undone by its rollback.
		var store = new MemoryKVStore();
		store.put("k", bytes("before"));
		store.begin();
		store.put("k", bytes("inside"));

		var started = new Lock();
		var finished = new Lock();
		var wrote:Null<KVRecord> = null;
		var sawOpen:Null<Bool> = null;

		Thread.create(function():Void {
			started.release();
			sawOpen = store.inTransaction;
			wrote = store.put("k", bytes("other"));
			finished.release();
		});

		Assert.isTrue(started.wait(10));
		Assert.isFalse(finished.wait(0.2), "a write from another thread went through an open transaction");
		Assert.isNull(wrote);
		store.rollback();

		Assert.isTrue(finished.wait(10));
		Assert.equals(false, sawOpen, "another thread's transaction is not its own");
		Assert.equals(2.0, Require.notNull(wrote).revision, "it wrote over what the rollback put back");
		Assert.equals("other", text(store.get("k")));
		#else
		Assert.pass();
		#end
	}
}
