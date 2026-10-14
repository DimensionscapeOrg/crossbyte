package crossbyte.rpc;

import utest.Assert;

/**
	A test's checks of what arrived, run inside the handler's call. What the
	session reads an argument into (a patch, a `@:reuse` argument) is valid
	only during the call, and `-D crossbyte_check_events` poisons it once the
	call returns, so a test reading it afterwards reads garbage, as a handler
	keeping it would.

	A handler calls `run()` last in each of its methods; a test calls
	`test(send, check)`.
**/
class InCall {
	var check:Null<Void->Void> = null;
	var ran:Int = 0;
	var failure:Null<haxe.Exception> = null;

	/**
		Whether the session reads each call into what it keeps: always, but
		under `-D crossbyte_fresh_events`, where every arrival is new.
	**/
	public static inline var REUSED:Bool = #if crossbyte_fresh_events false #else true #end;

	/**
		Asserts `kept` is `now`, the instance the session read the last call
		into, as it reuses one; under `-D crossbyte_fresh_events` that it is not.
	**/
	public static function assertKept<T>(kept:T, now:T, message:String, ?pos:haxe.PosInfos):Void {
		if (REUSED) {
			Assert.isTrue(kept == now, message, pos);
		} else {
			Assert.isFalse(kept == now, "under -D crossbyte_fresh_events, an arrival was not new: " + message, pos);
		}
	}

	public function new() {}

	/** Runs the check a test is waiting on, once: the handler calls it in its method. **/
	public function run():Void {
		final check:Null<Void->Void> = this.check;
		if (check == null) {
			return;
		}
		this.check = null;
		ran++;
		try {
			check();
		} catch (e:haxe.Exception) {
			// Thrown back to the test, not to the session that called the handler.
			failure = e;
		}
	}

	/** Runs `send`, and `check` inside the call it makes; one call has to arrive. **/
	public function test(send:Void->Void, check:Void->Void, ?pos:haxe.PosInfos):Void {
		this.check = check;
		ran = 0;
		failure = null;
		send();
		this.check = null;
		Assert.equals(1, ran, "the call did not arrive while it was sent", pos);
		final thrown:Null<haxe.Exception> = failure;
		failure = null;
		if (thrown != null) {
			throw thrown;
		}
	}
}
