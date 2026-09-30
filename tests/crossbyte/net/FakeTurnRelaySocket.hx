package crossbyte.net;

// Real sockets, so not for the browser. Node has them but cannot pump a test
// while it waits, so the cases using this run natively and on the jvm.
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.FakeTurnRelay.RelayEndpoint;

/**
	`FakeTurnRelay` on real sockets: one it listens on, and one more for each
	allocation, bound for the address the allocation relays from.

	So a client talking to it is talking over UDP, through whatever socket it
	would use against a real relay, and a peer sending to a relayed address is
	sending to a port that exists. Anything the relay holds back for `delay` is
	let go from the runtime's tick.
**/
class FakeTurnRelaySocket {
	public var relay(default, null):FakeTurnRelay;

	/** The port the relay listens on, once started. **/
	public var port(default, null):Int = 0;

	/** The address it listens on and relays from. **/
	public var address(default, null):String = "127.0.0.1";

	/**
		Added to the wall clock for the relay's own: a test that wants a nonce
		stale or an allocation expired moves this rather than waiting.
	**/
	public var clockOffset:Float = 0;

	/** The port it takes TCP connections on, once `startTcp` has listened; 0 before. **/
	public var tcpPort(default, null):Int = 0;

	@:noCompletion private var __control:DatagramSocket;
	@:noCompletion private var __relays:Map<Int, DatagramSocket> = new Map();
	@:noCompletion private var __tick:TickEvent->Void;
	@:noCompletion private var __runtime:CrossByte;
	@:noCompletion private var __listener:ServerSocket;

	/** TCP clients by "address:port", with what they sent that is not yet a whole message. **/
	@:noCompletion private var __streams:Map<String, FakeStreamClient> = new Map();

	public function new(?relay:FakeTurnRelay) {
		this.relay = relay != null ? relay : new FakeTurnRelay();
	}

	public function now():Float {
		return haxe.Timer.stamp() + clockOffset;
	}

	public function start(address:String = "127.0.0.1"):Void {
		this.address = address;

		__control = new DatagramSocket();
		__control.bind(0, address);
		port = __control.localPort;
		__control.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			relay.receive(e.data, e.srcAddress, e.srcPort, now());
		});
		__control.receive();

		relay.onToClient = function(bytes:ByteArray, to:String, toPort:Int):Void {
			// Down the connection a TCP client came on, or as a datagram.
			var stream = __streams.get(to + ":" + toPort);

			if (stream != null) {
				try {
					stream.socket.writeBytes(bytes, 0, bytes.length);
					stream.socket.flush();
				} catch (_:Dynamic) {}

				return;
			}

			if (__control != null) {
				try {
					__control.send(bytes, 0, bytes.length, to, toPort);
				} catch (_:Dynamic) {}
			}
		};

		relay.onToPeer = function(relayPort:Int, bytes:ByteArray, to:String, toPort:Int):Void {
			var socket = __relays.get(relayPort);

			if (socket != null) {
				try {
					socket.send(bytes, 0, bytes.length, to, toPort);
				} catch (_:Dynamic) {}
			}
		};

		relay.openRelay = function():RelayEndpoint {
			var socket = new DatagramSocket();
			socket.bind(0, address);
			var relayPort:Int = socket.localPort;
			socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
				relay.fromPeer(relayPort, e.data, e.srcAddress, e.srcPort, now());
			});
			socket.receive();
			__relays.set(relayPort, socket);
			return {address: address, port: relayPort};
		};

		relay.closeRelay = function(relayPort:Int):Void {
			var socket = __relays.get(relayPort);
			__relays.remove(relayPort);

			if (socket != null) {
				try {
					socket.close();
				} catch (_:Dynamic) {}
			}
		};

		__runtime = CrossByte.current();
		__tick = function(_:TickEvent):Void {
			relay.flush(now());
		};
		__runtime.addEventListener(TickEvent.TICK, __tick);
	}

	/**
		Takes TCP connections too, on a port of its own: RFC 8656's framing,
		each message whole, a STUN message by its header's length, ChannelData
		by its own, padded to four bytes both ways. A connection's end is its
		allocation's. Call after `start`.
	**/
	public function startTcp():Void {
		relay.padChannelData = true;

		__listener = new ServerSocket();
		__listener.bind(0, address);
		__listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var socket:Socket = e.socket;
			var client = new FakeStreamClient(socket, socket.remoteAddress, socket.remotePort);
			__streams.set(client.key, client);

			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_:ProgressEvent):Void {
				var chunk = new ByteArray();
				socket.readBytes(chunk, 0, socket.bytesAvailable);
				client.buffer.position = client.buffer.length;
				client.buffer.writeBytes(chunk, 0, chunk.length);

				for (message in client.messages()) {
					relay.receive(message, client.address, client.port, now());
				}
			});

			socket.addEventListener(Event.CLOSE, function(_:Event):Void {
				__streams.remove(client.key);
				relay.forgetClient(client.address, client.port);
			});
		});
		__listener.listen();
		tcpPort = __listener.localPort;
	}

	public function close():Void {
		for (stream in __streams) {
			try {
				stream.socket.close();
			} catch (_:Dynamic) {}
		}

		__streams = new Map();

		if (__listener != null) {
			try {
				__listener.close();
			} catch (_:Dynamic) {}

			__listener = null;
		}

		if (__tick != null) {
			try {
				__runtime.removeEventListener(TickEvent.TICK, __tick);
			} catch (_:Dynamic) {}

			__tick = null;
		}

		for (socket in __relays) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}

		__relays = new Map();

		if (__control != null) {
			try {
				__control.close();
			} catch (_:Dynamic) {}

			__control = null;
		}
	}
}

/** One TCP client of the relay, and the bytes it sent that are not a whole message yet. **/
private class FakeStreamClient {
	public var socket(default, null):Socket;
	public var address(default, null):String;
	public var port(default, null):Int;
	public var key(default, null):String;
	public var buffer:ByteArray = new ByteArray();

	public function new(socket:Socket, address:String, port:Int) {
		this.socket = socket;
		this.address = address;
		this.port = port;
		this.key = address + ":" + port;
	}

	/** Every whole message the buffer holds, taken out of it. **/
	public function messages():Array<ByteArray> {
		var found:Array<ByteArray> = [];
		var at:Int = 0;

		while (buffer.length - at >= 4) {
			var first:Int = buffer[at];
			var length:Int = (buffer[at + 2] << 8) | buffer[at + 3];
			var size:Int = first < 0x40 ? 20 + length : 4 + length;
			var framed:Int = first < 0x40 ? size : 4 + length + ((4 - (length % 4)) % 4);

			if ((first < 0x40 && buffer.length - at < 20) || buffer.length - at < framed) {
				break;
			}

			var message = new ByteArray();
			message.writeBytes(buffer, at, size);
			message.position = 0;
			found.push(message);
			at += framed;
		}

		if (at > 0) {
			var rest = new ByteArray();

			if (buffer.length > at) {
				rest.writeBytes(buffer, at, buffer.length - at);
			}

			buffer = rest;
		}

		return found;
	}
}
#end
