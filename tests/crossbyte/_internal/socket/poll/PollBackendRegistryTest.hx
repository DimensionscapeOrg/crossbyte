package crossbyte._internal.socket.poll;

import sys.net.Host;
import sys.net.Socket as SysSocket;
import utest.Assert;

class PollBackendRegistryTest extends utest.Test {
	public function testRegisterFactoryCreatesCustomBackend():Void {
		PollBackendRegistry.clear();
		var createdCapacity = 0;
		var fake = new FakePollBackend(32);

		PollBackendRegistry.register(capacity -> {
			createdCapacity = capacity;
			return fake;
		});

		var backend = PollBackendRegistry.create(32);

		Assert.equals(32, createdCapacity);
		Assert.equals(fake, backend);

		PollBackendRegistry.clear();
	}

	public function testUnregisterRestoresFallbackBackend():Void {
		PollBackendRegistry.clear();
		var factory:Int->PollBackend = capacity -> new FakePollBackend(capacity);

		PollBackendRegistry.register(factory);
		Assert.isTrue(PollBackendRegistry.unregister(factory));
		Assert.isOfType(PollBackendRegistry.create(4), crossbyte._internal.socket.HaxePollBackend);

		PollBackendRegistry.clear();
	}

	public function testCustomBackendUpdatesReusableIndexes():Void {
		PollBackendRegistry.clear();
		var fake = new FakePollBackend(4);
		fake.readIndexes = [1, -1];
		fake.writeIndexes = [0, -1];

		PollBackendRegistry.register(_ -> fake);
		var backend = PollBackendRegistry.create(4);
		backend.prepare([], []);
		backend.events(0);

		Assert.same([1, -1], backend.readIndexes);
		Assert.same([0, -1], backend.writeIndexes);
		Assert.isTrue(fake.prepared);
		Assert.equals(0, fake.lastTimeout);

		PollBackendRegistry.clear();
	}

	public function testFallbackBackendPollsReadableSocket():Void {
		PollBackendRegistry.clear();
		var server = new SysSocket();
		var client = new SysSocket();
		var peer:SysSocket = null;
		var backend:PollBackend = null;
		var readableIndex = -1;

		try {
			server.bind(new Host("127.0.0.1"), 0);
			server.listen(1);

			client.connect(new Host("127.0.0.1"), server.host().port);

			backend = PollBackendRegistry.create(4);
			backend.prepare([server], []);
			for (_ in 0...20) {
				backend.events(0.05);
				readableIndex = backend.readIndexes[0];
				if (readableIndex == 0) {
					break;
				}
				Sys.sleep(0.01);
			}
			Assert.equals(0, readableIndex);

			peer = server.accept();
		} catch (e:Dynamic) {
			closeQuietly(peer);
			closeQuietly(client);
			closeQuietly(server);
			if (backend != null) {
				backend.dispose();
			}
			throw e;
		}

		if (backend != null) {
			backend.dispose();
		}
		closeQuietly(peer);
		closeQuietly(client);
		closeQuietly(server);
	}

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}

private class FakePollBackend implements PollBackend {
	public var capacity(get, never):Int;
	public var readIndexes:Array<Int> = [-1];
	public var writeIndexes:Array<Int> = [-1];
	public var prepared:Bool = false;
	public var lastTimeout:Float = -1;
	private var __capacity:Int;

	public function new(capacity:Int) {
		__capacity = capacity;
	}

	private inline function get_capacity():Int {
		return __capacity;
	}

	public function prepare(read:Array<SysSocket>, write:Array<SysSocket>):Void {
		prepared = true;
	}

	public function events(timeout:Float):Void {
		lastTimeout = timeout;
	}

	public function dispose():Void {}
}
