package crossbyte.io;

import crossbyte.Future;
import crossbyte.io.ByteArray;
import crossbyte.io.Store;
import utest.Assert;
import utest.Async;
import crossbyte.test.Require;

/**
 * The store, wherever it has a backend.
 *
 * Every case here is a way a store can lie rather than fail: a value that does
 * not survive a reopen, a missing key that reads as empty, a failed write that
 * leaves half a value, or bytes that differ between the target that wrote them
 * and the one that reads them. A store is trusted by definition -- nobody
 * checks that their save worked -- so quiet wrongness is the only kind that
 * matters.
 *
 * The browser runs these too, against IndexedDB, through the headless job.
 * That is the point of the API being one shape: the same assertions, both
 * backends, no target grading its own homework.
 *
 * ## Chained rather than nested
 *
 * These were written before `Future` could compose, so each step nested inside
 * the one before it -- five levels deep in places, with a failure handler
 * repeated at every level. The repetition was the real cost, not the
 * indentation: six copies of `failWith(async)` in one case is six places to
 * forget one, and a forgotten one turns a failing store into a case that hangs
 * until utest times it out and reports something unrelated to what broke.
 *
 * `flatMap` carries a failure down the whole chain, so each case has one
 * handler at its end and no intermediate one to omit.
 */
class StoreTest extends utest.Test {
	private static var counter:Int = 0;

	/** Every name handed out, so `teardownClass` can take back what the run made. */
	private static var created:Array<String> = [];

	/**
	 * A store name nothing else is using.
	 *
	 * Distinct per case because IndexedDB databases outlive a page and the
	 * file backend outlives a process: a shared name would let one run's
	 * leftovers decide the next run's result, which is the sort of test that
	 * passes until it is the only thing standing between you and a bug.
	 *
	 * Recorded on the way out, because a name is a directory (or a database)
	 * somebody has to remove later, and later is `teardownClass`.
	 */
	private function freshName():String {
		var name = "test-" + (counter++) + "-" + Std.int(haxe.Timer.stamp() * 1000);
		created.push(name);
		return name;
	}

	/**
	 * Removes every store this run created.
	 *
	 * Fresh names are the right design and litter is their cost: each case
	 * leaves a store the next run will never look at, and 462 of them had
	 * piled up under a roaming profile before anyone counted. The pile is
	 * paid for here rather than by sharing names, which would buy back the
	 * flakiness the naming exists to prevent.
	 *
	 * One name at a time rather than `Future.all`, so the run cannot end out
	 * from under the sweep -- and the failure arm walks on exactly like the
	 * success arm, because utest carries on after a failed case and one store
	 * that will not clear must not strand every store behind it.
	 */
	@:timeout(10000)
	public function teardownClass(async:Async):Void {
		removeCreated(0, async);
	}

	private static function removeCreated(index:Int, async:Async):Void {
		if (index >= created.length) {
			created = [];
			async.done();
			return;
		}

		var name = created[index];
		var store:Store = null;

		Store.open(name)
			.flatMap(function(opened:Store):Future<Store> {
				store = opened;
				return opened.clear();
			})
			.then(function(_):Void {
				store.close();
				removeStoreDirectory(name);
				removeCreated(index + 1, async);
			}, function(_):Void {
				if (store != null) {
					store.close();
				}
				removeCreated(index + 1, async);
			});
	}

	/**
	 * Removes what `clear()` leaves behind: the container itself.
	 *
	 * Clearing empties a store without removing it -- the file backend keeps
	 * the now-empty directory and IndexedDB keeps the database. Here the
	 * directory is within reach of the same filesystem the backend uses, so
	 * the sweep finishes the job; the browser offers no handle on the
	 * database through the Store API, so there the empty shell stays.
	 *
	 * The path restates FileStore's private layout, `<storage>/stores/<name>`.
	 * That coupling is accepted over exposing the path on the API for one
	 * test's benefit, and a drift in it shows up as directories in the
	 * verification listing rather than as anything silent.
	 */
	private static function removeStoreDirectory(name:String):Void {
		#if !(js && !nodejs)
		try {
			var directory = haxe.io.Path.join([File.applicationStorageDirectory.nativePath, "stores", name]);

			if (sys.FileSystem.exists(directory)) {
				sys.FileSystem.deleteDirectory(directory);
			}
		} catch (_:Dynamic) {}
		#end
	}

