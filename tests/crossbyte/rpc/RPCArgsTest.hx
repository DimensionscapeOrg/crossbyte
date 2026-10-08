package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;
import utest.Assert;

/**
	`RPCSession.registerArgs`: runtime handlers that read their arguments
	where they lie, through `RPCArgs`' typed getters, each checked against
	the value's tag.
**/
class RPCArgsTest extends utest.Test {
	static inline final OP:Int = 400;

	public function testEachGetterReadsItsKind():Void {
		var pair = new ArgsPair();
		var seen:Array<String> = [];
		var kept:Bytes = null;
		pair.server.registerArgs(OP, args -> {
			seen.push(args.count + " " + args.int(0) + " " + args.float(1) + " " + args.bool(2) + " " + args.bool(3) + " " + args.string(4) + " "
				+ args.bytes(5).toString() + " " + args.isNull(6) + " " + args.string(6) + " " + args.bytes(6));
			seen.push([for (i in 0...args.count) args.kind(i)].join(","));
			kept = args.bytes(5);
			return null;
		});
		pair.client.call(OP, [7, 2.5, true, false, "hé", Bytes.ofString("raw"), null]);
		Assert.same(["7 7 2.5 true false hé raw true null null", "Int,Float,Bool,Bool,String,Bytes,Null"], seen);
		// What a getter made is the handler's to keep.
		Assert.equals("raw", kept.toString());
	}

	public function testAFloatGetterTakesAnInt():Void {
		var pair = new ArgsPair();
		var got:Float = 0;
		pair.server.registerArgs(OP, args -> {
			got = args.float(0);
			return null;
		});
		pair.client.runtimeCall(OP).int(3).send();
		Assert.equals(3.0, got);
	}

	public function testValueReadsAsTheArrayHolds():Void {
		var pair = new ArgsPair();
		var got:Array<Dynamic> = [];
		pair.server.registerArgs(OP, args -> {
			got = [for (i in 0...args.count) args.value(i)];
			return null;
		});
		pair.client.call(OP, [1, 1.5, "s", true, null]);
		Assert.same([1, 1.5, "s", true, null], got);
	}

	public function testAWrongKindIsTheCallersAnswer():Void {
		var pair = new ArgsPair();
		pair.server.registerArgs(OP, args -> args.int(0));
		var answer = pair.client.request(OP, ["seven"]);
		Assert.isFalse(answer.succeeded);
		Assert.equals("RPC argument 0 is a String, where an Int was asked for", answer.error);
		var floatAsInt = pair.client.request(OP, [1.5]);
		Assert.equals("RPC argument 0 is a Float, where an Int was asked for", floatAsInt.error);
		var none = pair.client.request(OP, [null]);
		Assert.equals("RPC argument 0 is null, where an Int was asked for", none.error);
		var missing = pair.client.request(OP, []);
		Assert.equals("RPC argument 0 was asked for, and the call carries 0", missing.error);
		// The connection carries on.
		Assert.equals(5, pair.client.request(OP, [5]).result);
	}

	public function testAnArgsHandlerAnswersAsAnArrayHandlerDoes():Void {
		var pair = new ArgsPair();
		pair.server.registerArgs(OP, args -> args.int(0) + args.int(1));
		Assert.equals(42, pair.client.request(OP, [7, 35]).result);
		Assert.equals(3, pair.client.runtimeRequest(OP).int(1).int(2).send().result);
		// An answer later.
		var pending:crossbyte.Future<Int> = null;
		var doubled:Int = 0;
		pair.server.registerArgs(OP + 1, args -> {
			// Read during the call, answered after it.
			doubled = args.int(0) * 2;
			pending = new crossbyte.Future<Int>();
			return pending;
		});
		var answer = pair.client.request(OP + 1, [5]);
		Assert.isFalse(answer.succeeded);
		@:privateAccess pending.__resolve(doubled);
		Assert.equals(10, answer.result);
	}

	public function testRegisteringAgainEitherWayReplacesTheHandler():Void {
		var pair = new ArgsPair();
		pair.server.register(OP, args -> "array");
		pair.server.registerArgs(OP, args -> "args");
		Assert.equals("args", pair.client.request(OP, []).result);
		pair.server.register(OP, args -> "array");
		Assert.equals("array", pair.client.request(OP, []).result);
		// Another handler keeps the session reading, as it does for register.
		pair.server.registerArgs(OP + 9, args -> null);
		Assert.isTrue(pair.server.deregister(OP));
		Assert.isFalse(pair.server.deregister(OP));
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, pair.client.request(OP, []).error);
	}

	public function testACallThatDoesNotReadIsAnsweredAndItsHandlerDoesNotRun():Void {
		var pair = new ArgsPair();
		var ran:Int = 0;
		pair.server.registerArgs(OP, args -> {
			ran++;
			return null;
		});
		var answers = errorAnswersAt(pair.link.client);
		// A tag this lane does not know; a string longer than the frame; a
		// count past it; an Int cut short.
		for (body in [
			(out:ByteArrayOutput) -> {
				out.writeVarUInt(1);
				out.writeByte(9);
			},
			(out:ByteArrayOutput) -> {
				out.writeVarUInt(1);
				out.writeByte(5);
				out.writeVarUInt(50);
			},
			(out:ByteArrayOutput) -> {
				out.writeVarUInt(1000);
				out.writeByte(0);
			},
			(out:ByteArrayOutput) -> {
				out.writeVarUInt(1);
				out.writeByte(3);
				out.writeByte(1);
			}
		]) {
			pair.link.client.send(frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_REQUEST);
				out.writeInt(OP);
				out.writeVarUInt(9);
				body(out);
			}));
		}
		Assert.equals(0, ran);
		Assert.same([for (_ in 0...4) "9: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	public function testAHandlerReEnteredIsHandedArgsOfItsOwn():Void {
		// The handler's call is delivered at once, to a handler on the same
		// session: the inner call's arguments are its own, and the outer's
		// are still there once it returns.
		var pair = new ArgsPair();
		var seen:Array<String> = [];
		pair.client.registerArgs(OP + 1, args -> {
			seen.push("inner " + args.string(0));
			return null;
		});
		pair.server.registerArgs(OP, args -> {
			final before = args.string(0);
			pair.server.call(OP + 1, ["echo of " + before]);
			pair.client.call(OP + 2, []);
			seen.push("outer " + before + " " + args.string(0) + " " + args.int(1));
			return null;
		});
		pair.server.registerArgs(OP + 2, args -> {
			seen.push("nested " + args.count);
			return null;
		});
		pair.client.call(OP, ["hi", 9]);
		Assert.same(["inner echo of hi", "nested 0", "outer hi hi 9"], seen);
	}

	static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		var payload = new ByteArrayOutput(64);
		write(payload);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	static function errorAnswersAt(connection:LinkedConnection):Array<String> {
		var answers:Array<String> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final end:Int = input.position + 4 + input.readInt();
				final flags:Int = input.readByte();
				input.readInt();
				if ((flags & RPCWire.FLAG_ERROR) != 0) {
					final id:Int = input.readVarUInt();
					answers.push(id + ": " + input.readVarUTF());
				}
				input.position = end;
			}
		};
		return answers;
	}
}

private class ArgsPair {
	public final link = LinkedConnection.pair();
	public final client:RPCSession<Dynamic, Dynamic>;
	public final server:RPCSession<Dynamic, Dynamic>;

	public function new() {
		client = new RPCSession(link.client);
		server = new RPCSession(link.server);
	}
}
