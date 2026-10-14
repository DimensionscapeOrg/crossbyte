package crossbyte.db.kv;

#if target.threaded
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.db.kv.KVStoreChecks.text;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.sys.System;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	`AsyncKVStore` and `AsyncKVRepo`, wherever there are threads for their
	workers: each call answered by a future on the runtime that made it, at
	its next pass, while the runtime goes on; values copied as the call is
	made; refusals and transactions through the future. Behind it a
	`MemoryKVStore` on every such target, and natively a pool of SQLite
	stores on one file.
**/
class AsyncKVStoreTest extends utest.Test {
	private var __async:Null<AsyncKVStore> = null;

	public function teardown():Void {
		if (__async != null) {
			__async.shutdown();
			__async = null;
		}
	}

	/** One memory store for every place in a pool of `size`, behind an AsyncKVStore. **/
	private function __memory(size:Int = 2):AsyncKVStore {
		var store:KVStore = new MemoryKVStore();
		var pool = new ConnectionPool<KVStore>({factory: () -> store, close: s -> s.close(), maxSize: size});
		return __async = AsyncKVStore.of(pool);
	}

	/** Pumps the runtime until `future` is complete; whether it is. **/
	private static function __settle<T>(future:Future<T>, seconds:Float = 30):Bool {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (!future.completed && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			System.sleep(0.001);
		}

		return future.completed;
	}

	/** The value `future` settles with; stops the test when it fails or does not settle. **/
	private static function __value<T>(future:Future<T>):T {
		if (!__settle(future)) {
			throw "the future did not complete";
		}

		if (!future.succeeded) {
			throw 'the future failed: ${future.error}';
		}

		return future.result;
	}

	public function testEachCallIsAnsweredThroughAFuture():Void {
		var kv = __memory();
		var first = __value(kv.put("users/alice", bytes("one")));
		Assert.equals(1.0, first.revision);
		Assert.equals("one", text(__value(kv.get("users/alice"))));
		Assert.isNull(__value(kv.get("users/nobody")));

		Require.notNull(__value(kv.compareAndSet("users/alice", bytes("two"), first.revision)));
		Assert.isNull(__value(kv.compareAndSet("users/alice", bytes("three"), first.revision)), "a write from a stale read lost");
		Assert.isFalse(__value(kv.compareAndDelete("users/alice", first.revision)));

		__value(kv.put("users/bob", bytes("b")));
		var page = __value(kv.scan({prefix: "users/"}));
		Assert.same(["users/alice", "users/bob"], [for (record in page.items) record.key]);

		Assert.isTrue(__value(kv.delete("users/bob")));
		Assert.equals(1, __value(kv.purgeTombstones(1e15)));
		Assert.equals("two", text(__value(kv.submit(store -> store.get("users/alice")))));
	}

	public function testTheAnswerComesOnTheRuntimesThread():Void {
		// Whether the worker finishes before the callback is given (it is
		// called at once, by the call that gives it) or after (it is posted to
		// the runtime and called in its next pass), it runs on the runtime's
		// thread, never on the worker.
		var kv = __memory();
		var runtime:CrossByte = CrossByte.current();
		var seen:Array<Null<CrossByte>> = [];
		var futures:Array<Future<Int>> = [];

		for (i in 0...10) {
			var slow:Bool = i % 2 == 0;
			var future = kv.submit(function(store:KVStore):Int {
				if (slow) {
					System.sleep(0.05);
				}

				store.put("k" + i, bytes("v"));
				return i;
			});

			if (!slow) {
				// Done, most likely, before its callback is given.
				System.sleep(0.05);
			}

			future.then(_ -> seen.push(@:privateAccess CrossByte.__currentOrNull()));
			futures.push(future);
		}

		Assert.isTrue(__settle(Future.all(futures)));
		Assert.equals(10, seen.length);
		Assert.equals(0, [for (on in seen) if (on != runtime) on].length, "a callback ran off the runtime's thread");
	}

