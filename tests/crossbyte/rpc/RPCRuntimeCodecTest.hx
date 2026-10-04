package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.rpc._internal.RPCRuntimeCodec;
import haxe.io.Bytes;
import utest.Assert;

/**
	How the runtime lane tells one kind of value from another.

	It asked `Type.typeof`, which made a `TClass`, an object, for every
	String and Bytes it was asked about, on every call. `tagOf` answers
	without allocating, and must answer as `Type.typeof` did on every target:
	which numbers are Ints differs between targets, and a call must arrive as
	it always did wherever it is made.
**/
class RPCRuntimeCodecTest extends utest.Test {
	public function testEachValueGoesUnderTheTagTypeOfGaveIt():Void {
		for (value in samples()) {
			Assert.equals(referenceTag(value), RPCRuntimeCodec.tagOf(value), 'not tagged as Type.typeof had it: ' + describe(value));
		}
	}

	public function testEachValueArrivesAsItDid():Void {
		// Every value the lane carries, sent and read back: what arrives is of
		// the kind Type.typeof gave what was sent.
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server);
		var client = new RPCSession(link.client);
		var arrived:Array<Dynamic> = null;
		server.register(9, args -> {
			arrived = args;
			return null;
		});
		final sent:Array<Dynamic> = [for (value in samples()) if (referenceTag(value) != RPCRuntimeCodec.NOT_CARRIED) value];
		client.call(9, sent);

		Assert.notNull(arrived);
		if (arrived == null) {
			return;
		}
		Assert.equals(sent.length, arrived.length);
		for (i in 0...sent.length) {
			final tag:Int = referenceTag(sent[i]);
			Assert.equals(tag, referenceTag(arrived[i]), 'arrived as another kind: ' + describe(sent[i]) + ' as ' + describe(arrived[i]));
			switch (tag) {
				case RPCRuntimeCodec.TAG_BYTES:
					Assert.equals((cast sent[i] : Bytes).toHex(), (cast arrived[i] : Bytes).toHex());
				case RPCRuntimeCodec.TAG_FLOAT if (Math.isNaN(sent[i])):
					Assert.isTrue(Math.isNaN(arrived[i]));
				case _:
					Assert.isTrue(sent[i] == arrived[i], 'arrived as another value: ' + describe(sent[i]) + ' as ' + describe(arrived[i]));
			}
		}
	}

	public function testAValueTheLaneDoesNotCarryIsRefusedAsItWas():Void {
		var link = LinkedConnection.pair();
		var client = new RPCSession(link.client);
		for (value in samples()) {
			if (referenceTag(value) != RPCRuntimeCodec.NOT_CARRIED) {
				continue;
			}
			var refused:Null<String> = null;
			try {
				client.call(10, [value]);
			} catch (error:Dynamic) {
				refused = Std.string(error);
			}
			Assert.notNull(refused, 'carried: ' + describe(value));
			if (refused != null) {
				Assert.stringContains("Unsupported runtime RPC value", refused);
			}
		}
		// And nothing was left held by the refusal.
		Assert.isFalse(@:privateAccess client.__frame != null && @:privateAccess client.__frame.busy);
	}

	// ------------------------------------------------------------------

	/** How the lane classified a value: `Type.typeof`, as it asked it. **/
	private static function referenceTag(value:Dynamic):Int {
		if (value == null) {
			return RPCRuntimeCodec.TAG_NULL;
		}
		return switch (Type.typeof(value)) {
			case TBool: value ? RPCRuntimeCodec.TAG_TRUE : RPCRuntimeCodec.TAG_FALSE;
			case TInt: RPCRuntimeCodec.TAG_INT;
			case TFloat: RPCRuntimeCodec.TAG_FLOAT;
			case TClass(String): RPCRuntimeCodec.TAG_STRING;
			case TClass(Bytes): RPCRuntimeCodec.TAG_BYTES;
			case TClass(_) if (Std.isOfType(value, Bytes)): RPCRuntimeCodec.TAG_BYTES;
			default: RPCRuntimeCodec.NOT_CARRIED;
		}
	}

	private static function samples():Array<Dynamic> {
		final bytes = Bytes.alloc(3);
		bytes.set(0, 1);
		bytes.set(1, 0);
		bytes.set(2, 255);
		final array = new ByteArray();
		array.writeByte(7);
		final whole:Float = 2.0;
		final negative:Float = -2.0;
		final zero:Float = 0.0;
		final negativeZero:Float = -0.0;
		final big:Float = 3000000000.0;
		final values:Array<Dynamic> = [
			null, true, false, 0, 1, -1, 0x7FFFFFFF, 0x80000000, whole, negative, zero, negativeZero, 2.5, -0.125, big, -big, 1e300, Math.NaN,
			Math.POSITIVE_INFINITY, Math.NEGATIVE_INFINITY, "", "x", "café", bytes, array, [1, 2], {a: 1}, haxe.ds.Option.None,
			new haxe.ds.StringMap<Int>(), (x:Int) -> x
		];
		return values;
	}

	private static function describe(value:Dynamic):String {
		// Bytes as hex: as a string, these are not UTF-8.
		final shown:String = (value is Bytes) ? "0x" + (cast value : Bytes).toHex() : Std.string(value);
		return shown + " (" + Std.string(Type.typeof(value)) + ")";
	}
}
