package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.io.Endian;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	"Copy it to keep it" on a `DatagramSocket`, over real sockets: what a
	`DATA` listener is handed is right while it is handled, what it sends
	back is what arrived, and what it keeps, a clone, or the event itself,
	is what each mode says it is. And what a datagram too large to send
	says, which on Node comes back from Node later, as an event.

	Asynchronous, so Node runs it too: its datagrams come through a path of
	their own.
**/
@:access(crossbyte.net.DatagramSocket)
class DatagramArrivalTest extends utest.Test {
	@:timeout(15000)
	public function testWhatArrivesIsRightAndAnEchoCarriesIt(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		// The commonest thing a server does: send what arrived straight back.
		var during:Array<String> = [];
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			during.push(e.data.position + "/" + e.data.length + "/" + e.srcPort);
			pair.server.send(e.data, 0, 0, e.srcAddress, e.srcPort);
		});
		var back:Array<ByteArray> = [];
		pair.client.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var copy = new ByteArray();
			e.data.readBytes(copy);
			back.push(copy);
		});

		pair.whenReady(function():Void {
			pair.client.send(numbered(300, 1), 0, 0, "127.0.0.1", pair.server.localPort);
			pair.client.send(numbered(17, 2), 0, 0, "127.0.0.1", pair.server.localPort);
			pair.client.send(numbered(1200, 3), 0, 0, "127.0.0.1", pair.server.localPort);

			NetPump.until(() -> back.length >= 3, 5.0, function(_) {
				Assert.equals(3, back.length, "not every datagram came back");
				var port:Int = pair.client.localPort;
				Assert.same(['0/300/$port', '0/17/$port', '0/1200/$port'], during, "a datagram was not itself while it was handled");
				if (back.length == 3) {
					Assert.equals(-1, wrongByte(back[0], 300, 1), "the first echo carried other bytes");
					Assert.equals(-1, wrongByte(back[1], 17, 2), "the second echo carried other bytes");
					Assert.equals(-1, wrongByte(back[2], 1200, 3), "the third echo carried other bytes");
				}
				pair.close();
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAKeptCloneKeepsItsBytesAndAKeptEventIsWhatTheModeSays(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		var clones:Array<DatagramSocketDataEvent> = [];
		var events:Array<DatagramSocketDataEvent> = [];
		var payloads:Array<ByteArray> = [];
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			clones.push(cast e.clone());
			events.push(e);
			payloads.push(e.data);
		});

		pair.whenReady(function():Void {
			pair.client.send(numbered(64, 7), 0, 0, "127.0.0.1", pair.server.localPort);
			pair.client.send(numbered(900, 8), 0, 0, "127.0.0.1", pair.server.localPort);

			NetPump.until(() -> clones.length >= 2, 5.0, function(_) {
				Assert.equals(2, clones.length);
				if (clones.length == 2) {
					// A clone is the one way to keep a whole event, in every mode.
					Assert.equals(-1, wrongByte(clones[0].data, 64, 7));
					Assert.equals(-1, wrongByte(clones[1].data, 900, 8));
					Assert.equals(pair.client.localPort, clones[1].srcPort);

					#if crossbyte_check_events
					for (i in 0...2) {
						Assert.equals(0, payloads[i].length, "a payload kept past its call was left alive");
						Assert.isNull(events[i].srcAddress, "an event kept past its call still said where it came from");
						Assert.equals(-1, events[i].dstPort);
					}
					#elseif crossbyte_fresh_events
					Assert.isTrue(events[0] != events[1], "an event was handed out twice");
					Assert.equals(-1, wrongByte(payloads[0], 64, 7));
					Assert.equals(-1, wrongByte(payloads[1], 900, 8));
					#else
					// Released: the socket's one event and one payload, handed
					// out for each datagram and emptied once its call returned.
					Assert.isTrue(events[0] == events[1], "the socket's event was not handed out again");
					Assert.isTrue(payloads[0] == payloads[1], "the socket's payload was not handed out again");
					Assert.equals(0, payloads[1].length, "a payload kept past its call still read as the datagram");
					Assert.equals(0, payloads[1].position);
					Assert.isTrue(events[1].data == payloads[1]);
					#end
				}
				pair.close();
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testEveryArrivalStartsAtZeroInTheSocketsByteOrder(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		pair.server.endian = Endian.BIG_ENDIAN;
		var seen:Array<String> = [];
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var first:Int = e.data.readUnsignedShort();
			seen.push(e.data.position + ":" + e.data.length + ":" + (e.data.endian == Endian.BIG_ENDIAN ? "big" : "little") + ":" + first);
			// Left at its end, and in the other order: the next arrival is
			// not to start where this one was left.
			e.data.position = e.data.length;
			e.data.endian = Endian.LITTLE_ENDIAN;
		});

		pair.whenReady(function():Void {
			for (value in [0x0102, 0x0A0B, 0xFFEE]) {
				var bytes = new ByteArray();
				bytes.endian = Endian.BIG_ENDIAN;
				bytes.writeShort(value);
				bytes.writeByte(9);
				pair.client.send(bytes, 0, 0, "127.0.0.1", pair.server.localPort);
			}

			NetPump.until(() -> seen.length >= 3, 5.0, function(_) {
				Assert.same(["2:3:big:258", "2:3:big:2571", "2:3:big:65518"], seen);
				pair.close();
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAListenerThatThrowsLeavesTheNextArrivalRight(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		var calls:Int = 0;
		var after:Array<ByteArray> = [];
		var events:Array<DatagramSocketDataEvent> = [];
		// What the listener throws is the runtime's to report, natively and on
		// Node alike, and the socket goes on receiving.
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			calls++;
			events.push(e);
			if (calls == 1) {
				// Left mid-read: the next arrival starts at 0 regardless.
				e.data.position = 7;
				throw "a listener's own failure";
			}
			var copy = new ByteArray();
			e.data.readBytes(copy);
			after.push(copy);
		});

		pair.whenReady(function():Void {
			pair.client.send(numbered(40, 4), 0, 0, "127.0.0.1", pair.server.localPort);

			NetPump.until(() -> calls >= 1, 5.0, function(_) {
				pair.client.send(numbered(41, 5), 0, 0, "127.0.0.1", pair.server.localPort);
				NetPump.until(() -> after.length >= 1, 5.0, function(_) {
					Assert.equals(1, after.length, "nothing arrived after a listener threw");
					if (after.length == 1) {
						Assert.equals(-1, wrongByte(after[0], 41, 5), "the arrival after a listener threw was wrong");
						#if !(crossbyte_fresh_events || crossbyte_check_events)
						// The throw let go of them too: the socket's own
						// event, not one made because it still looked out.
						Assert.isTrue(events[0] == events[1], "a listener's throw left the socket's event out");
						Assert.isFalse(pair.server.__arrivalOut, "a listener's throw left the socket's payload out");
						#end
					}
					pair.close();
					async.done();
				});
			});
		});
	}

	/**
		Reuse holds nothing for a socket nothing has reached, and lets go of
		storage a large datagram grew past `Arrivals.KEEP` once its call has
		returned: one socket's rare 20 KB datagram is not held for good.
	**/
	@:timeout(15000)
	public function testALargeDatagramsStorageIsLetGoAndAnIdleSocketHoldsNone(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		Assert.isNull(pair.server.__arrival, "a socket that received nothing holds a payload");
		Assert.isNull(pair.server.__arrivalEvent, "a socket that received nothing holds an event");

		var seen:Array<String> = [];
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			seen.push(e.data.length + ":" + wrongByte(e.data, e.data.length, e.data.length == 20000 ? 3 : 4));
		});

		// macOS sends no datagram larger than the socket's send buffer, 9,216
		// bytes unless asked for more: the send failed (CI, 2026-10-05).
		if (DatagramSocket.bufferSizeSupported) {
			pair.client.sendBufferSize = 64 * 1024;
		}

		pair.whenReady(function():Void {
			pair.client.send(numbered(20000, 3), 0, 0, "127.0.0.1", pair.server.localPort);
			NetPump.until(() -> seen.length >= 1, 5.0, function(_) {
				var heldAfterLarge:Int = capacityOf(pair.server.__arrival);
				pair.client.send(numbered(100, 4), 0, 0, "127.0.0.1", pair.server.localPort);
				NetPump.until(() -> seen.length >= 2, 5.0, function(_) {
					Assert.same(["20000:-1", "100:-1"], seen, "a datagram was not itself");
					#if !(crossbyte_fresh_events || crossbyte_check_events)
					Assert.isTrue(heldAfterLarge <= Arrivals.KEEP, "a 20,000-byte datagram's storage was held after its call: " + heldAfterLarge);
					var held:Int = capacityOf(pair.server.__arrival);
					Assert.isTrue(held >= 100 && held <= Arrivals.KEEP, "the next datagram's storage: " + held);
					#else
					Assert.isNull(pair.server.__arrival, "a payload was kept for reuse with reuse off");
					#end
					pair.close();
					async.done();
				});
			});
		});
	}

	/**
		A datagram too large to send says so, and why, where it said only
		"Socket operation failed" (natively), which is all CI's macOS leg
		reported for a 20,000-byte datagram, since macOS sends none larger
		than the socket's send buffer, 9,216 bytes unless raised.

		65,520 bytes is past what UDP carries over IPv4 (65,507), and the
		system's refusal is what says so: natively, on the jvm and on Node.
		65,528 is past what it carries over either family, which is said
		on every target, HashLink and Neko included, whose sockets report
		every failure alike. Natively and on the jvm `send` throws; on Node
		the refusal is an `ioError` event, Node sending a turn later. With
		the send buffer at 8 KB, a 20,000-byte datagram is refused on macOS
		for the buffer, and goes everywhere else.
	**/
	@:timeout(15000)
	public function testADatagramTooLargeToSendSaysSoAndWhy(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		var reported:Array<String> = [];
		pair.client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			reported.push(e.text);
		});
		var arrived:Array<Int> = [];
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			arrived.push(e.data.length);
		});
		if (DatagramSocket.bufferSizeSupported) {
			pair.client.sendBufferSize = 8 * 1024;
		}

		pair.whenReady(function():Void {
			var thrown:Array<String> = [];
			for (length in [65520, 65528, 20000]) {
				try {
					pair.client.send(numbered(length, 5), 0, 0, "127.0.0.1", pair.server.localPort);
				} catch (e:IOError) {
					thrown.push(e.message);
				} catch (e:Dynamic) {
					thrown.push("not an IOError: " + Std.string(e));
				}
			}
			var macOS:Bool = #if nodejs js.Node.process.platform == "darwin" #else Sys.systemName() == "Mac" #end;
			// Where the system's own refusal is told apart from any other.
			var told:Bool = #if (cpp || jvm || nodejs) true #else false #end;
			var refusals:Int = macOS ? 3 : 2;
			NetPump.until(() -> reported.length >= refusals && (macOS || arrived.length >= 1), 5.0, function(_) {
				var buffer:Int = pair.client.sendBufferSize;
				var why:Int->String = length -> 'a datagram of $length bytes is larger than this socket can send ('
					+ (buffer > 0 ? 'sendBufferSize $buffer' : 'its send buffer size cannot be read here') + ')';
				// Nothing else reported: on Node a send buffer asked for between
				// bind() and Node binding was refused (ENOTSOCK), and the socket
				// stopped receiving for it.
				Assert.equals(refusals, reported.length, "the ioError events: " + reported.join(" | "));
				#if nodejs
				Assert.equals(0, thrown.length, "Node threw where it reports a send's failure as an event: " + thrown.join(" | "));
				var said:Array<String> = reported;
				#else
				Assert.equals(refusals, thrown.length, "a refused send did not throw: " + thrown.join(" | "));
				var said:Array<String> = thrown.concat(reported);
				#end
				if (DatagramSocket.bufferSizeSupported) {
					Assert.isTrue(buffer >= 8 * 1024, "the send buffer asked for before the socket was bound was not applied: " + buffer);
				}
				function saysWhy(length:Int):Bool {
					return said.filter(text -> text.indexOf(why(length)) >= 0).length == #if nodejs 1 #else 2 #end;
				}
				Assert.isTrue(saysWhy(65528), "a datagram too large for UDP was not named so: " + said.join(" | "));
				if (told) {
					Assert.isTrue(saysWhy(65520), "a datagram too large for UDP over IPv4 was not named so: " + said.join(" | "));
				}
				if (macOS) {
					if (told) {
						Assert.isTrue(saysWhy(20000), "a datagram past macOS's send buffer was not named so: " + said.join(" | "));
					}
				} else {
					Assert.same([20000], arrived, "a 20,000-byte datagram did not go with an 8 KB send buffer");
				}
				Assert.isTrue(pair.client.receiving, "a datagram too large to send stopped the socket receiving");
				pair.close();
				async.done();
			});
		});
	}

	#if !js
	@:timeout(15000)
	public function testANestedArrivalHasItsOwnEventAndBytes(async:Async):Void {
		var pair = Pair.make(async);
		if (pair == null) return;

		var runtime = CrossByte.current();
		var outer:String = null;
		var outerAfter:String = null;
		var outerFrom:Int = 0;
		var nested:String = null;
		var depth:Int = 0;
		pair.server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			depth++;
			if (depth == 1) {
				outer = e.data.toString();
				// The listener runs the loop, and the next datagram arrives inside it.
				var deadline:Float = haxe.Timer.stamp() + 3.0;
				while (nested == null && haxe.Timer.stamp() < deadline) {
					runtime.pump(0, 0);
					crossbyte.sys.System.sleep(0.001);
				}
				e.data.position = 0;
				outerAfter = e.data.toString();
				outerFrom = e.srcPort;
			} else {
				nested = e.data.toString();
			}
			depth--;
		});

		pair.whenReady(function():Void {
			pair.client.send(text("the outer one"), 0, 0, "127.0.0.1", pair.server.localPort);
			pair.client.send(text("the nested one, longer"), 0, 0, "127.0.0.1", pair.server.localPort);

			NetPump.until(() -> outerAfter != null, 5.0, function(_) {
				Assert.equals("the outer one", outer);
				Assert.equals("the nested one, longer", nested, "the nested datagram was not delivered as itself");
				Assert.equals("the outer one", outerAfter, "a datagram arriving inside a listener changed the one it was handling");
				Assert.equals(pair.client.localPort, outerFrom, "a datagram arriving inside a listener changed the event it was handling");
				pair.close();
				async.done();
			});
		});
	}
	#end

	// ------------------------------------------------------------- helpers

	/** The storage a payload holds, readable or not; 0 for none. **/
	private static function capacityOf(payload:ByteArray):Int {
		if (payload == null) {
			return 0;
		}
		var data:ByteArrayData = payload;
		return @:privateAccess data.__length;
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function numbered(length:Int, seed:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in 0...length) {
			bytes.writeByte((i * 13 + seed) & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	/** The first byte not as `numbered` made it, -1 for none, -2 for the wrong length. **/
	private static function wrongByte(bytes:ByteArray, length:Int, seed:Int):Int {
		if (bytes == null || bytes.length != length) {
			return -2;
		}
		var raw:Bytes = bytes;
		for (i in 0...length) {
			if (raw.get(i) != ((i * 13 + seed) & 0xFF)) {
				return i;
			}
		}
		return -1;
	}
}

/** Two datagram sockets on the loopback, receiving. **/
private class Pair {
	public var server:DatagramSocket;
	public var client:DatagramSocket;

	public static function make(async:Async):Pair {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			async.done();
			return null;
		}
		return new Pair();
	}

	private function new() {
		server = new DatagramSocket();
		client = new DatagramSocket();
		server.bind(0, "127.0.0.1");
		client.bind(0, "127.0.0.1");
		server.receive();
		client.receive();
	}

	/** Once both are bound, which on Node is a turn after `bind`. **/
	public function whenReady(then:Void->Void):Void {
		NetPump.until(() -> server.localPort > 0 && client.localPort > 0, 5.0, function(_) then());
	}

	public function close():Void {
		try server.close() catch (_:Dynamic) {}
		try client.close() catch (_:Dynamic) {}
	}
}
