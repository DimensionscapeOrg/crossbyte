package crossbyte._internal.socket.poll;

import crossbyte._internal.socket.HaxePollBackend;
import crossbyte._internal.socket.IPollableSocket;
import crossbyte._internal.socket.NativeSocketRegistry;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import utest.Assert;
#if cpp
import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
#end

/**
	What the registry tells a poll backend, and when.

	A backend that holds each descriptor with the system -- libuv's -- has to
	be told a socket is leaving while the socket is still open: `Socket`
	closed its descriptor and only then queued its deregistration, and libuv
	forbids closing a descriptor it is polling. The registry also skips
	`prepare` once its set is empty, so a backend never heard that the last
	socket left. A backend that failed kept failing every pass, polling
	nothing; one whose factory threw left the runtime with none; and growing
	disposed of the backend before making the next, with whatever factory was
	installed by then.
**/
@:access(crossbyte._internal.socket.NativeSocketRegistry)
class PollBackendSeamTest extends utest.Test {
	public function teardown():Void {
		PollBackendRegistry.clear();
	}

	public function testTheLastSocketToLeaveIsReportedAtOnce():Void {
		var fake:FakeBackend = new FakeBackend(8);
		PollBackendRegistry.register(_ -> fake);
		var registry:NativeSocketRegistry = new NativeSocketRegistry(8);
		var pair:Pair = new Pair();

		registry.register(pair.left);
		registry.update(0);
		Assert.same(["prepare 1"], fake.calls);

		// Out, before any pass: the backend hears at once, not at a prepare
		// that never comes for an empty set.
		registry.deregister(pair.left);
		Assert.same(["prepare 1", "remove"], fake.calls, "the backend was not told the socket had left");
		registry.update(0);
		Assert.same(["prepare 1", "remove"], fake.calls, "an empty set was prepared");
		pair.close();
	}

	public function testASocketBackBeforeItLeftIsPreparedAgain():Void {
		var fake:FakeBackend = new FakeBackend(8);
		PollBackendRegistry.register(_ -> fake);
		var registry:NativeSocketRegistry = new NativeSocketRegistry(8);
		var pair:Pair = new Pair();

		registry.register(pair.left);
		registry.update(0);
		registry.deregister(pair.left);
		registry.register(pair.left);
		registry.update(0);
		Assert.same(["prepare 1", "remove", "prepare 1"], fake.calls, "a socket the backend was told had gone was never given back to it");
		pair.close();
	}

	public function testAFailingBackendIsReplacedAndPollingGoesOn():Void {
		var fake:FakeBackend = new FakeBackend(8);
		fake.failEvents = true;
		PollBackendRegistry.register(_ -> fake);
		var registry:NativeSocketRegistry = new NativeSocketRegistry(8);
		var pair:Pair = new Pair();
		var reader:Counter = new Counter();
		pair.left.custom = reader;
		registry.register(pair.left);
		pair.right.output.writeString("x");

		// The failing pass, then passes on the built-in backend until the byte
		// is seen.
		var threw:Dynamic = null;
		try {
			for (_ in 0...50) {
				registry.update(0.01);
				if (reader.readable > 0) {
					break;
				}
			}
		} catch (e:Dynamic) {
			threw = e;
		}

		Assert.isNull(threw, "a backend's failure escaped the registry: " + threw);
		Assert.isTrue(fake.disposed, "the failed backend was kept");
		Assert.isOfType(registry.__poll, HaxePollBackend);
		Assert.isTrue(reader.readable > 0, "nothing was polled after the backend failed");
		pair.close();
	}

	public function testAFactoryThatThrowsLeavesTheBuiltInBackend():Void {
		var backend:PollBackend = PollBackendRegistry.createWith(_ -> throw "no backend today", 8);
		Assert.isOfType(backend, HaxePollBackend);
		backend.dispose();
	}

	public function testGrowingKeepsTheBackendARegistryWasMadeWith():Void {
		var made:Array<FakeBackend> = [];
		var order:Array<String> = [];
		PollBackendRegistry.register(capacity -> {
			var fake:FakeBackend = new FakeBackend(capacity);
			fake.order = order;
			order.push("made " + capacity);
			made.push(fake);
			return fake;
		});
		var registry:NativeSocketRegistry = new NativeSocketRegistry(2);
		// Installed since: not what this registry grows with.
		PollBackendRegistry.clear();

		var pairs:Array<Pair> = [for (_ in 0...3) new Pair()];
		for (pair in pairs) {
			registry.register(pair.left);
		}

		Assert.equals(2, made.length, "growing did not make a backend with the registry's own factory");
		Assert.same(["made 2", "made 3", "disposed 2"], order, "the old backend was disposed before the new one was made");
		Assert.equals((made[1] : PollBackend), registry.__poll);
		for (pair in pairs) {
			pair.close();
		}
	}

