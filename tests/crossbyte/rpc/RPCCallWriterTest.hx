package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;

/**
	`RPCSession.runtimeCall` and `runtimeRequest`: runtime-lane calls written
	value by value into the session's frame, the same frames `call` and
	`request` send, with no array.
**/
class RPCCallWriterTest extends utest.Test {
	static inline final OP:Int = 300;

	public function testAWrittenCallIsTheFrameCallSends():Void {
		var bytes = Bytes.ofString("xyz");
		var byCall = framesOf(session -> session.call(OP, [7, -1.5, "hé", true, false, null, bytes]));
		var byWriter = framesOf(session -> session.runtimeCall(OP).int(7).float(-1.5).string("hé").bool(true).bool(false).nullValue().bytes(bytes).send());
		Assert.equals(1, byCall.length);
		Assert.equals(byCall[0], byWriter[0]);
		// And `value` tags as call does.
		var byValue = framesOf(session -> session.runtimeCall(OP).value(7).value(-1.5).value("hé").value(true).value(false).value(null).value(bytes).send());
		Assert.equals(byCall[0], byValue[0]);
	}

	public function testAWrittenCallReachesAnArrayHandler():Void {
		var pair = new SessionPair();
		var got:Array<Dynamic> = null;
		pair.server.register(OP, args -> {
			got = args;
			return null;
		});
		pair.client.runtimeCall(OP).int(1).float(2).string(null).bytes(null).send();
		Assert.equals(4, got.length);
		Assert.equals(1, got[0]);
		Assert.equals(2.0, got[1]);
		Assert.isNull(got[2]);
		Assert.isNull(got[3]);
	}

	public function testAWrittenRequestIsAnswered():Void {
		var pair = new SessionPair();
		pair.server.register(OP, args -> (args[0] : Int) + (args[1] : Int));
		var answer = pair.client.runtimeRequest(OP).int(7).int(35).send();
		Assert.isTrue(answer.succeeded);
		Assert.equals(42, answer.result);
		// One after another, each its own id.
		Assert.equals(3, pair.client.runtimeRequest(OP).int(1).int(2).send().result);
		Assert.equals(0, pair.client.callsWaiting);
	}

	public function testMoreThan127ValuesMoveAlongForTheirCount():Void {
		// A count past 127 is a varint of two bytes, past 16,383 of three:
		// the values written after the one byte kept for it move along.
		for (total in [0, 1, 127, 128, 300, 16383, 16384, 20000]) {
			var pair = new SessionPair();
			pair.server.maxFrameLength = 0;
			pair.client.maxFrameLength = 0;
			var got:Array<Dynamic> = null;
			pair.server.register(OP, args -> {
				got = args;
				return null;
			});
			var writer = pair.client.runtimeCall(OP);
			for (i in 0...total) {
				writer.int(i);
			}
			writer.send();
			Assert.notNull(got, 'a call of $total values did not arrive');
			if (got != null) {
				Assert.equals(total, got.length);
				Assert.equals(total == 0 ? null : total - 1, got.length == 0 ? null : got[got.length - 1]);
			}
			// The same frame as call's.
			var values:Array<Dynamic> = [for (i in 0...total) i];
			var byCall = framesOf(session -> session.call(OP, values), 0);
			var byWriter = framesOf(session -> {
				var w = session.runtimeCall(OP);
				for (i in 0...total) {
					w.int(i);
				}
				w.send();
			}, 0);
			Assert.equals(byCall[0], byWriter[0], 'a call of $total values was not the frame call sends');
		}
	}

	public function testAWriterUsedAfterItIsSentThrows():Void {
		var pair = new SessionPair();
		var writer = pair.client.runtimeCall(OP).int(1);
		writer.send();
		Assert.raises(() -> writer.int(2), IllegalOperationError);
		Assert.raises(() -> writer.send(), IllegalOperationError);
		var request = pair.client.runtimeRequest(OP).int(1);
		request.send();
		Assert.raises(() -> request.send(), IllegalOperationError);
	}

