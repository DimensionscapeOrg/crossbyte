package crossbyte.events;

import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import haxe.io.Bytes;
import utest.Assert;

/**
	"Copy it to keep it": what an event that carries received bytes owes a
	listener that keeps it, on every target, and what each define does.

	`clone()` is the one way to keep a whole event, so a clone copies the
	bytes the event carries; and under `-D crossbyte_check_events` a payload
	is killed, once its delivery returns, in a way that cannot be missed by
	whatever kept it, its own length and position 0, and its storage
	overwritten for whatever kept the storage instead.
**/
@:access(crossbyte.events.Event)
class ArrivalsTest extends utest.Test {
	public function testTheDefinesSayWhatTheyDo():Void {
		#if crossbyte_check_events
		Assert.isFalse(Arrivals.REUSE, "nothing is reused under the check, so a killed payload stays dead");
		Assert.isTrue(Arrivals.CHECK);
		#elseif crossbyte_fresh_events
		Assert.isFalse(Arrivals.REUSE);
		Assert.isFalse(Arrivals.CHECK);
		#else
		Assert.isTrue(Arrivals.REUSE, "released, the hot events and payloads are reused");
		Assert.isFalse(Arrivals.CHECK);
		#end
	}

	public function testACloneOfADatagramEventKeepsItsBytesWhenTheEventsAreKilled():Void {
		var payload = bytesOf([1, 2, 3, 4, 5]);
		payload.endian = Endian.BIG_ENDIAN;
		payload.position = 2;
		var event = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "10.0.0.1", 4000, "10.0.0.2", 5000, payload);

		var kept:DatagramSocketDataEvent = cast event.clone();
		Arrivals.kill(payload);
		event.__kill();

