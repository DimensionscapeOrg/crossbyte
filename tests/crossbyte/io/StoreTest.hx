package crossbyte.io;

import crossbyte.io.ByteArray;
import crossbyte.io.Store;
import utest.Assert;
import utest.Async;

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
 */
class StoreTest extends utest.Test {
	private static var counter:Int = 0;

	/**
	 * A store name nothing else is using.
	 *
	 * Distinct per case because IndexedDB databases outlive a page and the
	 * file backend outlives a process: a shared name would let one run's
	 * leftovers decide the next run's result, which is the sort of test that
	 * passes until it is the only thing standing between you and a bug.
	 */
	private function freshName():String {
		return "test-" + (counter++) + "-" + Std.int(haxe.Timer.stamp() * 1000);
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

	public function testAValueSurvivesCloseAndReopen(async:Async):Void {
		var name = freshName();

		Store.open(name).then(store -> {
			store.put("token", bytesOf("abc123")).then(_ -> {
				store.close();

				// A new Store over the same name, which is what a reload is.
				Store.open(name).then(reopened -> {
					reopened.get("token").then(value -> {
						Assert.notNull(value, "the value did not survive a reopen");
						Assert.equals("abc123", textOf(value));
						reopened.clear().then(_ -> {
							reopened.close();
							async.done();
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testAMissingKeyIsNullAndNotEmpty(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.get("never-written").then(value -> {
				// Null means absent. An empty ByteArray would mean "a value of
				// no bytes", and a caller that cannot tell those apart writes
				// the wrong thing back.
				Assert.isNull(value, "a key that was never written did not read as null");

				store.put("empty", new ByteArray()).then(_ -> {
					store.get("empty").then(stored -> {
						Assert.notNull(stored, "a deliberately empty value read as absent");
						Assert.equals(0, stored.length);
						store.clear().then(_ -> {
							store.close();
							async.done();
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testOverwriteAndRemove(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.put("k", bytesOf("first")).then(_ -> {
				store.put("k", bytesOf("second")).then(_ -> {
					store.get("k").then(value -> {
						Assert.equals("second", textOf(value));

						store.remove("k").then(_ -> {
							store.get("k").then(gone -> {
								Assert.isNull(gone, "the key survived remove()");

								// Removing what is not there is not an error.
								store.remove("k").then(_ -> {
									store.close();
									async.done();
								}, failWith(async));
							}, failWith(async));
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testKeysAndPrefix(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.put("user:1", bytesOf("a")).then(_ -> {
				store.put("user:2", bytesOf("b")).then(_ -> {
					store.put("cache:1", bytesOf("c")).then(_ -> {
						store.keys().then(all -> {
							Assert.equals(3, all.length);

							store.keys("user:").then(users -> {
								users.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
								Assert.equals(2, users.length);
								Assert.equals("user:1", users[0]);
								Assert.equals("user:2", users[1]);

								store.clear().then(_ -> {
									store.keys().then(empty -> {
										Assert.equals(0, empty.length);
										store.close();
										async.done();
									}, failWith(async));
								}, failWith(async));
							}, failWith(async));
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testKeysAreNotConstrainedByTheFilesystem(async:Async):Void {
		// Every one of these is a legal key and an illegal or dangerous file
		// name: a path, a parent reference, a Windows device, and two that
		// differ only by case and would collide on a case-insensitive volume.
		var awkward = ["a/b", "..", "CON", "Token", "token", "with space", "unicode-éè"];

		Store.open(freshName()).then(store -> {
			var remaining = awkward.length;

			for (i in 0...awkward.length) {
				var key = awkward[i];

				store.put(key, bytesOf("value-" + i)).then(_ -> {
					store.get(key).then(value -> {
						Assert.notNull(value, "lost the key " + key);
						Assert.equals("value-" + i, textOf(value), "wrong value for the key " + key);

						if (--remaining == 0) {
							store.keys().then(all -> {
								Assert.equals(awkward.length, all.length, "keys() lost one: " + all);
								store.clear().then(_ -> {
									store.close();
									async.done();
								}, failWith(async));
							}, failWith(async));
						}
					}, failWith(async));
				}, failWith(async));
			}
		}, failWith(async));
	}

	public function testBinaryValuesAreNotTextAndSurviveIntact(async:Async):Void {
		var raw = new ByteArray();
		for (i in 0...256) {
			raw.writeByte(i);
		}

		Store.open(freshName()).then(store -> {
			store.put("binary", raw).then(_ -> {
				store.get("binary").then(value -> {
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

					store.clear().then(_ -> {
						store.close();
						async.done();
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testTheCallerCanReuseItsBuffer(async:Async):Void {
		var buffer = bytesOf("original");

		Store.open(freshName()).then(store -> {
			store.put("k", buffer).then(_ -> {
				// The store copies on the way in, so this cannot reach back and
				// change what was stored. Handing a backend a live view of a
				// caller's buffer is how one write ends up holding another's
				// bytes -- the same hazard the Node socket and the WebSocket
				// output both had to be fixed for.
				buffer.clear();
				buffer.writeUTFBytes("changed");

				store.get("k").then(value -> {
					Assert.equals("original", textOf(value));
					store.clear().then(_ -> {
						store.close();
						async.done();
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testAClosedStoreRefusesRatherThanIgnoring(async:Async):Void {
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
		Store.open(freshName()).then(store -> {
			var written = 0;

			for (i in 0...20) {
				store.putString("k" + i, "v" + i).then(_ -> {
					if (++written < 20) {
						return;
					}

					var seen = new Map<String, String>();

					store.forEach((key, value) -> {
						value.position = 0;
						seen.set(key, value.readUTFBytes(value.length));
						return true;
					}).then(_ -> {
						var count = 0;
						for (key in seen.keys()) {
							count++;
						}

						Assert.equals(20, count, "forEach missed entries");
						Assert.equals("v7", seen.get("k7"));

						store.clear().then(_ -> {
							store.close();
							async.done();
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}
		}, failWith(async));
	}

	public function testForEachStopsWhenAskedTo(async:Async):Void {
		Store.open(freshName()).then(store -> {
			var written = 0;

			for (i in 0...10) {
				store.putString("k" + i, "v").then(_ -> {
					if (++written < 10) {
						return;
					}

					var visited = 0;

					// Returning false is the early exit a cursor exists for. If
					// it were ignored, this would count ten and the method would
					// be `keys()` with extra steps.
					store.forEach((key, value) -> {
						visited++;
						return visited < 3;
					}).then(_ -> {
						Assert.equals(3, visited, "forEach did not stop when asked");

						store.clear().then(_ -> {
							store.close();
							async.done();
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}
		}, failWith(async));
	}

	public function testForEachHonoursAPrefix(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.putString("user:1", "a").then(_ -> {
				store.putString("cache:1", "b").then(_ -> {
					var seen:Array<String> = [];

					store.forEach((key, _) -> {
						seen.push(key);
						return true;
					}, "user:").then(_ -> {
						Assert.equals(1, seen.length, "prefix ignored: " + seen);
						Assert.equals("user:1", seen[0]);

						store.clear().then(_ -> {
							store.close();
							async.done();
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testStringsRoundTripAndAbsentIsStillNull(async:Async):Void {
		Store.open(freshName()).then(store -> {
			store.putString("greeting", "hello ☃").then(_ -> {
				store.getString("greeting").then(text -> {
					// UTF-8 through the byte layer and back, including a
					// character that is not one byte.
					Assert.equals("hello ☃", text);

					store.putString("empty", "").then(_ -> {
						store.getString("empty").then(blank -> {
							// An empty string is a value somebody stored.
							Assert.equals("", blank);

							store.getString("never").then(missing -> {
								// Absent is still null, not "".
								Assert.isNull(missing, "a missing key read as an empty string");

								store.clear().then(_ -> {
									store.close();
									async.done();
								}, failWith(async));
							}, failWith(async));
						}, failWith(async));
					}, failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	public function testTwoStoresOnOneNameDoNotCorruptEachOther(async:Async):Void {
		// The concurrency question, answered by measurement rather than by a
		// paragraph. Two Store instances over one name is what two CrossByte
		// runtimes in a process look like to the backend, and the claim being
		// tested is the modest one the design actually makes: writes are atomic
		// per key, so interleaving them yields one whole value or the other and
		// never half of each.
		var name = freshName();

		Store.open(name).then(first -> {
			Store.open(name).then(second -> {
				var done = 0;
				var finish = function():Void {
					if (++done < 2) {
						return;
					}

					first.get("contested").then(value -> {
						value.position = 0;
						var text = value.readUTFBytes(value.length);

						// Last writer wins, and which one that is is not
						// promised. What is promised is that it is one of them
						// entire.
						Assert.isTrue(text == "from-first" || text == "from-second", "interleaved writes produced neither value: " + text);

						first.getString("only-second").then(sideEffect -> {
							Assert.equals("visible", sideEffect, "a write through one handle was invisible to the other");

							first.clear().then(_ -> {
								first.close();
								second.close();
								async.done();
							}, failWith(async));
						}, failWith(async));
					}, failWith(async));
				};

				first.putString("contested", "from-first").then(_ -> finish(), failWith(async));
				second.putString("contested", "from-second").then(_ -> {
					second.putString("only-second", "visible").then(_ -> finish(), failWith(async));
				}, failWith(async));
			}, failWith(async));
		}, failWith(async));
	}

	private function failWith(async:Async):String->Void {
		return function(message:String):Void {
			Assert.fail(message);
			async.done();
		};
	}
}
