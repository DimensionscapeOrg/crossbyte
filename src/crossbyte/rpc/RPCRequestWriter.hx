package crossbyte.rpc;

import crossbyte.rpc._internal.RPCFrame;
import haxe.io.Bytes;

/**
	A request on the runtime lane, written value by value straight into its
	session's frame: what `RPCSession.runtimeRequest(op)` gives. `send()`
	returns the `RPCResponse<T>` that completes with the answer, as
	`request` does.

	```haxe
	// Given session:RPCSession<Dynamic, Dynamic>.
	final ADD = 101;
	session.runtimeRequest(ADD).int(7).int(35).send().then(sum -> trace(sum));
	```

	The same frame `request(op, [7, 35])` sends, with no array and no boxing
	of the arguments. Its request id is taken as it begins, and the call
	waits for an answer only once it is sent: one cancelled, or never sent,
	leaves nothing waiting. Valid until it is sent, as `RPCCallWriter` is:
	a writer used after it was sent or cancelled throws an
	`IllegalOperationError`, and one never sent keeps the session's frame
	until `cancel()`.
**/
@:access(crossbyte.rpc.RPCSession)
abstract RPCRequestWriter<T>(RPCFrame) {
	@:allow(crossbyte.rpc.RPCSession) inline function new(frame:RPCFrame) {
		this = frame;
	}

	/** An `Int`, tagged as one: five bytes. **/
	public inline function int(value:Int):RPCRequestWriter<T> {
		this.valueInt(value);
		return new RPCRequestWriter<T>(this);
	}

	/** A `Float`, tagged as one whatever its value: nine bytes. **/
	public inline function float(value:Float):RPCRequestWriter<T> {
		this.valueFloat(value);
		return new RPCRequestWriter<T>(this);
	}

	/** A `Bool`: one byte. **/
	public inline function bool(value:Bool):RPCRequestWriter<T> {
		this.valueBool(value);
		return new RPCRequestWriter<T>(this);
	}

	/** A `String` as UTF-8 after its length, or the lane's null for `null`. **/
	public inline function string(value:String):RPCRequestWriter<T> {
		this.valueString(value);
		return new RPCRequestWriter<T>(this);
	}

	/** `Bytes` (a `ByteArray` as its `length` bytes) after their length, or the lane's null for `null`. **/
	public inline function bytes(value:Bytes):RPCRequestWriter<T> {
		this.valueBytes(value);
		return new RPCRequestWriter<T>(this);
	}

	/** The lane's null: one byte. **/
	public inline function nullValue():RPCRequestWriter<T> {
		this.valueNull();
		return new RPCRequestWriter<T>(this);
	}

	/**
		Any value `call` carries, tagged as `call` tags it, for a value whose
		type is known only at run time.

		@throws String For a value of a type the lane does not carry; the call
		        can still be cancelled.
	**/
	public inline function value(value:Dynamic):RPCRequestWriter<T> {
		this.valueAny(value);
		return new RPCRequestWriter<T>(this);
	}

	/** How many values have been written so far. **/
	public var count(get, never):Int;

	inline function get_count():Int {
		return this.count;
	}

	/**
		Sends the request, as `request` does, and returns its response. A
		request that cannot go fails at once: over `maxFrameLength`, with an
		`ArgumentError` as its cause; on a connection that has ended, with the
		`Reason` it ended with; when the send throws, with what it threw.

		@throws IllegalOperationError When it was sent or cancelled already.
	**/
	public inline function send():RPCResponse<T> {
		this.requireBuilding();
		return this.owner.__sendWrittenRequest(this.requestId, this.op, this.finishValues());
	}

	/** Gives the frame back unsent; nothing if it was sent or cancelled already. **/
	public inline function cancel():Void {
		if (this.building) {
			this.building = false;
			this.owner.__sent(this);
		}
	}
}