	public function testACancelledWriterGivesItsFrameBack():Void {
		var pair = new SessionPair();
		var writer = pair.client.runtimeCall(OP).int(1);
		// The session's own buffer, taken; under the checking defines every
		// frame is a fresh one and the session keeps none.
		#if !(crossbyte_check_events || crossbyte_fresh_events)
		Assert.isTrue((@:privateAccess pair.client.__frame != null && @:privateAccess pair.client.__frame.busy));
		#end
		writer.cancel();
		Assert.isFalse((@:privateAccess pair.client.__frame != null && @:privateAccess pair.client.__frame.busy));
		Assert.raises(() -> writer.int(2), IllegalOperationError);
		writer.cancel();
		// A request cancelled leaves nothing waiting.
		var request = pair.client.runtimeRequest(OP).int(1);
		request.cancel();
		Assert.equals(0, pair.client.callsWaiting);
		Assert.isFalse((@:privateAccess pair.client.__frame != null && @:privateAccess pair.client.__frame.busy));
	}

	public function testAWriterTakenWhileAnotherIsWrittenHasAFrameOfItsOwn():Void {
		var pair = new SessionPair();
		var calls:Array<String> = [];
		pair.server.register(OP, args -> {
			calls.push(args.join(","));
			return null;
		});
		var outer = pair.client.runtimeCall(OP).int(1);
		pair.client.runtimeCall(OP).int(2).int(3).send();
		outer.int(4).send();
		Assert.same(["2,3", "1,4"], calls);
		Assert.isFalse((@:privateAccess pair.client.__frame != null && @:privateAccess pair.client.__frame.busy));
	}

	public function testACallOverTheFrameLimitIsRefused():Void {
		var pair = new SessionPair();
		pair.client.maxFrameLength = 64;
		var writer = pair.client.runtimeCall(OP);
		for (i in 0...20) {
			writer.int(i);
		}
		Assert.raises(() -> writer.send(), ArgumentError);
		Assert.isFalse((@:privateAccess pair.client.__frame != null && @:privateAccess pair.client.__frame.busy));
		var request = pair.client.runtimeRequest(OP);
		for (i in 0...20) {
			request.int(i);
		}
		var answer = request.send();
		Assert.isFalse(answer.succeeded);
		Assert.isTrue(Std.isOfType(answer.cause, ArgumentError));
		Assert.equals(0, pair.client.callsWaiting);
	}

	public function testARequestOnAnEndedConnectionFailsAtOnce():Void {
		var pair = new SessionPair();
		pair.link.client.close();
		pair.link.server.close();
		pair.client.stop();
		var answer = pair.client.runtimeRequest(OP).int(1).send();
		Assert.isFalse(answer.succeeded);
		Assert.equals(0, pair.client.callsWaiting);
	}

	/** The frames `send` puts on the wire, as hex, the hello left out. **/
	static function framesOf(send:RPCSession<Dynamic, Dynamic>->Void, maxFrameLength:Int = -1):Array<String> {
		var link = LinkedConnection.pair();
		var session:RPCSession<Dynamic, Dynamic> = new RPCSession(link.client);
		if (maxFrameLength >= 0) {
			session.maxFrameLength = maxFrameLength;
		}
		var frames:Array<String> = [];
		link.server.readEnabled = true;
		link.server.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final start:Int = input.position;
				final length:Int = input.readInt();
				final frame = Bytes.alloc(length + 4);
				input.position = start;
				input.readBytes(frame, 0, length + 4);
				frames.push(frame.toHex());
			}
		};
		frames.resize(0);
		send(session);
		return frames;
	}
}

private class SessionPair {
	public final link = LinkedConnection.pair();
	public final client:RPCSession<Dynamic, Dynamic>;
	public final server:RPCSession<Dynamic, Dynamic>;

	public function new() {
		client = new RPCSession(link.client);
		server = new RPCSession(link.server);
	}
}
