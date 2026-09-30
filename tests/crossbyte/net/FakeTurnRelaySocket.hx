package crossbyte.net;

// Real sockets, so not for the browser. Node has them but cannot pump a test
// while it waits, so the cases using this run natively and on the jvm.
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
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

	@:noCompletion private var __control:DatagramSocket;
	@:noCompletion private var __relays:Map<Int, DatagramSocket> = new Map();
	@:noCompletion private var __tick:TickEvent->Void;
	@:noCompletion private var __runtime:CrossByte;

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

	public function close():Void {
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
#end
