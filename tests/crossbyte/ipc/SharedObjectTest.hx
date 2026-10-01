package crossbyte.ipc;

import haxe.Timer;
import utest.Assert;

@:access(crossbyte.ipc.SharedObject)
class SharedObjectTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(SharedObject.isSupported);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testConstructingUnsupportedTargetThrows():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(SharedObject.isSupported);
		#else
		var name:String = "crossbyte_sharedobject_test_" + Std.int(Timer.stamp() * 1000);
		Assert.isTrue(throws(function() {
			new SharedObject(name);
		}));
		#end
	}

	public function testSharedObjectRoundTrip():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("roundtrip");
		var writer = null;
		var reader = null;
		try {
			writer = new SharedObject(name, 8192);
			writer.data = {message: "hello", value: 42, active: true};
			writer.flush();

			reader = new SharedObject(name, 8192);
			Assert.equals("hello", reader.data.message);
			Assert.equals(42, reader.data.value);
			Assert.equals(true, reader.data.active);

			reader.data.value = 99;
			reader.flush();
			writer.sync();

			Assert.equals(99, writer.data.value);

			writer.clear();
			Assert.equals(0, Reflect.fields(writer.data).length);
		} catch (e:Dynamic) {
			if (reader != null) {
				reader.close();
			}
			if (writer != null) {
				writer.close();
			}
			throw e;
		}
		if (reader != null) {
			reader.close();
		}
		if (writer != null) {
			writer.close();
		}
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testSanitizedNameCollisionsStayIsolated():Void {
		#if (cpp && (windows || linux || mac || macos))
		var base:String = uniqueName("alias");
		var first:SharedObject = null;
		var second:SharedObject = null;
		var third:SharedObject = null;
		try {
			first = new SharedObject(base + "/same", 8192);
			second = new SharedObject(base + ":same", 8192);
			third = new SharedObject(base + "_same", 8192);

			first.data = {value: "slash"};
			second.data = {value: "colon"};
			third.data = {value: "underscore"};
			first.flush();
			second.flush();
			third.flush();

			first.sync();
			second.sync();
			third.sync();
			Assert.equals("slash", first.data.value);
			Assert.equals("colon", second.data.value);
			Assert.equals("underscore", third.data.value);
		} catch (e:Dynamic) {
			closeIfOpen(first);
			closeIfOpen(second);
			closeIfOpen(third);
			throw e;
		}
		closeIfOpen(first);
		closeIfOpen(second);
		closeIfOpen(third);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testOversizedPayloadThrows():Void {
		#if (cpp && (windows || linux || mac || macos))
		var shared:SharedObject = null;
		try {
			shared = new SharedObject(uniqueName("oversized"), 32);
			shared.data = {message: "this payload should be much larger than the tiny shared object capacity"};
			Assert.isTrue(throws(function() {
				shared.flush();
			}));
		} catch (e:Dynamic) {
			closeIfOpen(shared);
			throw e;
		}
		closeIfOpen(shared);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testClosedSharedObjectRejectsOperations():Void {
		#if (cpp && (windows || linux || mac || macos))
		var shared = new SharedObject(uniqueName("closed"), 8192);
		shared.close();
		Assert.isTrue(throws(function() {
			shared.flush();
		}));
		Assert.isTrue(throws(function() {
			shared.sync();
		}));
		Assert.isTrue(throws(function() {
			shared.clear();
		}));
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	/**
		A sync made while another handle flushes reads one whole payload.

		The length and the bytes were read under two acquisitions of the
		region's lock, so a flush between them left a copy cut to the old
		length, or one shorter than the new. The first failed to parse and
		`sync()` swapped in `{}` -- which a participant then flushing wrote
		over the shared state -- and the second threw. Over three seconds of
		a second handle flushing payloads of varying length, 176,256 syncs
		read `{}` and 2,923 threw.
	**/
	@:timeout(30000)
	public function testASyncWhileAnotherHandleFlushesReadsAWholePayload():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("torn");
		var writer = new SharedObject(name, 65536);
		var reader = new SharedObject(name, 65536);
		var stop = new sys.thread.Deque<Bool>();
		var stopped = new sys.thread.Deque<Bool>();
		// Never empty from here on, so `{}` can only be a read gone wrong.
		writer.data = {n: -1, length: 0, pad: ""};
		writer.flush();

		sys.thread.Thread.create(function():Void {
			var i:Int = 0;
			while (stop.pop(false) == null) {
				// A length that moves on every flush, and says what it was.
				var length:Int = (i * 37) % 3000;
				writer.data = {n: i, length: length, pad: StringTools.lpad("", "x", length)};
				writer.flush();
				i++;
			}
			stopped.add(true);
		});

		var syncs:Int = 0;
		var empty:Int = 0;
		var torn:Int = 0;
		var threw:Int = 0;
		var until:Float = Timer.stamp() + 1.0;

		while (Timer.stamp() < until) {
			try {
				reader.sync();
				var data:Dynamic = reader.data;
				if (data.n == null) {
					empty++;
				} else if (data.pad.length != data.length) {
					torn++;
				}
			} catch (_:Dynamic) {
				threw++;
			}
			syncs++;
		}

		stop.add(true);
		stopped.pop(true);
		writer.close();
		reader.close();

		Assert.isTrue(syncs > 0);
		Assert.equals(0, empty + torn + threw, '$syncs syncs: $empty read as {}, $torn torn, $threw threw');
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	/**
		A payload that cannot be read is not replaced with `{}`.

		`sync()` throws and leaves `data` as it was: swapping in an empty
		object meant the next flush wrote it over whatever the region held.
	**/
	public function testASyncOfAPayloadThatCannotBeReadKeepsTheData():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("unreadable");
		var shared = new SharedObject(name, 8192);
		var other = new SharedObject(name, 8192);
		shared.data = {kept: "yes"};
		shared.flush();
		shared.sync();

		// What another program, or a build knowing a class this one does
		// not, might leave in the region.
		var garbage = haxe.io.Bytes.ofString("#not a serialized value");
		Assert.isTrue(SharedObject.__write(other.__handle, garbage.getData(), garbage.length));

		var raised:Dynamic = null;
		try {
			shared.sync();
		} catch (e:Dynamic) {
			raised = e;
		}

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "sync() did not throw an IOError: " + raised);
		Assert.equals("yes", shared.data.kept);
		other.close();
		shared.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	/**
		The constructor starts from `defaultData` when the region's payload
		cannot be read, as it does when the region is empty. It started from
		`{}` and dropped what it was given.
	**/
	public function testTheConstructorStartsFromDefaultDataWhenThePayloadCannotBeRead():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("defaults");
		var holder = new SharedObject(name, 8192);
		var garbage = haxe.io.Bytes.ofString("#not a serialized value");
		Assert.isTrue(SharedObject.__write(holder.__handle, garbage.getData(), garbage.length));

		var opened = new SharedObject(name, 8192, {fallback: true});
		Assert.equals(true, opened.data.fallback);

		// And from what the region holds, when it can be read.
		holder.data = {held: 1};
		holder.flush();
		var again = new SharedObject(name, 8192, {fallback: true});
		Assert.equals(1, again.data.held);
		Assert.isNull(again.data.fallback);

		again.close();
		opened.close();
		holder.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	#if (cpp && linux)
	/**
		A region found before its creator sized it is sized here, not refused.

		On Linux and macOS the creator made a region and sized it in two
		steps, before taking the lock, and a handle opening the name between
		them found it empty: "Failed to create or open shared object". Linux
		keeps a region as a file under /dev/shm, so the moment is made here
		by hand and held still -- an empty file under the region's name.
	**/
	public function testARegionFoundBeforeItWasSizedIsSizedNotRefused():Void {
		var name:String = uniqueName("unsized");
		var path:String = posixRegionPath(name);
		sys.io.File.saveBytes(path, haxe.io.Bytes.alloc(0));

		var shared:SharedObject = null;
		try {
			shared = new SharedObject(name, 8192);
		} catch (e:Dynamic) {
			Assert.fail("opening a region not yet sized threw: " + e);
		}

		if (shared != null) {
			Assert.equals(8192, shared.__capacity);
			// The file made above is the region: sized now, by this handle.
			Assert.equals(12 + 8192, sys.FileSystem.stat(path).size);
			shared.data = {sized: true};
			shared.flush();
			shared.sync();
			Assert.equals(true, shared.data.sized);
			shared.close();
		}
		sys.FileSystem.deleteFile(path);
	}

	/**
		A handle asking for more than a region has is told what it has.

		Whichever participant took the lock first set up the header with its
		own `maxSize`, so one that opened a smaller region first was told it
		could flush that much, and wrote past the end of the mapping. Made
		here by hand: the region's file at the size a creator asking for 64
		bytes gives it, with no header yet -- that creator between sizing the
		region and taking the lock.
	**/
	public function testAHandleAskingForMoreThanARegionHasIsToldWhatItHas():Void {
		var name:String = uniqueName("small");
		var path:String = posixRegionPath(name);
		// The 12-byte header, then 64 of payload; all zero, so no header yet.
		sys.io.File.saveBytes(path, haxe.io.Bytes.alloc(12 + 64));

		var shared = new SharedObject(name, 8192);
		// The file made above is the region, at the size it was made.
		Assert.equals(12 + 64, sys.FileSystem.stat(path).size);
		Assert.equals(64, shared.__capacity);

		shared.data = {fill: StringTools.lpad("", "z", 40)};
		shared.flush();
		shared.sync();
		Assert.equals(40, shared.data.fill.length);

		shared.data = {fill: StringTools.lpad("", "z", 4000)};
		Assert.isTrue(throws(function() {
			shared.flush();
		}), "a flush larger than the region was taken");

		shared.close();
		sys.FileSystem.deleteFile(path);
	}

	/**
		Where Linux keeps a region: the name the native side gives it -- the
		name made safe, then its FNV-1a hash -- as a file under /dev/shm. The
		native side seeds the hash with 1469598103934665603, not FNV's own
		14695981039346656037; any seed hashes, and changing it would part a
		process built before the change from one built after.
	**/
	private static function posixRegionPath(name:String):String {
		var bytes = haxe.io.Bytes.ofString(name);
		var hash:haxe.Int64 = haxe.Int64.make(0x14650fb0, 0x739d0383);
		var prime:haxe.Int64 = haxe.Int64.make(0x100, 0x000001b3);
		var safe = new StringBuf();
		for (i in 0...bytes.length) {
			var c:Int = bytes.get(i);
			hash = (hash ^ haxe.Int64.ofInt(c)) * prime;
			var kept:Bool = (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code
				|| c == "_".code;
			safe.addChar(kept ? c : "_".code);
		}
		var hex:String = (StringTools.hex(hash.high, 8) + StringTools.hex(hash.low, 8)).toLowerCase();
		return "/dev/shm/crossbyte_shared_object_" + safe.toString() + "_" + hex;
	}
	#end

	/**
		How long a region lives, which differs by OS and is documented on the
		class: on Windows it goes with the last handle to it in any process,
		and on Linux and macOS it stays until the machine restarts.
	**/
	public function testARegionOutlivesItsLastHandleOnlyOnLinuxAndMacOS():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("lifetime");
		var first = new SharedObject(name, 8192);
		first.data = {left: "behind"};
		first.flush();
		first.close();

		var second = new SharedObject(name, 8192);
		#if windows
		Assert.isNull(second.data.left);
		#else
		Assert.equals("behind", second.data.left);
		#end
		second.clear();
		second.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	private static function uniqueName(label:String):String {
		return "crossbyte_sharedobject_" + label + "_" + Std.int(Timer.stamp() * 1000) + "_" + Std.random(1000000);
	}

	private static function closeIfOpen(shared:SharedObject):Void {
		if (shared != null) {
			shared.close();
		}
	}

	private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