	public function testTheRuntimeDoesNotWaitForTheStore():Void {
		var kv = __memory();
		var started:Float = haxe.Timer.stamp();
		var slow = kv.submit(function(store:KVStore):Int {
			System.sleep(0.5);
			store.put("k", bytes("v"));
			return 1;
		});
		Assert.isTrue(haxe.Timer.stamp() - started < 0.25, "the call waited for the statement");
		Assert.equals(1, __value(slow));
	}

	public function testAValueIsCopiedAsTheCallIsMade():Void {
		var kv = __memory();
		var buffer = bytes("abc");
		var future = kv.put("k", buffer);
		// Reused at once, as a socket reuses what it read into.
		buffer.set(0, "z".code);
		__value(future);
		Assert.equals("abc", text(__value(kv.get("k"))));
	}

	public function testWritesPastTheQueuedBytesAreRefusedAtOnce():Void {
		// The one worker held: writes wait, and what they hold is counted.
		var kv = __memory(1);
		kv.maxQueuedBytes = 100;
		var gate = new sys.thread.Lock();
		var held = kv.submit(function(store:KVStore):Int {
			gate.wait(10);
			return 0;
		});

		var first = kv.put("a", Bytes.alloc(60));
		Assert.equals(60.0, kv.queuedBytes);
		var refused = kv.put("b", Bytes.alloc(60));
		Assert.isTrue(refused.completed, "refused at once, its value never copied");
		Assert.isFalse(refused.succeeded);
		Assert.isTrue(Std.isOfType(refused.cause, IllegalOperationError), Std.string(refused.cause));
		var fits = kv.compareAndSet("c", Bytes.alloc(40), 0);
		Assert.equals(100.0, kv.queuedBytes);

		gate.release();
		Assert.isTrue(__settle(Future.all([held, first.map(_ -> 0), fits.map(_ -> 0)])));
		Assert.equals(0.0, kv.queuedBytes, "a write done is let go of");
		Assert.isNull(__value(kv.get("b")));
		Assert.notNull(__value(kv.get("c")));

		// A repository's writes are counted too.
		kv.maxQueuedBytes = 4;
		var names = new AsyncKVRepo<String>(kv, "names/", KVCodecs.text());
		var tooLong = names.put("x", "longer than four");
		Assert.isTrue(tooLong.completed);
		Assert.isFalse(tooLong.succeeded);
		Assert.equals("ok", Require.notNull(__value(names.put("y", "ok"))).value);

		kv.maxQueuedBytes = 0;
		__value(kv.put("big", Bytes.alloc(1000)));
		Assert.raises(() -> kv.maxQueuedBytes = -1, ArgumentError);
		Assert.raises(() -> kv.maxQueuedBytes = Math.NaN, ArgumentError);
	}

	public function testARefusalFailsTheFutureWithTheStoresError():Void {
		var kv = __memory();
		var refused = kv.put("", bytes("v"));
		Assert.isTrue(__settle(refused));
		Assert.isFalse(refused.succeeded);
		Assert.isTrue(Std.isOfType(refused.cause, ArgumentError), Std.string(refused.cause));

		var thrown = kv.submit(function(store:KVStore):Int {
			throw new ArgumentError("from the body");
		});
		Assert.isTrue(__settle(thrown));
		Assert.isFalse(thrown.succeeded);
		Assert.equals("from the body", thrown.error);
	}

	public function testATransactionLandsWholeOrNotAtAll():Void {
		var kv = __memory();
		var rolledBack = kv.transaction(function(store:KVStore):Int {
			store.put("a", bytes("1"));
			store.put("b", bytes("2"));
			throw "changed my mind";
		});
		Assert.isTrue(__settle(rolledBack));
		Assert.isFalse(rolledBack.succeeded);
		Assert.isNull(__value(kv.get("a")), "a write of a transaction that threw was kept");
		Assert.isNull(__value(kv.get("b")));

		var committed = kv.transaction(function(store:KVStore):Float {
			store.put("a", bytes("1"));
			return store.put("b", bytes("2")).revision;
		});
		Assert.equals(1.0, __value(committed));
		Assert.equals("1", text(__value(kv.get("a"))));
		Assert.equals("2", text(__value(kv.get("b"))));
	}

