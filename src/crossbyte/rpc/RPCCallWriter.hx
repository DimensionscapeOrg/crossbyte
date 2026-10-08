package crossbyte.rpc;

import crossbyte.rpc._internal.RPCFrame;
import haxe.io.Bytes;

/**
	A one-way call on the runtime lane, written value by value straight into
	its session's frame: what `RPCSession.runtimeCall(op)` gives.

	```haxe
	// Given session:RPCSession<Dynamic, Dynamic>.
	final MOVE = 102;
	session.runtimeCall(MOVE).float(1.5).float(2.5).int(7).string("run").send();
	```

	The same frame `call(op, [1.5, 2.5, 7, "run"])` sends, and read the same
	way by the other side (an `Array<Dynamic>` handler or one registered
	with `registerArgs`), but with no array and no boxing: each value is
	written, tagged, as it is given, and a call of numbers allocates
	nothing. A value is always sent under its method's tag: `float(2)` is a
	Float on every target, where `call` sends a whole Float as an Int on
	JavaScript, the jvm and HashLink.

	**Valid until it is sent.** It is the session's frame, being written:
	call `send()` once, and nothing on it after. A writer used after it was
	sent or cancelled throws an `IllegalOperationError`. One taken and never
	sent keeps the session's frame, and every call after it is framed in a
	fresh buffer: `cancel()` gives it back. Taken while another is being
	written (a value computed by code that makes a call of its own), it is
	framed in a buffer of its own, so the two do not mix.

	Allocation-free and inlined: the writer is the frame, and each method
	is a few stores.
**/
@:access(crossbyte.rpc.RPCSession)
abstract RPCCallWriter(RPCFrame) {
	@:allow(crossbyte.rpc.RPCSession) inline function new(frame:RPCFrame) {
		this = frame;
	}

	/** An `Int`, tagged as one: five bytes. **/
	public inline function int(value:Int):RPCCallWriter {
		this.valueInt(value);
		return new RPCCallWriter(this);
	}

	/** A `Float`, tagged as one whatever its value: nine bytes. **/
	public inline function float(value:Float):RPCCallWriter {
		this.valueFloat(value);
		return new RPCCallWriter(this);
	}

	/** A `Bool`: one byte. **/
	public inline function bool(value:Bool):RPCCallWriter {
		this.valueBool(value);
		return new RPCCallWriter(this);
	}

	/** A `String` as UTF-8 after its length, or the lane's null for `null`. **/
	public inline function string(value:String):RPCCallWriter {
		this.valueString(value);
		return new RPCCallWriter(this);
	}

	/** `Bytes` (a `ByteArray` as its `length` bytes) after their length, or the lane's null for `null`. **/
	public inline function bytes(value:Bytes):RPCCallWriter {
		this.valueBytes(value);
		return new RPCCallWriter(this);
	}

	/** The lane's null: one byte. **/
	public inline function nullValue():RPCCallWriter {
		this.valueNull();
		return new RPCCallWriter(this);
	}

	/**
		Any value `call` carries, tagged as `call` tags it, for a value whose
		type is known only at run time.

		@throws String For a value of a type the lane does not carry; the call
		        can still be cancelled.
	**/
	public inline function value(value:Dynamic):RPCCallWriter {
		this.valueAny(value);
		return new RPCCallWriter(this);
	}

	/** How many values have been written so far. **/
	public var count(get, never):Int;

	inline function get_count():Int {
		return this.count;
	}

	/**
		Sends the call, as `call` does: on a connection that has ended it is
		dropped, as a one-way call is.

		@throws ArgumentError When the call is over `RPCSession.maxFrameLength`.
		@throws IllegalOperationError When it was sent or cancelled already.
	**/
	public inline function send():Void {
		this.requireBuilding();
		this.owner.__sendCallFrame(this.finishValues());
	}

	/** Gives the frame back unsent; nothing if it was sent or cancelled already. **/
	public inline function cancel():Void {
		if (this.building) {
			this.building = false;
			this.owner.__sent(this);
		}
	}
}
