package crossbyte.db.mongodb.bson;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
#if (target.threaded && !cpp && !java && !jvm)
import sys.thread.Mutex;
#end

/**
	A MongoDB ObjectId: twelve bytes, made of the second it was created, five
	bytes drawn at random once per process, and a three-byte counter.

	Unique without coordination, and roughly ordered by creation time, which
	is why MongoDB uses it as the default `_id`. `MongoConnection.insert`
	makes one for every document that arrives without an `_id`.

	```haxe
	var id = new ObjectId();
	var same = ObjectId.fromHex(id.toHex());
	trace(id.equals(same)); // true
	```
**/
final class ObjectId {
	/** The twelve bytes, big-endian as they travel. Not to be modified. **/
	public var bytes(default, null):Bytes;

	// Five bytes unique to this process and a counter that starts somewhere
	// random, as the ObjectId specification asks, so two processes started
	// in the same second do not produce the same ids.
	@:noCompletion private static var __processUnique:Bytes = __randomBytes(5);
	#if cpp
	// A plain Int, incremented with an atomic add: an id is made for every
	// document inserted without one, and a Mutex costs a GC-free zone on each
	// acquire natively.
	@:noCompletion private static var __counter:Int = Std.random(0xFFFFFF);
	#elseif (java || jvm)
	@:noCompletion private static var __counter:java.util.concurrent.atomic.AtomicInteger = new java.util.concurrent.atomic.AtomicInteger(Std.random(0xFFFFFF));
	#else
	@:noCompletion private static var __counter:Int = Std.random(0xFFFFFF);
	#end
	#if (target.threaded && !cpp && !java && !jvm)
	@:noCompletion private static var __counterLock:Mutex = new Mutex();
	#end

	/**
		Makes a new ObjectId, or wraps `bytes` when given: exactly twelve,
		kept as they are rather than copied.
	**/
	public function new(?bytes:Bytes) {
		if (bytes != null) {
			if (bytes.length != 12) {
				throw new ArgumentError('An ObjectId is 12 bytes, not ${bytes.length}.');
			}

			this.bytes = bytes;
			return;
		}

		var out:Bytes = Bytes.alloc(12);
		// time of day: an ObjectId carries the second it was made in.
		var seconds:Float = Math.ffloor(Date.now().getTime() / 1000);
		// Written as two halves: past 2038 the value no longer fits an Int,
		// and converting it to one is undefined on several targets.
		var high:Int = Std.int(seconds / 65536);
		var low:Int = Std.int(seconds - high * 65536.0);
		out.set(0, (high >> 8) & 0xFF);
		out.set(1, high & 0xFF);
		out.set(2, (low >> 8) & 0xFF);
		out.set(3, low & 0xFF);
		out.blit(4, __processUnique, 0, 5);

		var count:Int = __nextCount();
		out.set(9, (count >> 16) & 0xFF);
		out.set(10, (count >> 8) & 0xFF);
		out.set(11, count & 0xFF);
		this.bytes = out;
	}

	/**
		Parses the 24 hexadecimal characters `toHex` produces, either case.

		@throws ArgumentError When `hex` is not exactly that.
	**/
	public static function fromHex(hex:String):ObjectId {
		if (!isValid(hex)) {
			throw new ArgumentError('Not an ObjectId: "$hex". One is 24 hexadecimal characters.');
		}

		var out:Bytes = Bytes.alloc(12);

		for (i in 0...12) {
			out.set(i, (__nibble(StringTools.fastCodeAt(hex, i * 2)) << 4) | __nibble(StringTools.fastCodeAt(hex, i * 2 + 1)));
		}

		return new ObjectId(out);
	}

	/** Whether `hex` is 24 hexadecimal characters. **/
	public static function isValid(hex:String):Bool {
		if (hex == null || hex.length != 24) {
			return false;
		}

		for (i in 0...24) {
			if (__nibble(StringTools.fastCodeAt(hex, i)) < 0) {
				return false;
			}
		}

		return true;
	}

	/** The second this id was made in, as a date. **/
	public function getDate():Date {
		return Date.fromTime(getTimestamp() * 1000.0);
	}

	/** Seconds since the Unix epoch at which this id was made. **/
	public function getTimestamp():Float {
		return ((bytes.get(0) << 8) | bytes.get(1)) * 65536.0 + ((bytes.get(2) << 8) | bytes.get(3));
	}

	/** The 24 lower-case hexadecimal characters of the id. **/
	public function toHex():String {
		var out:StringBuf = new StringBuf();

		for (i in 0...12) {
			var b:Int = bytes.get(i);
			out.addChar(__HEX.charCodeAt(b >> 4));
			out.addChar(__HEX.charCodeAt(b & 15));
		}

		return out.toString();
	}

	public function toString():String {
		return toHex();
	}

	/** Whether `other` holds the same twelve bytes. **/
	public function equals(other:ObjectId):Bool {
		if (other == null) {
			return false;
		}

		if (other == this) {
			return true;
		}

		return bytes.compare(other.bytes) == 0;
	}

	@:noCompletion private static inline var __HEX:String = "0123456789abcdef";

	@:noCompletion private static function __nibble(code:Int):Int {
		if (code >= "0".code && code <= "9".code) {
			return code - "0".code;
		}

		if (code >= "a".code && code <= "f".code) {
			return code - "a".code + 10;
		}

		if (code >= "A".code && code <= "F".code) {
			return code - "A".code + 10;
		}

		return -1;
	}

	@:noCompletion private static function __nextCount():Int {
		#if cpp
		return (untyped __cpp__("_hx_atomic_add(&{0}, 1)", __counter) : Int) & 0xFFFFFF;
		#elseif (java || jvm)
		return __counter.getAndIncrement() & 0xFFFFFF;
		#elseif target.threaded
		__counterLock.acquire();
		var count:Int = __counter++;
		__counterLock.release();
		return count & 0xFFFFFF;
		#else
		return (__counter++) & 0xFFFFFF;
		#end
	}

	/**
		Bytes from the platform's secure generator where it has one, and from
		`Math.random` where it does not (the interpreter, neko and hl).

		Nothing depends on these being unpredictable: they only have to differ
		between processes, which the clock-seeded generator also manages.
	**/
	@:noCompletion private static function __randomBytes(length:Int):Bytes {
		if (crossbyte.crypto.SecureRandom.isSupported) {
			try {
				return crossbyte.crypto.SecureRandom.getSecureRandomBytes(length);
			} catch (_:Dynamic) {}
		}

		var out:Bytes = Bytes.alloc(length);

		for (i in 0...length) {
			out.set(i, Std.random(256));
		}

		return out;
	}
}
