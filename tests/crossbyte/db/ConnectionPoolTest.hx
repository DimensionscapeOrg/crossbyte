package crossbyte.db;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import utest.Assert;

/**
 * Stand-in for a driver connection, so pool behavior is tested without a
 * database server.
 */
private class FakeConnection {
	public var id(default, null):Int;
	public var closed(default, null):Bool = false;
	public var healthy:Bool = true;

	public function new(id:Int) {
		this.id = id;
	}

	public function close():Void {
		closed = true;
	}
}

class ConnectionPoolTest extends utest.Test {
	private var created:Array<FakeConnection>;
	private var nextId:Int;

	public function setup():Void {
		created = [];
		nextId = 0;
	}

	private function makePool(maxSize:Int = 2, ?validate:FakeConnection->Bool, ?acquireTimeout:Float):ConnectionPool<FakeConnection> {
		return new ConnectionPool({
			factory: function() {
				var connection = new FakeConnection(nextId++);
				created.push(connection);
				return connection;
			},
			close: connection -> connection.close(),
			validate: validate,
			maxSize: maxSize,
			acquireTimeout: (acquireTimeout == null) ? 0.05 : acquireTimeout
		});
	}

	public function testConnectionsAreCreatedLazilyAndReused():Void {
		var pool = makePool(4);
		Assert.equals(0, pool.size());

		var first = pool.acquire();
		Assert.equals(1, pool.size());
		Assert.equals(1, pool.inUse());
		Assert.equals(0, pool.available());

		pool.release(first);
		Assert.equals(0, pool.inUse());
		Assert.equals(1, pool.available());

		// A second acquire reuses rather than opening another connection.
		var second = pool.acquire();
		Assert.equals(first.id, second.id);
		Assert.equals(1, created.length);

		pool.release(second);
		pool.close();
	}

	public function testCeilingIsEnforcedAndAcquireTimesOut():Void {
		var pool = makePool(2);

		var a = pool.acquire();
		var b = pool.acquire();
		Assert.equals(2, pool.size());
		Assert.equals(2, pool.inUse());

		// Saturated: the next caller waits, then fails rather than opening
		// an unbounded number of connections.
		Assert.raises(() -> pool.acquire(), IllegalOperationError);
		Assert.equals(2, created.length);

		pool.release(a);
		var c = pool.acquire();
		Assert.equals(a.id, c.id);

		pool.release(b);
		pool.release(c);
		pool.close();
	}

	public function testWithConnectionReturnsConnectionEvenWhenBodyThrows():Void {
		var pool = makePool(1);

		var value = pool.withConnection(connection -> connection.id);
		Assert.equals(0, value);
		Assert.equals(0, pool.inUse());

		var threw = false;
		try {
			pool.withConnection(function(_):Int {
				throw "boom";
			});
		} catch (e:Dynamic) {
			threw = true;
			Assert.equals("boom", Std.string(e));
		}

		Assert.isTrue(threw);
		// Capacity must survive the error path, or a pool bleeds
		// connections until it deadlocks.
		Assert.equals(0, pool.inUse());
		Assert.equals(1, pool.available());

		pool.close();
	}

	public function testUnhealthyConnectionsAreReplacedOnAcquire():Void {
		var pool = makePool(2, connection -> connection.healthy);

		var first = pool.acquire();
		pool.release(first);

		// Simulate the server dropping an idle connection.
		first.healthy = false;

		var replacement = pool.acquire();
		Assert.notEquals(first.id, replacement.id);
		Assert.isTrue(first.closed);
		Assert.equals(2, created.length);
		Assert.equals(1, pool.size());

		pool.release(replacement);
		pool.close();
	}

	public function testDiscardRetiresConnectionAndFreesCapacity():Void {
		var pool = makePool(1);

		var broken = pool.acquire();
		pool.discard(broken);

		Assert.isTrue(broken.closed);
		Assert.equals(0, pool.size());
		Assert.equals(0, pool.inUse());

		// The retired connection's slot is reusable.
		var replacement = pool.acquire();
		Assert.notEquals(broken.id, replacement.id);

		pool.release(replacement);
		pool.close();
	}

	public function testCloseClosesIdleAndRejectsFurtherAcquire():Void {
		var pool = makePool(2);

		var a = pool.acquire();
		var b = pool.acquire();
		pool.release(a);

		pool.close();
		Assert.isTrue(pool.closed);
		Assert.isTrue(a.closed);
		// Still checked out, so not yet closed.
		Assert.isFalse(b.closed);

		Assert.raises(() -> pool.acquire(), IllegalOperationError);

		// Releasing after close retires the connection instead of pooling it.
		pool.release(b);
		Assert.isTrue(b.closed);
		Assert.equals(0, pool.available());

		// Idempotent.
		pool.close();
	}

	public function testDoubleReleaseAndForeignReleaseAreIgnored():Void {
		var pool = makePool(2);

		var connection = pool.acquire();
		pool.release(connection);
		pool.release(connection);
		pool.release(new FakeConnection(999));
		pool.release(null);

		// Accounting must not be corrupted into reporting phantom capacity.
		Assert.equals(1, pool.available());
		Assert.equals(0, pool.inUse());

		pool.close();
	}

	public function testFactoryFailureDoesNotConsumeCapacity():Void {
		var shouldFail = true;
		var pool = new ConnectionPool({
			factory: function() {
				if (shouldFail) {
					throw "cannot connect";
				}
				return new FakeConnection(nextId++);
			},
			close: connection -> connection.close(),
			maxSize: 1,
			acquireTimeout: 0.05
		});

		Assert.raises(() -> pool.acquire());
		Assert.equals(0, pool.size());

		// A failed connection attempt must not permanently consume the
		// pool's only slot.
		shouldFail = false;
		var connection = pool.acquire();
		Assert.notNull(connection);

		pool.release(connection);
		pool.close();
	}

	public function testConstructorValidatesOptions():Void {
		Assert.raises(() -> new ConnectionPool<FakeConnection>(null), ArgumentError);
		Assert.raises(() -> new ConnectionPool({factory: null}), ArgumentError);
		Assert.raises(() -> new ConnectionPool({factory: () -> new FakeConnection(0), maxSize: 0}), ArgumentError);
		Assert.raises(() -> new ConnectionPool({factory: () -> new FakeConnection(0), acquireTimeout: -1}), ArgumentError);
	}

	public function testNullFromFactoryIsRejected():Void {
		var pool = new ConnectionPool({factory: function():FakeConnection return null, maxSize: 1, acquireTimeout: 0.05});

		Assert.raises(() -> pool.acquire(), IllegalOperationError);
		// The slot is released, not leaked.
		Assert.equals(0, pool.size());
	}
}