	public function testCallsAfterShutdownFail():Void {
		var kv = __memory();
		kv.shutdown();
		__async = null;
		var late = kv.get("k");
		Assert.isTrue(__settle(late, 5));
		Assert.isFalse(late.succeeded);
	}

	public function testATypedRepositoryRunsOnTheWorkers():Void {
		var kv = __memory();
		var players = new AsyncKVRepo<{name:String, level:Int}>(kv, "players/", KVCodecs.json());
		var player = {name: "Alice", level: 1};
		var saved = __value(players.put("alice", player));
		// Encoded as the call was made: changing it now changes nothing kept.
		player.level = 99;
		Assert.equals("alice", saved.key);
		Assert.equals(1, Require.notNull(__value(players.get("alice"))).value.level);

		Require.notNull(__value(players.compareAndSet("alice", {name: "Alice", level: 2}, saved.revision)));
		Assert.isNull(__value(players.compareAndSet("alice", {name: "Alice", level: 3}, saved.revision)));
		__value(players.put("bob", {name: "Bob", level: 5}));
		var page = __value(players.scan({limit: 1}));
		Assert.same(["alice"], [for (item in page.items) item.key]);
		Assert.equals("alice", page.next);
		Assert.isFalse(__value(players.compareAndDelete("bob", 2)));
		Assert.isTrue(__value(players.delete("bob")));

		// Another schema's record fails the future with the KVError.
		var newer = new AsyncKVRepo<{name:String, level:Int}>(kv, "players/", KVCodecs.json(2));
		var refused = newer.get("alice");
		Assert.isTrue(__settle(refused));
		Assert.isFalse(refused.succeeded);
		Assert.isTrue(Std.isOfType(refused.cause, KVError));
		Assert.equals(KVErrorKind.SchemaMismatch, (cast refused.cause : KVError).kind);

		var tombstones = players.scan({includeTombstones: true});
		Assert.isTrue(__settle(tombstones));
		Assert.isFalse(tombstones.succeeded);
		Assert.raises(() -> new AsyncKVRepo<String>(null, "a/", KVCodecs.text()), ArgumentError);
	}

	#if cpp
	public function testPooledSQLiteStoresShareOneFile():Void {
		// Each place in the pool its own connection to the file; jobs from the
		// runtime adding to a counter by compare-and-set on whichever store
		// their worker holds: every add lands once.
		var path:String = haxe.io.Path.join([Sys.getCwd(), "export", "kv-async-" + Std.random(0x7FFFFFF) + ".db"]);
		var pool = new ConnectionPool<KVStore>({factory: () -> SQLiteKVStore.open(path), close: s -> s.close(), maxSize: 4});
		var kv = __async = AsyncKVStore.of(pool);
		__value(kv.put("counter", bytes("0")));

		var jobs:Array<Future<Int>> = [];

		for (j in 0...20) {
			jobs.push(kv.submit(function(store:KVStore):Int {
				var lost:Int = 0;

				for (i in 0...10) {
					while (true) {
						var read = store.get("counter");
						var next:Int = Std.parseInt(read.value.toString()) + 1;

						if (store.compareAndSet("counter", bytes(Std.string(next)), read.revision) != null) {
							break;
						}

						lost++;
					}
				}

				return lost;
			}));
		}

		var all = Future.all(jobs);
		Assert.isTrue(__settle(all, 120));
		Assert.isTrue(all.succeeded, all.error);
		var counter = Require.notNull(__value(kv.get("counter")));
		Assert.equals("200", text(counter));
		Assert.equals(201.0, counter.revision);

		kv.shutdown();
		__async = null;

		for (suffix in ["", "-wal", "-shm"]) {
			try {
				if (sys.FileSystem.exists(path + suffix)) {
					sys.FileSystem.deleteFile(path + suffix);
				}
			} catch (_:Dynamic) {}
		}
	}
	#end
}
#end
