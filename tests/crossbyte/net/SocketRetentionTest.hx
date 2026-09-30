package crossbyte.net;

import crossbyte.ds.Stack;
import utest.Assert;
#if !js
import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
#end

/**
	What a closed connection leaves behind in the runtime: nothing.

	The socket registry kept every connection that wrote in a busy pass. Its
	writable queue is a `Stack`, and `Stack.clear()` only reset the count, so
	the backing array went on holding each socket queued there; the select
	buffer kept the last sockets polled once the set emptied. Through
	`sys.net.Socket.custom` each held the whole `Socket`, its buffers and its
	`userData`: 150 closed connections carrying 64 KB each all survived five
	collections on the jvm.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.Socket)
class SocketRetentionTest extends utest.Test {
	private static inline var COUNT:Int = 40;

	public function testAClearedStackHoldsNothing():Void {
		var stack:Stack<Held> = new Stack();
		for (_ in 0...10) {
			stack.push(new Held());
		}
		stack.clear();

		Assert.equals(0, __nonNull(@:privateAccess stack.__items), "a cleared stack still holds what it held");
		Assert.equals(0, stack.length);

		// Emptied, not disposed: it goes on working, from its old capacity.
		var again:Held = new Held();
		stack.push(again);
		Assert.equals(1, stack.length);
		Assert.equals(again, stack.pop());
	}

	#if !js
	/**
		Every connection writes in one pass and then closes, as a broadcast
		followed by everyone leaving does; the runtime's registry is then
		searched for any of their sockets.
	**/
	@:timeout(30000)
	public function testTheRegistryLetsGoOfClosedConnections():Void {
		var outcome:Outcome = __broadcastThenClose(COUNT);
		Assert.equals(COUNT, outcome.accepted, "not every connection was accepted");

		var registry = CrossByte.current().__socketRegistry;
		var kept:Int = __countIn(@:privateAccess registry.__writableQueue.__items, outcome.sockets)
			+ __countIn(@:privateAccess registry.__writableSwap.__items, outcome.sockets);
		Assert.equals(0, kept, 'the registry\'s writable queue still holds $kept of $COUNT closed connections');

		#if !cpp
		var selected:Int = __countIn(@:privateAccess registry.__selectBuffer, outcome.sockets);
		Assert.equals(0, selected, 'the registry\'s select buffer still holds $selected of $COUNT closed connections');
		#end

		outcome.sockets.resize(0);
	}
	#end

	#if (java || jvm || cpp)
	/**
		The same, measured by what the collector can take: a weak reference
		to each closed connection, each carrying 64 KB of userData.
	**/
	@:timeout(30000)
	public function testClosedConnectionsAreCollected():Void {
		var outcome:Outcome = __broadcastThenClose(COUNT);
		Assert.equals(COUNT, outcome.accepted, "not every connection was accepted");
		outcome.sockets.resize(0);

		var alive:Int = COUNT;
		for (_ in 0...5) {
			__collect();
			__pump(0.05);
			alive = 0;
			for (ref in outcome.weak) {
				if (ref.get() != null) {
					alive++;
				}
			}
			if (alive == 0) {
				break;
			}
		}

		Assert.equals(0, alive, '$alive of $COUNT closed connections, each with 64 KB of userData, survived five collections');
	}
	#end

	#if !js
	/**
		Accepts `count` connections, gives each 64 KB of userData, has each
		write once in the same pass, and closes everything. Kept in a function
		of its own so nothing it touched is left on the stack of the caller,
		which is where the collector is asked afterwards.
	**/
	private static function __broadcastThenClose(count:Int):Outcome {
		var server:ServerSocket = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var clients:Array<Socket> = [];
		for (_ in 0...count) {
			var client:Socket = new Socket();
			client.connect("127.0.0.1", server.localPort);
			clients.push(client);
		}
		__pumpUntil(() -> accepted.length == count, 20.0);

		var outcome:Outcome = {accepted: accepted.length, sockets: [], weak: []};
		for (socket in accepted) {
			socket.userData = Bytes.alloc(64 * 1024);
			outcome.sockets.push(socket.__socket);
			#if (java || jvm)
			outcome.weak.push(new java.lang.ref.WeakReference<Socket>(socket));
			#elseif cpp
			outcome.weak.push(new cpp.vm.WeakRef<Socket>(socket));
			#end
		}

		// One pass in which every connection writes: each joins the
		// registry's writable queue, which the next pass drains.
		for (socket in accepted) {
			socket.writeUTFBytes("tick");
			socket.flush();
		}
		__pump(0.1);

		for (socket in accepted) {
			try socket.close() catch (_:Dynamic) {}
		}
		for (client in clients) {
			try client.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
		__pump(0.2);

		accepted.resize(0);
		clients.resize(0);
		return outcome;
	}

	private static function __countIn(items:Array<Null<sys.net.Socket>>, sockets:Array<sys.net.Socket>):Int {
		var found:Int = 0;
		if (items == null) {
			return found;
		}
		for (item in items) {
			if (item != null && sockets.indexOf(item) >= 0) {
				found++;
			}
		}
		return found;
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Bool {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + timeout;
		var last:Float = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			Sys.sleep(0.001);
		}
		return done();
	}

	private static function __pump(seconds:Float):Void {
		__pumpUntil(() -> false, seconds);
	}
	#end

	#if (java || jvm || cpp)
	private static function __collect():Void {
		#if (java || jvm)
		java.lang.System.gc();
		#else
		cpp.vm.Gc.run(true);
		#end
	}
	#end

	private static function __nonNull(items:Array<Dynamic>):Int {
		var count:Int = 0;
		for (item in items) {
			if (item != null) {
				count++;
			}
		}
		return count;
	}
}

private class Held {
	public function new() {}
}

#if !js
private typedef Outcome = {
	var accepted:Int;
	var sockets:Array<sys.net.Socket>;
	var weak:Array<#if (java || jvm) java.lang.ref.WeakReference<Socket> #elseif cpp cpp.vm.WeakRef<Socket> #else Dynamic #end>;
}
#end
