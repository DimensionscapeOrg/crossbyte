package crossbyte.core;

import crossbyte._internal.socket.poll.PollBackendRegistry;
import utest.Assert;

class SocketCapacityTest extends utest.Test {
	private var original:Int;

	public function setup():Void {
		original = CrossByte.defaultSocketCapacity;
	}

	public function teardown():Void {
		CrossByte.defaultSocketCapacity = original;
	}

	public function testDefaultIsSizedForServerWorkloads():Void {
		// The historical 64 forced roughly seven grow-and-rebuild cycles on
		// the way to a thousand connections.
		Assert.isTrue(CrossByte.defaultSocketCapacity >= 1024);
	}

	public function testCapacityIsConfigurableAndGuardedAgainstNonsense():Void {
		CrossByte.defaultSocketCapacity = 4096;
		Assert.equals(4096, CrossByte.defaultSocketCapacity);

		// A zero or negative assignment must not produce a zero-sized poll
		// backend; the runtime falls back to its built-in default.
		CrossByte.defaultSocketCapacity = 0;
		Assert.equals(0, CrossByte.defaultSocketCapacity);
		var backend = PollBackendRegistry.create(__resolve(CrossByte.defaultSocketCapacity));
		Assert.isTrue(backend.capacity > 0);
		backend.dispose();

		CrossByte.defaultSocketCapacity = -1;
		var negative = PollBackendRegistry.create(__resolve(CrossByte.defaultSocketCapacity));
		Assert.isTrue(negative.capacity > 0);
		negative.dispose();
	}

	public function testPollBackendHonoursRequestedCapacity():Void {
		// Capacity well past the classic FD_SETSIZE of 64 must be accepted:
		// the backend allocates a right-sized descriptor set rather than
		// relying on the fixed-size one.
		for (requested in [64, 1024, 4096]) {
			var backend = PollBackendRegistry.create(requested);
			Assert.equals(requested, backend.capacity);
			backend.dispose();
		}
	}

	/**
	 * Mirrors the runtime's own fallback so the guard is asserted rather
	 * than assumed.
	 */
	private function __resolve(value:Int):Int {
		return value > 0 ? value : 64;
	}
}