	private function bytesOf(text:String):ByteArray {
		var data = new ByteArray();
		data.writeUTFBytes(text);
		return data;
	}

	private function textOf(data:ByteArray):String {
		data.position = 0;
		return data.readUTFBytes(data.length);
	}

	/**
	 * Opens a fresh store, runs `body` against it, then clears and closes it.
	 *
	 * The open, the clear and the close were spelled out in every case, which
	 * is three chances per case to leave a store behind -- and a store left
	 * behind is a name the next run inherits, on backends that outlive the
	 * process. The single failure handler is here for the same reason: a case
	 * that chains through this cannot forget one, because there is only one.
	 */
	private function withStore<T>(async:Async, body:Store->Future<T>):Void {
		var store:Store = null;

		Store.open(freshName())
			.flatMap(function(opened:Store):Future<T> {
				store = opened;
				return body(store);
			})
			.flatMap(_ -> store.clear())
			.then(function(_):Void {
				store.close();
				async.done();
			}, failWith(async));
	}

	public function testAValueSurvivesCloseAndReopen(async:Async):Void {
		var name = freshName();
		var reopened:Store = null;

		Store.open(name)
			.flatMap(store -> store.put("token", bytesOf("abc123")))
			.flatMap(function(store:Store):Future<Store> {
				store.close();

				// A new Store over the same name, which is what a reload is.
				return Store.open(name);
			})
			.flatMap(function(store:Store):Future<Null<ByteArray>> {
				reopened = store;
				return store.get("token");
			})
			.flatMap(function(value:Null<ByteArray>):Future<Store> {
				Assert.notNull(value, "the value did not survive a reopen");
				Assert.equals("abc123", textOf(value));
				return reopened.clear();
			})
			.then(function(_):Void {
				reopened.close();
				async.done();
			}, failWith(async));
	}

	public function testAMissingKeyIsNullAndNotEmpty(async:Async):Void {
		withStore(async, store -> store.get("never-written")
			.flatMap(function(value:Null<ByteArray>):Future<Store> {
				// Null means absent. An empty ByteArray would mean "a value of
				// no bytes", and a caller that cannot tell those apart writes
				// the wrong thing back.
				Assert.isNull(value, "a key that was never written did not read as null");
				return store.put("empty", new ByteArray());
			})
			.flatMap(_ -> store.get("empty"))
			.map(function(stored:Null<ByteArray>):Bool {
				Require.notNull(stored, "a deliberately empty value read as absent");
				Assert.equals(0, stored.length);
				return true;
			}));
	}

	public function testOverwriteAndRemove(async:Async):Void {
		withStore(async, store -> store.put("k", bytesOf("first"))
			.flatMap(_ -> store.put("k", bytesOf("second")))
			.flatMap(_ -> store.get("k"))
			.flatMap(function(value:Null<ByteArray>):Future<Store> {
				Assert.equals("second", textOf(value));
				return store.remove("k");
			})
			.flatMap(_ -> store.get("k"))
			.flatMap(function(gone:Null<ByteArray>):Future<Store> {
				Assert.isNull(gone, "the key survived remove()");

				// Removing what is not there is not an error.
				return store.remove("k");
			}));
	}

	public function testKeysAndPrefix(async:Async):Void {
		withStore(async, store -> store.put("user:1", bytesOf("a"))
			.flatMap(_ -> store.put("user:2", bytesOf("b")))
			.flatMap(_ -> store.put("cache:1", bytesOf("c")))
			.flatMap(_ -> store.keys())
			.flatMap(function(all:Array<String>):Future<Array<String>> {
				Assert.equals(3, all.length);
				return store.keys("user:");
			})
			.flatMap(function(users:Array<String>):Future<Store> {
				users.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
				Assert.equals(2, users.length);
				Assert.equals("user:1", users[0]);
				Assert.equals("user:2", users[1]);
				return store.clear();
			})
			.flatMap(_ -> store.keys())
			.map(function(empty:Array<String>):Bool {
				Assert.equals(0, empty.length);
				return true;
			}));
	}