	#if cpp
	/**
		The runtime's own sockets: each leaves the backend while it is still
		open. Natively, where the runtime's registry is this one.
	**/
	@:access(crossbyte.core.CrossByte)
	@:access(crossbyte.net.Socket)
	@:access(sys.net.Socket)
	@:timeout(15000)
	public function testARuntimesSocketsLeaveTheBackendBeforeTheyClose():Void {
		var registry = CrossByte.current().__socketRegistry;
		var real:PollBackend = registry.__poll;
		var spy:FakeBackend = new FakeBackend(real.capacity, real);
		registry.__poll = spy;
		registry.__isDirty = true;

		var server:ServerSocket = new ServerSocket();
		var accepted:Socket = null;
		var client:Socket = new Socket();
		try {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> accepted != null && client.connected, 5.0);

			var acceptedRaw:SysSocket = accepted == null ? null : accepted.__socket;
			var clientRaw:SysSocket = client.__socket;
			Assert.notNull(acceptedRaw, "the connection was never accepted");

			accepted.close();
			client.close();
			__pumpUntil(() -> false, 0.1);

			for (raw in [acceptedRaw, clientRaw]) {
				var at:Int = spy.removed.indexOf(raw);
				Assert.isTrue(at >= 0, "the backend was never told a closed socket had left");
				if (at >= 0) {
					Assert.isTrue(spy.openWhenRemoved[at], "the backend was told a socket had left only after it was closed");
				}
			}
		} catch (e:Dynamic) {
			Assert.fail("threw: " + Std.string(e));
		}

		try server.close() catch (_:Dynamic) {}
		registry.__poll = real;
		registry.__isDirty = true;
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Bool {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + timeout;
		var last:Float = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now:Float = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			crossbyte.sys.System.sleep(0.001);
		}
		return done();
	}
	#end
}

/** A connected loopback pair. **/
private class Pair {
	public var left(default, null):SysSocket;
	public var right(default, null):SysSocket;

	public function new() {
		var listener:SysSocket = new SysSocket();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(1);
		right = new SysSocket();
		right.connect(new Host("127.0.0.1"), listener.host().port);
		left = listener.accept();
		listener.close();
		left.setBlocking(false);
	}

	public function close():Void {
		for (socket in [left, right]) {
			try socket.close() catch (_:Dynamic) {}
		}
	}
}

/** Counts what the registry dispatches to it. **/
private class Counter implements IPollableSocket {
	public var readable:Int = 0;
	public var registryClosed(get, never):Bool;

	public function new() {}

	private function get_registryClosed():Bool {
		return false;
	}

	public function registryOnReadable():Void {
		readable++;
	}

	public function registryOnWritable():Void {}

	public function registryHasBufferedInput():Bool {
		return false;
	}
}

/**
	A backend that records what it is told, and passes it on to a real one
	when given one.
**/
@:access(sys.net.Socket)
private class FakeBackend implements PollBackend {
	public var capacity(get, never):Int;
	public var readIndexes(default, null):Array<Int> = [-1];
	public var writeIndexes(default, null):Array<Int> = [-1];

	public var calls:Array<String> = [];
	public var order:Array<String> = null;
	public var removed:Array<SysSocket> = [];
	public var openWhenRemoved:Array<Bool> = [];
	public var failEvents:Bool = false;
	public var disposed:Bool = false;

	private var __capacity:Int;
	private var __real:Null<PollBackend>;

	public function new(capacity:Int, ?real:PollBackend) {
		__capacity = capacity;
		__real = real;
	}

	private function get_capacity():Int {
		return __capacity;
	}

	public function prepare(read:Array<SysSocket>, write:Array<SysSocket>):Void {
		calls.push("prepare " + (read == null ? 0 : read.length));
		if (__real != null) {
			__real.prepare(read, write);
			readIndexes = __real.readIndexes;
			writeIndexes = __real.writeIndexes;
		}
	}

	public function events(timeout:Float):Void {
		if (failEvents) {
			throw "backend broke";
		}
		if (__real != null) {
			__real.events(timeout);
			readIndexes = __real.readIndexes;
			writeIndexes = __real.writeIndexes;
		}
	}

	public function dispose():Void {
		disposed = true;
		if (order != null) {
			order.push("disposed " + __capacity);
		}
	}

	public function remove(socket:SysSocket):Void {
		calls.push("remove");
		removed.push(socket);
		#if cpp
		// Closing hands the handle back and forgets it.
		openWhenRemoved.push(socket.__s != null);
		#else
		openWhenRemoved.push(true);
		#end
		if (__real != null) {
			__real.remove(socket);
		}
	}
}
