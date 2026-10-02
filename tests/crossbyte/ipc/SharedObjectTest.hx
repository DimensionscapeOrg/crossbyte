package crossbyte.ipc;

import haxe.Timer;
import utest.Assert;

@:access(crossbyte.ipc.SharedObject)
class SharedObjectTest extends utest.Test {
	// Every name a case opened, so teardown can take the regions away: on
	// Linux and macOS they outlived the run, one more set each time.
	private static var __names:Array<String> = [];

	public function teardown():Void {
		#if (cpp && (windows || linux || mac || macos))
		for (name in __names) {
			try {
				SharedObject.remove(name);
			} catch (_:Dynamic) {}
		}
		#end
		__names = [];
	}

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
		// Not an ArgumentError, which says the arguments were wrong: nothing
		// here could have made them right.
		Assert.raises(function() {
			new SharedObject(name);
		}, crossbyte.errors.IllegalOperationError);
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
			first = new SharedObject(tracked(base + "/same"), 8192);
			second = new SharedObject(tracked(base + ":same"), 8192);
			third = new SharedObject(tracked(base + "_same"), 8192);

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
		`sync()` swapped in `{}`, which a participant then flushing wrote
		over the shared state, and the second threw. Over three seconds of
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
		Assert.isTrue(SharedObject.__write(other.__handle, garbage.getData(), garbage.length, other.lockTimeout));

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
		A payload whose values nest more than 256 deep cannot be read: `sync()`
		throws and keeps `data`, and the constructor starts from `defaultData`.
		Reading takes a frame or two per level, and natively a payload nested
		6,000 deep, 12 KB, which any process writing the region could leave,
		overflowed the stack and ended the process reading it, past any
		catch.
	**/
	public function testAPayloadNestedPastTheBoundCannotBeRead():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("nested");
		var holder = new SharedObject(name, 65536);
		var reader = new SharedObject(name, 65536);
		function leave(levels:Int):Void {
			var payload = haxe.io.Bytes.ofString(StringTools.lpad("", "a", levels) + StringTools.lpad("", "h", levels));
			Assert.isTrue(SharedObject.__write(holder.__handle, payload.getData(), payload.length, holder.lockTimeout));
		}

		leave(256);
		reader.sync();
		Assert.isTrue(Std.isOfType(reader.data, Array), "256 levels were not read");