	public function testKeysAreNotConstrainedByTheFilesystem(async:Async):Void {
		// Every one of these is a legal key and an illegal or dangerous file
		// name: a path, a parent reference, a Windows device, and two that
		// differ only by case and would collide on a case-insensitive volume.
		var awkward = ["a/b", "..", "CON", "Token", "token", "with space", "unicode-éè"];

		// `Future.all` rather than a countdown counter closed over by every
		// callback, which is what this was -- and the counter version had to
		// nest the whole tail of the case inside the last write for it to run
		// at all.
		withStore(async, store -> Future.all([for (i in 0...awkward.length) store.put(awkward[i], bytesOf("value-" + i))])
			.flatMap(_ -> Future.all([for (key in awkward) store.get(key)]))
			.flatMap(function(values:Array<Null<ByteArray>>):Future<Array<String>> {
				for (i in 0...awkward.length) {
					Assert.notNull(values[i], "lost the key " + awkward[i]);
					Assert.equals("value-" + i, textOf(values[i]), "wrong value for the key " + awkward[i]);
				}

				return store.keys();
			})
			.map(function(all:Array<String>):Bool {
				Assert.equals(awkward.length, all.length, "keys() lost one: " + all);
				return true;
			}));
	}

	public function testBinaryValuesAreNotTextAndSurviveIntact(async:Async):Void {
		var raw = new ByteArray();
		for (i in 0...256) {
			raw.writeByte(i);
		}

		withStore(async, store -> store.put("binary", raw)
			.flatMap(_ -> store.get("binary"))
			.map(function(value:Null<ByteArray>):Bool {
				Assert.equals(256, value.length);

				var mismatch = -1;
				value.position = 0;
				for (i in 0...256) {
					// Unsigned, because readByte() sign-extends by design --
					// Flash semantics -- so byte 128 reads as -128 and the
					// first draft of this test blamed the store for it.
					if (value.readUnsignedByte() != i) {
						mismatch = i;
						break;
					}
				}

				// Every byte, including the NUL at zero, which a store that
				// went through a string somewhere would have truncated at.
				Assert.equals(-1, mismatch, "byte " + mismatch + " came back wrong");
				return true;
			}));
	}

	public function testTheCallerCanReuseItsBuffer(async:Async):Void {
		var buffer = bytesOf("original");

		withStore(async, store -> store.put("k", buffer)
			.flatMap(function(_):Future<Null<ByteArray>> {
				// The store copies on the way in, so this cannot reach back and
				// change what was stored. Handing a backend a live view of a
				// caller's buffer is how one write ends up holding another's
				// bytes -- the same hazard the Node socket and the WebSocket
				// output both had to be fixed for.
				buffer.clear();
				buffer.writeUTFBytes("changed");
				return store.get("k");
			})
			.map(function(value:Null<ByteArray>):Bool {
				Assert.equals("original", textOf(value));
				return true;
			}));
	}

	public function testAClosedStoreRefusesRatherThanIgnoring(async:Async):Void {
		// Deliberately not chained. `flatMap` exists to carry a failure past
		// everything downstream, and here the failures are the result -- a case
		// whose subject is the failure has to catch each one where it happens.
		Store.open(freshName()).then(store -> {
			store.close();

			store.put("k", bytesOf("v")).then(_ -> {
				Assert.fail("a closed store accepted a write");
				async.done();
			}, message -> {
				Assert.isTrue(message.indexOf("closed") >= 0, "unhelpful message: " + message);

				store.get("k").then(_ -> {
					Assert.fail("a closed store accepted a read");
					async.done();
				}, _ -> {
					async.done();
				});
			});
		}, failWith(async));
	}

