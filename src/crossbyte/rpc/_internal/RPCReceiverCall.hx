package crossbyte.rpc._internal;

import crossbyte._internal.system.timer.TimerHandle;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.net.Reason;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCError;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc.RPCReceiver;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.rpc.RPCTimeoutError;
import crossbyte.rpc.RPCValueReceiver;
import crossbyte.utils.Logger;

/**
	A call made with a receiver, while it waits for its answer: where its
	commands find it by its id, and where a deadline finds it, as they find
	an `RPCResponse`, which it is. Never handed to anyone: its commands keep
	a few and use them again, so a call allocates nothing for waiting.

	Its answer is handed to the receiver typed by the commands' generated
	reader (see `RPCCommands.__answerInt` and the others beside it). Every
	other way a call ends (a failure, a deadline, the connection going) is
	the `RPCResponse` one, which here tells the receiver `onFailure`.

	Back in its pool before the receiver is told, so the receiver can make
	the next call with it; nothing reads it after that.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
final class RPCReceiverCall extends RPCResponse<Dynamic> {
	/** Who is told; `null` while it waits in its pool. **/
	public var receiver:Null<RPCReceiver> = null;

	/** The next in its commands' pool. **/
	public var nextFree:Null<RPCReceiverCall> = null;

	/** The session whose queue of deadlines it waits in, if it does: its commands may be bound to another by the time it leaves. **/
	public var queuedIn:Null<RPCSession<Dynamic, Dynamic>> = null;

	public function new(commands:RPCCommands) {
		super(0, 0);
		__commands = commands;
		__pooled = true;
	}

	/** Waits as the call `requestId` for `op`, to tell `receiver`. **/
	public inline function begin(requestId:Int, op:Int, receiver:RPCReceiver):Void {
		this.requestId = requestId;
		this.op = op;
		this.receiver = receiver;
	}

	/**
		No longer waiting: out of any queue of deadlines, back in its pool,
		and its receiver handed over to be told. Called once it is out of
		where its commands find it.
	**/
	public inline function finish():RPCReceiver {
		__disarm();
		queuedIn = null;
		final told:RPCReceiver = receiver;
		receiver = null;
		__commands.__recycle(this);
		return told;
	}

	/** An answer for a receiver of any type, taken as `RPCValueReceiver`: the way an answer would arrive that the generated reader did not type. **/
	override function __resolve(value:Dynamic):Bool {
		if (receiver == null) {
			return false;
		}
		final call:Int = requestId;
		final told:RPCValueReceiver<Dynamic> = cast finish();
		try {
			told.onValue(call, value);
		} catch (error:Dynamic) {
			contained(error);
		}
		return true;
	}

	override function __fail(message:String, ?cause:Dynamic):Bool {
		if (receiver == null) {
			return false;
		}
		final failure:RPCFailure = failureOf(message, cause);
		final call:Int = requestId;
		tell(finish(), call, failure);
		return true;
	}

	/** Past its deadline: out of where its commands find it, and told so, with nothing made to say it. **/
	override function __expire(milliseconds:Int):Void {
		__deadline = TimerHandle.INVALID;
		if (receiver == null) {
			return;
		}
		__commands.__takeResponse(requestId);
		final call:Int = requestId;
		tell(finish(), call, TimedOut);
	}

	/** Leaves the queue of the session it was queued in, whichever its commands are bound to now. **/
	override function __leaveQueue(deadline:Int):Void {
		final session = queuedIn;
		if (session != null && session.__deadlines != null) {
			session.__deadlines.leave(this, deadline);
		}
	}

	/** Tells `receiver` that `call` failed, containing what it throws. **/
	public static function tell(receiver:RPCReceiver, call:Int, failure:RPCFailure):Void {
		try {
			receiver.onFailure(call, failure);
		} catch (error:Dynamic) {
			contained(error);
		}
	}

	/** A receiver threw: said, and gone no further, as a `Future`'s handler's throw is. **/
	public static function contained(error:Dynamic):Void {
		Logger.error("An RPC receiver threw and was contained: " + Std.string(error));
	}

	/**
		The failure a receiver is told of, from what an `RPCResponse` would
		have failed with.
	**/
	static function failureOf(message:String, cause:Null<Dynamic>):RPCFailure {
		if (cause == null) {
			return switch (message) {
				case RPCSession.STOPPED_MESSAGE: Stopped;
				case RPCSession.CANCELLED_MESSAGE: Cancelled;
				// An answer to another op, or of an op these commands do not read.
				case _: Unreadable(message);
			}
		}
		if (Std.isOfType(cause, RPCTimeoutError)) {
			return TimedOut;
		}
		if (Std.isOfType(cause, RPCError)) {
			return Refused(message);
		}
		if (Std.isOfType(cause, ArgumentError) || Std.isOfType(cause, IllegalOperationError)
			|| StringTools.startsWith(message, RPCSession.UNSENT_PREFIX)) {
			return Unsent(message);
		}
		if (Std.isOfType(cause, Reason)) {
			return Disconnected((cause : Reason));
		}
		return Unreadable(message);
	}
}