		for (levels in [257, 6000]) {
			leave(levels);
			var raised:Dynamic = null;
			try {
				reader.sync();
			} catch (e:Dynamic) {
				raised = e;
			}
			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), '$levels levels: sync() threw ' + raised);
			Assert.isTrue(Std.string(raised).indexOf("nested more than 256 levels deep") >= 0, '$levels levels: ' + raised);
			Assert.isTrue(Std.isOfType(reader.data, Array), '$levels levels: data was replaced');

			var opened = new SharedObject(name, 65536, {fallback: true});
			Assert.equals(true, opened.data.fallback, '$levels levels: the constructor did not start from defaultData');
			opened.close();
		}

		reader.close();
		holder.close();
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
		Assert.isTrue(SharedObject.__write(holder.__handle, garbage.getData(), garbage.length, holder.lockTimeout));

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
		by hand and held still, an empty file under the region's name.
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
		bytes gives it, with no header yet, that creator between sizing the
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
		Where Linux keeps a region: the name the native side gives it, the
		name made safe, then its hash (`nameHash`), as a file under
		/dev/shm.
	**/
	private static function posixRegionPath(name:String):String {
		var bytes = haxe.io.Bytes.ofString(name);
		var safe = new StringBuf();
		for (i in 0...bytes.length) {
			var c:Int = bytes.get(i);
			var kept:Bool = (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code
				|| c == "_".code;
			safe.addChar(kept ? c : "_".code);
		}
		return "/dev/shm/crossbyte_shared_object_" + safe.toString() + "_" + nameHash(name);
	}
	#end

	#if (cpp && !windows)
	/**
		What a region leaves on the file system: its file under /dev/shm by
		Linux's name and by macOS's (which a Linux build switched to macOS's
		names uses), and macOS's lock file. A real macOS has no /dev/shm.
	**/
	private static function leftBehind(name:String):Array<String> {
		var hash:String = nameHash(name);
		var paths:Array<String> = ["/dev/shm/cbso_" + hash, "/tmp/cbso_" + hash + ".lock"];
		#if linux
		paths.push(posixRegionPath(name));
		#end
		return paths;
	}

	/**
		The FNV-1a hash the native side gives a name, as 16 hex digits. It
		seeds the hash with 1469598103934665603, not FNV's own
		14695981039346656037; any seed hashes, and changing it would part a
		process built before the change from one built after.
	**/
	private static function nameHash(name:String):String {
		var bytes = haxe.io.Bytes.ofString(name);
		var hash:haxe.Int64 = haxe.Int64.make(0x14650fb0, 0x739d0383);
		var prime:haxe.Int64 = haxe.Int64.make(0x100, 0x000001b3);
		for (i in 0...bytes.length) {
			hash = (hash ^ haxe.Int64.ofInt(bytes.get(i))) * prime;
		}
		return (StringTools.hex(hash.high, 8) + StringTools.hex(hash.low, 8)).toLowerCase();
	}
	#end

	#if (cpp && !windows)
	/**
		On Linux and macOS a region, and macOS's lock file, are their user's
		alone. Both were made 0666 less the umask, 0644 as a rule, so any
		local user could read what any SharedObject held, and open the lock
		file and hold every participant's lock.
	**/
	public function testARegionAndItsLockFileAreTheirUsersAlone():Void {
		var name:String = uniqueName("private");
		var shared = new SharedObject(name, 8192);
		shared.data = {secret: "kept"};
		shared.flush();
		var checked:Int = 0;
		for (path in leftBehind(name)) {
			if (sys.FileSystem.exists(path)) {
				var mode:Int = sys.FileSystem.stat(path).mode;
				Assert.equals(0, mode & 63, path + " can be read or written by others: mode " + StringTools.hex(mode & 511));
				checked++;
			}
		}
		shared.close();
		Assert.isTrue(checked > 0, "found nothing of the region's to look at");
	}

	/**
		A link put where macOS's lock file goes is not followed, and the
		region is not opened. It was followed: another user's link made this
		process make, or lock, a file wherever it pointed.
	**/
	public function testALinkWhereTheLockFileGoesIsNotFollowed():Void {
		var name:String = uniqueName("link");
		var lockPath:String = lockFileOf(name);
		var target:String = lockPath + ".target";
		Assert.equals(0, Sys.command("ln", ["-s", target, lockPath]), "could not make the link");
		var raised:Dynamic = null;
		try {
			new SharedObject(name, 8192).close();
		} catch (e:Dynamic) {
			raised = e;
		}
		var followed:Bool = sys.FileSystem.exists(target);
		__removeQuietly(lockPath);
		__removeQuietly(target);

		Assert.isFalse(followed, "the link was followed: " + target + " was made");
		if (__usesLockFile()) {
			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "the region was opened through a link: " + raised);
			Assert.isTrue(Std.string(raised).indexOf("not this user's own") >= 0, Std.string(raised));
		}
	}

	/**
		A FIFO put where macOS's lock file goes does not hold the open. Opened
		for reading, a FIFO waits for a writer: the constructor waited for
		good, outside the collector's reach, and stopped this process's
		collections with it. The open runs on a thread of its own here, and a
		write to the FIFO lets it go if it waits.
	**/
	@:timeout(30000)
	public function testAFifoWhereTheLockFileGoesDoesNotHoldTheOpen():Void {
		if (!__usesLockFile()) {
			Assert.pass();
			return;
		}
		var name:String = uniqueName("fifo");
		var lockPath:String = lockFileOf(name);
		Assert.equals(0, Sys.command("mkfifo", [lockPath]), "could not make the FIFO");
		var outcome = new sys.thread.Deque<String>();
		sys.thread.Thread.create(() -> {
			try {
				new SharedObject(name, 8192).close();
				outcome.add("opened");
			} catch (e:Dynamic) {
				outcome.add("threw " + e);
			}
		});
		var deadline:Float = Timer.stamp() + 5;
		var result:Null<String> = null;
		while (result == null && Timer.stamp() < deadline) {
			result = outcome.pop(false);
			crossbyte.sys.System.sleep(0.005);
		}
		if (result == null) {
			// Lets the open go: a writer arrives.
			sys.io.File.write(lockPath).close();
			outcome.pop(true);
		}
		__removeQuietly(lockPath);

		Assert.notNull(result, "the open waited on a FIFO where the lock file goes");
		if (result != null) {
			Assert.isTrue(result.indexOf("not this user's own") >= 0, result);
		}
	}

	/**
		A lock file deleted while the region is open, as macOS's cleaner
		deletes what in /tmp nobody has touched for three days, does not
		part the participants. The next one to open made a new file and
		locked that, while those open went on locking the old: two
		participants each holding the region's lock. A handle open before
		now finds the file gone and takes the new one, and waits for whoever
		holds it.
	**/
	@:timeout(60000)
	public function testALockFileDeletedWhileOpenStillLocksEveryone():Void {
		if (!__usesLockFile()) {
			Assert.pass();
			return;
		}
		var name:String = uniqueName("swept");
		var early = new SharedObject(name, 8192);
		early.data = {n: 1};
		early.flush();
		sys.FileSystem.deleteFile(lockFileOf(name));
		// Opened since: it makes the lock file anew, and holds its lock.
		var holder = new HeldLock(new SharedObject(name, 8192));

		var raised:Dynamic = null;
		try {
			early.lockTimeout = 200;
			early.data = {n: 2};
			early.flush();
		} catch (e:Dynamic) {
			raised = e;
		}
		holder.release();
		early.lockTimeout = 5000;
		early.sync();
		var after:Dynamic = early.data.n;
		early.close();

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "a flush went ahead while another participant held the lock: " + raised);
		Assert.equals(1, after, "the flush made while another held the lock was written");
	}

	/**
		Opening a region brings its lock file's times up to date, as each
		hour of use does, so a cleaner of old files in /tmp does not find
		one in use old. A lock took nothing of the file, and left its times
		as they were made.
	**/
	public function testOpeningBringsTheLockFilesTimesUpToDate():Void {
		if (!__usesLockFile()) {
			Assert.pass();
			return;
		}
		var name:String = uniqueName("fresh");
		var lockPath:String = lockFileOf(name);
		// Made by this user, as an earlier participant would have, four days
		// ago.
		sys.io.File.saveContent(lockPath, "");
		Sys.command("chmod", ["600", lockPath]);
		var fourDaysAgo = Date.fromTime(Date.now().getTime() - 4 * 24 * 3600 * 1000.0);
		Assert.equals(0, Sys.command("touch", ["-t", DateTools.format(fourDaysAgo, "%Y%m%d%H%M"), lockPath]), "could not age the file");
		var aged:Float = sys.FileSystem.stat(lockPath).mtime.getTime();

		var shared = new SharedObject(name, 8192);
		var refreshed:Float = sys.FileSystem.stat(lockPath).mtime.getTime();
		shared.close();

		Assert.isTrue(Date.now().getTime() - aged > 3 * 24 * 3600 * 1000.0, "the file was not aged");
		Assert.isTrue(Date.now().getTime() - refreshed < 3600 * 1000.0, "the lock file still looks " + Math.round((Date.now().getTime() - refreshed) / 3600000) + " hours old");
	}

	/**
		A region or lock file another user made under the name is not used,
		and the error says why. One made first by another user, writable by
		all, was opened and shared with them where the system allowed it,
		macOS does, so they read what this process wrote and wrote what it
		read. Needs root, to make a file another user owns; elsewhere it
		passes having checked nothing.
	**/
	public function testWhatAnotherUserMadeUnderTheNameIsNotUsed():Void {
		var name:String = uniqueName("theirs");
		var region:String = __usesLockFile() ? "/dev/shm/cbso_" + nameHash(name) : #if linux posixRegionPath(name) #else null #end;
		var paths:Array<String> = region != null && sys.FileSystem.exists("/dev/shm") ? [region] : [];
		if (__usesLockFile()) {
			paths.push(lockFileOf(name));
		}
		for (path in paths) {
			sys.io.File.saveBytes(path, haxe.io.Bytes.alloc(0));
			Sys.command("chmod", ["666", path]);
			if (Sys.command("chown", ["nobody", path]) != 0) {
				// Not root: nothing can be made another user's.
				for (made in paths) {
					__removeQuietly(made);
				}
				Assert.pass();
				return;
			}
			var raised:Dynamic = null;
			try {
				new SharedObject(name, 8192).close();
			} catch (e:Dynamic) {
				raised = e;
			}
			__removeQuietly(path);
			// Linux refuses some of these itself (fs.protected_regular), with
			// an error that said nothing of why; macOS has no such guard.
			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), path + ", another user's, was not refused as theirs: " + raised);
			Assert.isTrue(Std.string(raised).indexOf("not this user's own") >= 0, Std.string(raised));
		}
	}

	/** macOS's lock file for `name`. **/
	private static function lockFileOf(name:String):String {
		return "/tmp/cbso_" + nameHash(name) + ".lock";
	}

	private static var __lockFileMode:Null<Bool> = null;

	/** Whether the native side uses macOS's lock file: on macOS, or a Linux build switched to it. **/
	private static function __usesLockFile():Bool {
		if (__lockFileMode == null) {
			var probe:String = "crossbyte_sharedobject_mode_" + Std.int(Timer.stamp() * 1000) + "_" + Std.random(1000000);
			new SharedObject(probe, 64).close();
			__lockFileMode = sys.FileSystem.exists(lockFileOf(probe));
			SharedObject.remove(probe);
		}
		return __lockFileMode;
	}

	private static function __removeQuietly(path:String):Void {
		try {
			sys.FileSystem.deleteFile(path);
		} catch (_:Dynamic) {}
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

	/**
		A participant stopped while holding the region's lock fails the others'
		waits at `lockTimeout`, with an `IOError` saying so, and they read,
		write and clear nothing. The wait had no deadline, so a holder
		suspended in a debugger or sent SIGSTOP stopped every participant for
		as long as it stayed stopped.

		The holder is a second handle whose lock is taken on a thread of its
		own, on Windows a mutex belongs to the thread that takes it, so
		another thread waits on it as another process would, and kept until
		the case lets it go.
	**/
	@:timeout(60000)
	public function testALockHeldPastTheDeadlineFailsTheWait():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("held");
		var shared = new SharedObject(name, 8192);
		shared.data = {kept: "before"};
		shared.flush();
		var holder = new HeldLock(new SharedObject(name, 8192));

		try {
			shared.lockTimeout = 200;
			shared.data = {kept: "during"};
			for (operation in ["sync", "flush", "clear"]) {
				var started:Float = Timer.stamp();
				var raised:Dynamic = null;
				try {
					switch (operation) {
						case "sync":
							shared.sync();
						case "flush":
							shared.flush();
						default:
							shared.clear();
					}
				} catch (e:Dynamic) {
					raised = e;
				}
				var waited:Float = Timer.stamp() - started;
				Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), '$operation threw ' + raised);
				Assert.isTrue(Std.string(raised).indexOf("lock was not released within 200 ms") >= 0, '$operation threw ' + raised);
				Assert.isTrue(waited >= 0.18 && waited < 3, '$operation waited $waited s');
			}
			// Nothing synced over it or cleared it.
			Assert.equals("during", shared.data.kept);

			// The constructor, which waits as long as the default allows.
			var started:Float = Timer.stamp();
			var raised:Dynamic = null;
			try {
				new SharedObject(name, 8192);
			} catch (e:Dynamic) {
				raised = e;
			}
			var waited:Float = Timer.stamp() - started;
			Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "new threw " + raised);
			Assert.isTrue(Std.string(raised).indexOf("lock was not released within 5000 ms") >= 0, "new threw " + raised);
			Assert.isTrue(waited >= 4.9 && waited < 20, 'new waited $waited s');
		} catch (e:Dynamic) {
			holder.release();
			shared.close();
			throw e;
		}

		holder.release();
		// Released, the region holds what the last flush left.
		shared.sync();
		Assert.equals("before", shared.data.kept);
		shared.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	/**
		A lock its holder lets go of in time is taken, with a deadline and with
		none (0). On Linux and macOS a wait with a deadline asks again and
		again rather than blocking, so this is also the case that it notices
		the lock coming free.
	**/
	@:timeout(60000)
	public function testALockReleasedInTimeIsTaken():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("released");
		var shared = new SharedObject(name, 8192);
		shared.data = {n: 0};
		shared.flush();

		for (deadline in [5000, 0]) {
			shared.lockTimeout = deadline;
			var holder = new HeldLock(new SharedObject(name, 8192), 0.3);
			var started:Float = Timer.stamp();
			shared.data = {n: deadline};
			shared.flush();
			var waited:Float = Timer.stamp() - started;
			holder.release();

			// It waited for the holder, then wrote.
			Assert.isTrue(waited >= 0.2 && waited < 5, 'lockTimeout $deadline: waited $waited s');
			shared.sync();
			Assert.equals(deadline, shared.data.n);
		}
		shared.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	/**
		`remove` takes a region away on Linux and macOS, where it otherwise
		outlives every handle until the machine restarts: the next handle
		opened under the name starts a new, empty region, while those open
		keep the old one between them. On Windows a region goes with its last
		handle and has no name to take away, so `remove` answers false.
	**/
	public function testRemoveTakesARegionAwayOnLinuxAndMacOS():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("removed");
		var first = new SharedObject(name, 8192);
		var second = new SharedObject(name, 8192);
		first.data = {left: "behind"};
		first.flush();

		#if windows
		Assert.isFalse(SharedObject.remove(name));
		second.sync();
		Assert.equals("behind", second.data.left);
		#else
		Assert.isTrue(SharedObject.remove(name));

		// Those open keep the region, between them.
		second.sync();
		Assert.equals("behind", second.data.left);
		second.data = {left: "still shared"};
		second.flush();
		first.sync();
		Assert.equals("still shared", first.data.left);

		// The next one opened under the name starts a new region.
		var third = new SharedObject(name, 8192, {fresh: true});
		Assert.equals(true, third.data.fresh);
		Assert.isNull(third.data.left);
		third.flush();
		first.sync();
		Assert.isNull(first.data.fresh);
		third.close();

		Assert.isTrue(SharedObject.remove(name), "the new region was not removed");
		Assert.isFalse(SharedObject.remove(name), "a region no one has was removed");
		// Nothing left under the name: on Linux the region's file, on macOS
		// (and on Linux with the native side switched to its names) the
		// region's and its lock file.
		for (path in leftBehind(name)) {
			Assert.isFalse(sys.FileSystem.exists(path), path + " is still there");
		}
		#end
		first.close();
		second.close();
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testRemoveRefusesAnEmptyName():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.raises(() -> SharedObject.remove(""), crossbyte.errors.ArgumentError);
		Assert.raises(() -> SharedObject.remove(null), crossbyte.errors.ArgumentError);
		#else
		Assert.raises(() -> SharedObject.remove("anything"), crossbyte.errors.IllegalOperationError);
		#end
	}

	private static function uniqueName(label:String):String {
		return tracked("crossbyte_sharedobject_" + label + "_" + Std.int(Timer.stamp() * 1000) + "_" + Std.random(1000000));
	}

	// A name whose region teardown removes.
	private static function tracked(name:String):String {
		__names.push(name);
		return name;
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

#if cpp
/**
	A region's lock held through `shared` on a thread of its own: until
	`release()`, or for `holdFor` seconds when given. Either way `release()`
	waits for the thread to let it go, then closes `shared`.
**/
@:access(crossbyte.ipc.SharedObject)
@:access(crossbyte.ipc._internal.NativeSharedObject)
private class HeldLock {
	private var shared:SharedObject;
	private var letGo:sys.thread.Deque<Bool> = new sys.thread.Deque<Bool>();
	private var gone:sys.thread.Deque<Bool> = new sys.thread.Deque<Bool>();
	private var released:Bool = false;

	public function new(shared:SharedObject, ?holdFor:Float) {
		this.shared = shared;
		var taken = new sys.thread.Deque<Bool>();
		var handle = shared.__handle;
		var letGo = this.letGo;
		var gone = this.gone;
		sys.thread.Thread.create(function():Void {
			var holding:Bool = crossbyte.ipc._internal.NativeSharedObject.__holdLockForTest(handle);
			taken.add(holding);
			if (holding) {
				if (holdFor == null) {
					letGo.pop(true);
				} else {
					crossbyte.sys.System.sleep(holdFor);
				}
				// On the thread that took it: a Windows mutex is released by
				// its owner or not at all.
				crossbyte.ipc._internal.NativeSharedObject.__releaseLockForTest(handle);
			}
			gone.add(true);
		});
		if (!taken.pop(true)) {
			gone.pop(true);
			shared.close();
			throw "the region's lock could not be taken";
		}
	}

	public function release():Void {
		if (released) {
			return;
		}
		released = true;
		letGo.add(true);
		gone.pop(true);
		shared.close();
	}
}
#end