	public function testAnEmptyKeyIsRefused(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.get("").then(_ -> {
				Assert.fail("an empty key was accepted");
				store.close();
				async.done();
			}, message -> {
				Assert.isTrue(message.indexOf("key") >= 0, "unhelpful message: " + message);
				store.close();
				async.done();
			});
		}, failWith(async));
	}

	public function testAnUnusableNameIsRefusedBeforeAnythingIsCreated():Void {
		// Thrown rather than returned as a failed Future, because this is a
		// programming error visible without running anything -- unlike a quota
		// or a permission, which are conditions of the machine.
		Assert.raises(() -> Store.open(""), crossbyte.errors.ArgumentError);
		Assert.raises(() -> Store.open("../escape"), crossbyte.errors.ArgumentError);
		Assert.raises(() -> Store.open("has/slash"), crossbyte.errors.ArgumentError);
	}

	public function testForEachVisitsEverythingWithoutHoldingIt(async:Async):Void {
		withStore(async, function(store:Store):Future<Bool> {
			var seen = new Map<String, String>();

			return Future.all([for (i in 0...20) store.putString("k" + i, "v" + i)])
				.flatMap(_ -> store.forEach(function(key:String, value:ByteArray):Bool {
					value.position = 0;
					seen.set(key, value.readUTFBytes(value.length));
					return true;
				}))
				.map(function(_):Bool {
					var count = 0;
					for (key in seen.keys()) {
						count++;
					}

					Assert.equals(20, count, "forEach missed entries");
					Assert.equals("v7", seen.get("k7"));
					return true;
				});
		});
	}

	public function testForEachStopsWhenAskedTo(async:Async):Void {
		withStore(async, function(store:Store):Future<Bool> {
			var visited = 0;

			return Future.all([for (i in 0...10) store.putString("k" + i, "v")])
				// Returning false is the early exit a cursor exists for. If it
				// were ignored, this would count ten and the method would be
				// `keys()` with extra steps.
				.flatMap(_ -> store.forEach(function(key:String, value:ByteArray):Bool {
					visited++;
					return visited < 3;
				}))
				.map(function(_):Bool {
					Assert.equals(3, visited, "forEach did not stop when asked");
					return true;
				});
		});
	}

	public function testForEachHonoursAPrefix(async:Async):Void {
		withStore(async, function(store:Store):Future<Bool> {
			var seen:Array<String> = [];

			return store.putString("user:1", "a")
				.flatMap(_ -> store.putString("cache:1", "b"))
				.flatMap(_ -> store.forEach(function(key:String, _):Bool {
					seen.push(key);
					return true;
				}, "user:"))
				.map(function(_):Bool {
					Assert.equals(1, seen.length, "prefix ignored: " + seen);
					Assert.equals("user:1", seen[0]);
					return true;
				});
		});
	}

	public function testStringsRoundTripAndAbsentIsStillNull(async:Async):Void {
		withStore(async, store -> store.putString("greeting", "hello ☃")
			.flatMap(_ -> store.getString("greeting"))
			.flatMap(function(text:Null<String>):Future<Store> {
				// UTF-8 through the byte layer and back, including a character
				// that is not one byte.
				Assert.equals("hello ☃", text);
				return store.putString("empty", "");
			})
			.flatMap(_ -> store.getString("empty"))
			.flatMap(function(blank:Null<String>):Future<Null<String>> {
				// An empty string is a value somebody stored.
				Assert.equals("", blank);
				return store.getString("never");
			})
			.map(function(missing:Null<String>):Bool {
				// Absent is still null, not "".
				Assert.isNull(missing, "a missing key read as an empty string");
				return true;
			}));
	}

	public function testTwoStoresOnOneNameDoNotCorruptEachOther(async:Async):Void {
		// The concurrency question, answered by measurement rather than by a
		// paragraph. Two Store instances over one name is what two CrossByte
		// runtimes in a process look like to the backend, and the claim being
		// tested is the modest one the design actually makes: writes are atomic
		// per key, so interleaving them yields one whole value or the other and
		// never half of each.
		var name = freshName();
		var first:Store = null;
		var second:Store = null;

		Store.open(name)
			.flatMap(function(opened:Store):Future<Store> {
				first = opened;
				return Store.open(name);
			})
			.flatMap(function(opened:Store):Future<Array<Store>> {
				second = opened;

				// Both writes outstanding together, which is the interleaving
				// under test. `Future.all` is what waits for both without a
				// completion count shared between two callbacks.
				return Future.all([
					first.putString("contested", "from-first"),
					second.putString("contested", "from-second").flatMap(_ -> second.putString("only-second", "visible"))
				]);
			})
			.flatMap(_ -> first.get("contested"))
			.flatMap(function(value:Null<ByteArray>):Future<Null<String>> {
				value.position = 0;
				var text = value.readUTFBytes(value.length);

				// Last writer wins, and which one that is is not promised. What
				// is promised is that it is one of them entire.
				Assert.isTrue(text == "from-first" || text == "from-second", "interleaved writes produced neither value: " + text);

				return first.getString("only-second");
			})
			.flatMap(function(sideEffect:Null<String>):Future<Store> {
				Assert.equals("visible", sideEffect, "a write through one handle was invisible to the other");
				return first.clear();
			})
			.then(function(_):Void {
				first.close();
				second.close();
				async.done();
			}, failWith(async));
	}

	private function failWith(async:Async):String->Void {
		return function(message:String):Void {
			Assert.fail(message);
			async.done();
		};
	}
}
