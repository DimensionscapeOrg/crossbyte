import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import haxe.Timer;

/**
	One message to many reliable UDP sessions, over real loopback sockets in
	one process: a server with `sessions` accepted sessions and as many
	clients, each client losing `loss` of the datagrams it receives and of
	those it sends (1% unless given). A round sends one `size`-byte reliable
	message to every session (`mode=prepared`: one `PreparedDatagram`
	and the server's `broadcast`; `mode=send`: `send` on each session) and
	pumps until every client has it and every session's frames are
	acknowledged.

	Reports, per run:

	- `held`: the first round sends ten messages to every session before
	  anything is pumped; the heap after a full collection then, less
	  before, per message: what the sessions hold for a message until it
	  is acknowledged, every pool still empty (natively `MEM_INFO_USAGE`,
	  whose noise one message's worth would sink in);
	- `call`: the sending call's wall time for one message to every
	  session, the median round, and per session;
	- `round`: from the call until everything is acknowledged, the median;
	- `alloc`: bytes allocated per round, natively with collection off (the
	  growth in what the collector reserved), on the jvm the thread's own
	  count; server and clients together, the same clients for both modes.

	Arguments: mode (prepared), sessions (1000), size (1024), loss (0.01),
	rounds (40), warm (10), encrypt=1, label. Build with `-D rt_before`
	against sources without `PreparedDatagram` for `mode=send` only.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.DatagramSocket)
class RudpFanout extends HostApplication {
	static var opts:Map<String, String> = new Map();

	static function opt(name:String, value:String):String {
		return opts.exists(name) ? opts.get(name) : value;
	}

	static function optInt(name:String, value:Int):Int {
		return Std.parseInt(opt(name, Std.string(value)));
	}

	static function main():Void {
		for (arg in Sys.args()) {
			var at = arg.indexOf("=");
			if (at > 0) {
				opts.set(arg.substr(0, at), arg.substr(at + 1));
			}
		}
		new RudpFanout().run();
	}

	var accepted:Array<ReliableDatagramSocket> = [];
	var clients:Array<LossyClient> = [];
	var got:Int = 0;
	var last:Float = 0;

	function new() {
		super();
	}

	function pump():Void {
		var now = Timer.stamp();
		advance(now - last, 0);
		last = now;
	}

	static function heap():Float {
		#if cpp
		cpp.vm.Gc.run(true);
		return cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		#elseif jvm
		var rt = java.lang.Runtime.getRuntime();
		for (_ in 0...3) {
			java.lang.System.gc();
		}
		return haxe.Int64.toInt(rt.totalMemory() - rt.freeMemory()) * 1.0;
		#else
		return 0;
		#end
	}

	#if jvm
	static function allocated():Float {
		var bean:AllocatingThreadBean = cast java.lang.management.ManagementFactory.getThreadMXBean();
		var self:haxe.Int64 = java.lang.Thread.currentThread().getId();
		var value:haxe.Int64 = bean.getThreadAllocatedBytes(self);
		return haxe.Int64.toInt(value >> 10) * 1024.0 + haxe.Int64.toInt(value & 1023);
	}
	#end

	/** Chunks the runtime's datagram sockets hold, in use or kept. **/
	static function chunksKept():Int {
		#if (cpp && !rt_before)
		var pool = @:privateAccess crossbyte.core.CrossByte.current().__datagramChunks();
		return pool.idle + pool.inUse;
		#else
		return 0;
		#end
	}

	function allAcknowledged():Bool {
		for (s in accepted) {
			if ((s.__windowBase : Int) != (s.__outSequence : Int)) {
				return false;
			}
		}
		return true;
	}

	function run():Void {
		var sessions = optInt("sessions", 1000);
		var size = optInt("size", 1024);
		var mode = opt("mode", "prepared");
		LossyClient.loss = Std.parseFloat(opt("loss", "0.01"));
		var message = new ByteArray();
		message.length = size;
		for (i in 0...size) {
			(message : haxe.io.Bytes).set(i, i & 0xFF);
		}

		var server = new ReliableDatagramServerSocket();
		server.maxPendingConnections = -1;
		var key:haxe.io.Bytes = null;
		if (opt("encrypt", "0") == "1") {
			key = haxe.io.Bytes.alloc(32);
			for (i in 0...32) {
				key.set(i, i * 7);
			}
			Reflect.setField(server, "encryptionKeyFor", (_:String, _:Int, _:ByteArray) -> key);
		}
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, (e:ReliableDatagramSocketConnectEvent) -> accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		last = Timer.stamp();
		var lossWas = LossyClient.loss;
		// Joined without loss, so every session starts alike.
		LossyClient.loss = 0;
		for (i in 0...sessions) {
			var c = new LossyClient();
			if (key != null) {
				Reflect.setProperty(c, "encryptionKey", key);
			}
			c.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> got++);
			c.bind(0, "127.0.0.1");
			c.connect("127.0.0.1", server.localPort);
			clients.push(c);
			if (i % 50 == 49) {
				pump();
			}
		}
		var deadline = Timer.stamp() + 60;
		while ((accepted.length < sessions || !allConnected()) && Timer.stamp() < deadline) {
			pump();
			crossbyte.sys.System.sleep(0.001);
		}
		if (accepted.length < sessions) {
			Sys.println('only ${accepted.length} of $sessions connected');
			Sys.exit(1);
		}
		// Settled: handshakes acknowledged.
		var settle = Timer.stamp() + 0.5;
		while (Timer.stamp() < settle) {
			pump();
		}
		LossyClient.loss = lossWas;

		var calls:Array<Float> = [];
		var rounds:Array<Float> = [];
		var stalls = 0;
		// `messages` sent before anything is pumped: on the first round, ten,
		// so what they hold stands out of the heap's noise.
		function round(measureHeld:Bool, messages:Int):Float {
			var want = got + sessions * messages;
			var before:Float = measureHeld ? heap() : 0;
			var chunksBefore:Int = chunksKept();
			var t0 = Timer.stamp();
			for (_ in 0...messages) {
				if (mode == "prepared") {
					#if !rt_before
					server.broadcast(crossbyte.net.PreparedDatagram.of(message));
					#else
					throw "no PreparedDatagram in this build";
					#end
				} else {
					for (s in accepted) {
						s.send(message, 0, size);
					}
				}
			}
			var t1 = Timer.stamp();
			var held:Float = 0;
			if (measureHeld) {
				// Onto the wire, nothing pumped, so nothing acknowledged: what
				// is left on the heap is what the sessions keep, not the pass's
				// datagrams waiting in the socket's batch.
				for (s in accepted) {
					s.flush();
				}
				// Batched natively only.
				#if cpp
				@:privateAccess server.__socket.__flushPass();
				#end
				// Less the chunks the pass's datagrams took from the runtime's
				// pool, which it keeps for the next pass, not for the sessions.
				held = (heap() - before - (chunksKept() - chunksBefore) * 65536.0) / messages;
			}
			calls.push((t1 - t0) / messages);
			var limit = Timer.stamp() + 30;
			while ((got < want || !allAcknowledged()) && Timer.stamp() < limit) {
				pump();
			}
			if (Timer.stamp() >= limit) {
				stalls++;
			}
			rounds.push(Timer.stamp() - t0);
			return held;
		}

		var held = round(true, 10);
		calls = [];
		rounds = [];
		for (_ in 0...optInt("warm", 10)) {
			round(false, 1);
		}
		calls = [];
		rounds = [];

		var count = optInt("rounds", 40);
		#if cpp
		cpp.vm.Gc.run(true);
		cpp.vm.Gc.enable(false);
		var m0 = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		#elseif jvm
		var m0 = allocated();
		#else
		var m0 = 0.0;
		#end
		for (_ in 0...count) {
			round(false, 1);
		}
		#if cpp
		var m1 = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED);
		cpp.vm.Gc.enable(true);
		#elseif jvm
		var m1 = allocated();
		#else
		var m1 = 0.0;
		#end
		var call = median(calls);
		Sys.println('FANOUT label=${opt("label", "")} target=${#if cpp "native" #elseif jvm "jvm" #else "other" #end} mode=$mode sessions=$sessions size=$size '
			+ 'loss=${LossyClient.loss} encrypt=${key != null} held=${Math.round(held)}B heldPerSession=${Math.round(held / sessions)}B '
			+ 'call median=${r(call * 1e6)}us perSession=${r(call * 1e9 / sessions)}ns round median=${r(median(rounds) * 1000)}ms '
			+ 'alloc/round=${Math.round((m1 - m0) / count)}B stalls=$stalls');
		Sys.exit(0);
	}

	function allConnected():Bool {
		for (c in clients) {
			if (!c.connected) {
				return false;
			}
		}
		return true;
	}

	static function median(values:Array<Float>):Float {
		var sorted = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return sorted[sorted.length >> 1];
	}

	static function r(x:Float):Float {
		return Math.round(x * 100) / 100;
	}
}

/** A client that loses `loss` of the datagrams it receives and of those it sends, the same ones every run. **/
@:access(crossbyte.net.ReliableDatagramSocket)
class LossyClient extends ReliableDatagramSocket {
	public static var loss:Float = 0.01;
	static var seed:Int = 12345;

	static function chance():Float {
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
		return seed / 2147483647.0;
	}

	public function new() {
		super();
	}

	override public function __receiveDatagram(data:ByteArray, address:String, port:Int):Void {
		if (loss > 0 && chance() < loss) {
			return;
		}
		super.__receiveDatagram(data, address, port);
	}

	override private function __sendBytes(buffer:ByteArray, offset:Int, length:Int):Bool {
		if (loss > 0 && chance() < loss) {
			return true;
		}
		return super.__sendBytes(buffer, offset, length);
	}
}

#if jvm
@:native("com.sun.management.ThreadMXBean")
extern interface AllocatingThreadBean {
	function getThreadAllocatedBytes(id:haxe.Int64):haxe.Int64;
}
#end