		Assert.isTrue(kept.data != payload, "the clone shares the event's payload");
		Assert.same([1, 2, 3, 4, 5], valuesOf(kept.data), "the clone's bytes went with the event's");
		Assert.equals(2, kept.data.position);
		Assert.equals(Endian.BIG_ENDIAN, kept.data.endian);
		Assert.equals("10.0.0.1", kept.srcAddress);
		Assert.equals(4000, kept.srcPort);
		Assert.equals("10.0.0.2", kept.dstAddress);
		Assert.equals(5000, kept.dstPort);
		Assert.equals(DatagramSocketDataEvent.DATA, kept.type);
	}

	public function testACloneOfAWebSocketMessageKeepsItsBytesAndText():Void {
		var payload = new ByteArray();
		payload.writeUTFBytes("hello");
		payload.position = 0;
		var event = new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, payload, true);
		Assert.equals("hello", event.text);

		var kept:WebSocketMessageEvent = cast event.clone();
		Arrivals.kill(payload);
		event.__kill();

		Assert.isTrue(kept.data != payload, "the clone shares the event's message");
		Assert.equals(5, kept.data.length);
		Assert.equals("hello", kept.text);
		Assert.isTrue(kept.isText);
		kept.data.position = 0;
		Assert.equals("hello", kept.data.readUTFBytes(kept.data.length));
	}

	public function testACloneOfAnEventWithNoPayloadIsOne():Void {
		var event = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "10.0.0.1", 1, "10.0.0.2", 2, null);
		var kept:DatagramSocketDataEvent = cast event.clone();
		Assert.isNull(kept.data);
	}

	public function testAKilledPayloadReadsEmptyAndItsStorageReadsPoison():Void {
		var payload = bytesOf([10, 20, 30, 40]);
		payload.position = 1;
		// What a keeper of the storage would hold: the same bytes, by another
		// name, a Bytes over the payload's own storage.
		var storage:Bytes = Bytes.ofData((payload : Bytes).getData());

		Arrivals.kill(payload);

		Assert.equals(0, payload.length);
		Assert.equals(0, payload.position);
		Assert.equals(0, payload.bytesAvailable);
		Assert.raises(() -> payload.readUnsignedByte());
		#if eval
		// eval has no second view: a ByteArray is its own storage there, and
		// Bytes.ofData(getData()) is the ByteArray itself, so what a keeper
		// of the storage holds reads empty, as the payload does.
		Assert.equals(0, storage.length, "the storage outlived the kill");
		#else
		for (i in 0...4) {
			Assert.equals(Arrivals.POISON, storage.get(i), "byte " + i + " of the storage survived the kill");
		}
		#end
	}

	public function testAKilledPayloadCanBeKilledAgainAndNullIsNothing():Void {
		var payload = bytesOf([1]);
		Arrivals.kill(payload);
		Arrivals.kill(payload);
		Arrivals.kill(null);
		Assert.equals(0, payload.length);
	}

	public function testAKilledEventIsClearedButSaysWhatItWas():Void {
		var payload = bytesOf([1, 2]);
		var target = new EventDispatcher();
		var datagram = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "10.0.0.1", 4000, "10.0.0.2", 5000, payload);
		var seen:DatagramSocketDataEvent = null;
		target.addEventListener(DatagramSocketDataEvent.DATA, e -> seen = e);
		target.dispatchEvent(datagram);
		Assert.equals(target, seen.target);

		datagram.__kill();
		Assert.equals(DatagramSocketDataEvent.DATA, datagram.type);
		Assert.isNull(datagram.srcAddress);
		Assert.equals(-1, datagram.srcPort);
		Assert.isNull(datagram.dstAddress);
		Assert.equals(-1, datagram.dstPort);
		Assert.isNull(datagram.target);
		Assert.isNull(datagram.currentTarget);
		Assert.equals(payload, datagram.data, "the dead payload is still the one it carried");

		var progress = new ProgressEvent(ProgressEvent.SOCKET_DATA, 12, 0);
		progress.__kill();
		Assert.equals(ProgressEvent.SOCKET_DATA, progress.type);
		Assert.isTrue(progress.bytesLoaded == (cast -1 : UInt));
		Assert.isTrue(progress.bytesTotal == (cast -1 : UInt));

		var message = new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, bytesOf([104, 105]), true);
		Assert.equals("hi", message.text);
		message.__kill();
		Assert.isFalse(message.isText);

		var error = new IOErrorEvent(IOErrorEvent.IO_ERROR, "why", 7);
		error.__kill();
		Assert.isNull(error.text);
		Assert.equals(-1, error.errorID);
	}

	public function testAKilledMessageEventMakesNoTextFromItsDeadBytes():Void {
		var payload = new ByteArray();
		payload.writeUTFBytes("later");
		var message = new WebSocketMessageEvent(WebSocketMessageEvent.MESSAGE, payload, true);
		Arrivals.kill(payload);
		message.__kill();
		Assert.equals("", message.text, "text read after the call came from somewhere other than the dead message");
	}

	public function testDoneKillsOnlyUnderTheCheck():Void {
		var payload = bytesOf([7, 8, 9]);
		var event = new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "10.0.0.1", 1, "10.0.0.2", 2, payload);
		Arrivals.done(payload);
		Arrivals.doneWith(event);
		#if crossbyte_check_events
		Assert.equals(0, payload.length);
		Assert.isNull(event.srcAddress);
		#else
		Assert.same([7, 8, 9], valuesOf(payload));
		Assert.equals("10.0.0.1", event.srcAddress);
		#end
	}

	public function testACopyIsItsOwn():Void {
		var payload = bytesOf([5, 6, 7]);
		payload.position = 3;
		payload.endian = Endian.LITTLE_ENDIAN;
		var copy = Arrivals.copyOf(payload);
		payload.position = 0;
		payload.writeByte(99);
		Assert.same([5, 6, 7], valuesOf(copy));
		Assert.equals(3, copy.position);
		Assert.equals(Endian.LITTLE_ENDIAN, copy.endian);
		Assert.isNull(Arrivals.copyOf(null));
		Assert.equals(0, Arrivals.copyOf(new ByteArray()).length);
	}

	private static function bytesOf(values:Array<Int>):ByteArray {
		var bytes = new ByteArray();
		for (value in values) {
			bytes.writeByte(value);
		}
		bytes.position = 0;
		return bytes;
	}

	private static function valuesOf(bytes:ByteArray):Array<Int> {
		var raw:Bytes = bytes;
		return [for (i in 0...bytes.length) raw.get(i)];
	}
}
