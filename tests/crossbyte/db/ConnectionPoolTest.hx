package crossbyte.db;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import utest.Assert;

/**
 * Stand-in for a driver connection, so pool behavior is tested without a
 * database server.
 */
private class FakeConnection {
	public var id(default, null):Int;
	public var closed(default, null):Bool = false;
	public var healthy:Bool = true;
	public var inTransaction:Bool = false;

	public function new(id:Int) {
		this.id = id;
	}

	public function close():Void {
		closed = true;
	}
}

/**
 * A connection that reports its transaction, as the drivers do, so the
 * pool's own rollback is tested without a server.
 */
private class FakeTransactionalConnection implements ITransactionalConnection {
	public var id(default, null):Int;
	public var closed(default, null):Bool = false;
	public var inTransaction(get, null):Bool;
	public var rollbacks:Int = 0;
	public var failRollback:Bool = false;

	@:noCompletion private var __open:Bool = false;

	public function new(id:Int) {
		this.id = id;
	}

	public function begin():Void {
		__open = true;
	}

	public function commit():Void {
		__open = false;
	}

	public function rollback():Void {
		rollbacks++;

		if (failRollback) {
			throw "the server went away";
		}

		__open = false;
	}

	public function close():Void {
		closed = true;
	}

	private function get_inTransaction():Bool {
		return __open;
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

	private function __poolWithReset(reset:FakeConnection->Void):ConnectionPool<FakeConnection> {
		return new ConnectionPool({
			factory: function() {
				var connection = new FakeConnection(nextId++);
				created.push(connection);
				return connection;
			},
			close: connection -> connection.close(),
			reset: reset,
			maxSize: 1,
			acquireTimeout: 0.05
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

	public function testResetRunsOnEveryReleaseIncludingWhenTheBodyThrows():Void {
		// A body that opened a transaction and then threw handed the next
		// borrower that transaction: its writes joined it, and the locks it
		// held stayed held. validate() cannot see it -- an open transaction
		// answers a ping like any other -- so the release has to fix it.
		var resets:Int = 0;
		var pool = __poolWithReset(c -> {
			resets++;
			c.inTransaction = false;
		});

		try {
			pool.withConnection(function(c:FakeConnection):Void {
				c.inTransaction = true;
				throw "a bug after BEGIN";
			});
		} catch (_:Dynamic) {}

		Assert.equals(1, resets);
		Assert.isFalse(pool.withConnection(c -> c.inTransaction), "the next borrower was handed an open transaction");
		Assert.equals(2, resets);

		// A plain release runs it too.
		pool.release(pool.acquire());
		Assert.equals(3, resets);
		Assert.equals(1, pool.size());
	}

	public function testAResetThatThrowsRetiresTheConnection():Void {
		var pool = __poolWithReset(c -> throw "cannot roll back");
		var first = pool.acquire();

		pool.release(first);

		Assert.isTrue(first.closed);
		Assert.equals(0, pool.size());
		Assert.equals(0, pool.available());
		Assert.equals(0, pool.inUse());

		// Its slot is free again.
		var second = pool.acquire();
		Assert.notEquals(first.id, second.id);
		pool.release(second);
	}

	public function testReleasingIntoAClosedPoolSkipsTheReset():Void {
		var resets:Int = 0;
		var pool = __poolWithReset(c -> resets++);
		var connection = pool.acquire();

		pool.close();
		pool.release(connection);

		Assert.equals(0, resets);
		Assert.isTrue(connection.closed);
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

	public function testDoubleDiscardDoesNotBreachTheCeiling():Void {
		// release() guards against being called twice; discard() did not, and
		// decremented __created unconditionally. Two discards of one connection
		// therefore credited the pool with a slot it never gave up, and the
		// ceiling -- the pool's single reason to exist -- stopped holding.
		var pool = makePool(1);

		var connection = pool.acquire();
		pool.discard(connection);
		pool.discard(connection);

		Assert.equals(0, pool.size());

		var replacement = pool.acquire();
		Assert.equals(1, pool.size());
		Assert.equals(1, pool.inUse());

		// One connection, one ceiling: the next acquire must wait, not open a
		// second. A pool whose count has drifted below reality opens without
		// limit instead.
		Assert.raises(() -> pool.acquire(), IllegalOperationError);

		pool.release(replacement);
		pool.close();
	}

	public function testForeignDiscardIsIgnored():Void {
		// The same asymmetry from the other direction: a connection this pool
		// never issued must not alter its accounting.
		var pool = makePool(1);
		var foreign = new FakeConnection(9999);

		var held = pool.acquire();
		pool.discard(foreign);

		Assert.equals(1, pool.size());
		Assert.equals(1, pool.inUse());
		Assert.isFalse(foreign.closed);

		pool.release(held);
		pool.close();
	}

	public function testDiscardingAnIdleConnectionRemovesItFromThePool():Void {
		// Discarding something already released closed it but left it sitting
		// in the idle list, so the next acquire handed out a closed connection.
		var pool = makePool(2);

		var connection = pool.acquire();
		pool.release(connection);
		pool.discard(connection);

		var next = pool.acquire();
		Assert.isFalse(next.closed);

		pool.release(next);
		pool.close();
	}

	public function testConnectionStaysCountedWhileItIsValidated():Void {
		// Validation runs unlocked, because it may talk to the server. The
		// connection was discounted from __created for that whole window, so a
		// second caller arriving mid-validation saw room that did not exist and
		// opened a connection past the ceiling. It is still open while being
		// checked, so it stays counted; only a failed check retires it.
		var observed:Int = -1;
		var pool:ConnectionPool<FakeConnection> = null;

		pool = makePool(1, function(connection:FakeConnection):Bool {
			observed = pool.size();
			return true;
		});

		var first = pool.acquire();
		pool.release(first);

		var second = pool.acquire();

		Assert.equals(1, observed);
		Assert.equals(1, pool.size());

		pool.release(second);
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

	private function __transactionalPool(?reset:FakeTransactionalConnection->Void):ConnectionPool<FakeTransactionalConnection> {
		return new ConnectionPool({
			factory: () -> new FakeTransactionalConnection(nextId++),
			close: connection -> connection.close(),
			reset: reset,
			maxSize: 1,
			acquireTimeout: 0.05
		});
	}

	public function testAnOpenTransactionIsRolledBackOnReleaseWithNoResetSet():Void {
		// Rolling back took a reset the application had to know to write, and
		// without one the next borrower was handed the transaction: its writes
		// joined it, and the locks it held stayed held.
		var pool = __transactionalPool();
		var warnings:Array<String> = [];
		Logger.recordSink = record -> {
			if (record.category == "db.pool" && record.level == LogLevel.WARN) {
				warnings.push(record.message);
			}
		};

		var first = pool.acquire();
		first.begin();
		pool.release(first);

		Logger.recordSink = null;

		Assert.equals(1, first.rollbacks);
		var next = pool.acquire();
		Assert.equals(first, next, "a connection rolled back cleanly is reused, not retired");
		Assert.isFalse(next.inTransaction, "the next borrower was handed an open transaction");
		pool.release(next);
		Assert.equals(1, next.rollbacks, "a connection with nothing open is not rolled back");

		// Said, since it is a bug in whoever released it, and said once.
		Assert.equals(1, warnings.length);
		pool.close();
	}

	public function testATransactionTheBodyThrewOutOfIsRolledBackQuietly():Void {
		var pool = __transactionalPool();
		var logged:Int = 0;
		Logger.recordSink = record -> if (record.category == "db.pool") logged++;

		var borrowed:FakeTransactionalConnection = null;
		var threw:Bool = false;

		try {
			pool.withConnection(function(c:FakeTransactionalConnection):Void {
				borrowed = c;
				c.begin();
				throw "a bug after BEGIN";
			});
		} catch (_:Dynamic) {
			threw = true;
		}

		Logger.recordSink = null;

		Assert.isTrue(threw, "the body's error was swallowed");
		Assert.equals(1, borrowed.rollbacks);
		Assert.isFalse(pool.withConnection(c -> c.inTransaction));
		// The body's own error is on its way to the caller; a warning as well
		// would report the one failure twice.
		Assert.equals(0, logged);
		pool.close();
	}

	public function testACommittedTransactionIsLeftAlone():Void {
		var pool = __transactionalPool();

		pool.withConnection(function(c:FakeTransactionalConnection):Void {
			c.begin();
			c.commit();
		});

		Assert.equals(0, pool.withConnection(c -> c.rollbacks));
		pool.close();
	}

	public function testARollbackThatFailsRetiresTheConnection():Void {
		var pool = __transactionalPool();
		var first = pool.acquire();
		first.failRollback = true;
		first.begin();

		Logger.recordSink = _ -> {};
		pool.release(first);
		Logger.recordSink = null;

		// Its state is unknown, so nobody else gets it.
		Assert.isTrue(first.closed);
		Assert.equals(0, pool.size());
		Assert.equals(0, pool.inUse());

		var second = pool.acquire();
		Assert.notEquals(first.id, second.id);
		pool.release(second);
		pool.close();
	}

	public function testTheRollbackRunsBeforeTheReset():Void {
		var openWhenReset:Array<Bool> = [];
		var pool = __transactionalPool(c -> openWhenReset.push(c.inTransaction));

		Logger.recordSink = _ -> {};
		pool.withConnection(c -> c.begin());
		Logger.recordSink = null;

		// And the reset still runs: it is for the rest of the session's state.
		Assert.same([false], openWhenReset);
		pool.close();
	}

	public function testNothingIsRolledBackIntoAClosedPool():Void {
		// The connection is closed on the way in, which ends the transaction
		// on the server; a rollback first would be a round trip for nothing.
		var pool = __transactionalPool();
		var connection = pool.acquire();
		connection.begin();

		pool.close();
		pool.release(connection);

		Assert.equals(0, connection.rollbacks);
		Assert.isTrue(connection.closed);
	}

	public function testEveryDriverCanReportItsTransaction():Void {
		// What the pool's rollback depends on; a driver that stopped
		// implementing it would lose the rollback without a compile error
		// anywhere else.
		var drivers:Array<Class<Dynamic>> = [
			crossbyte.db.postgres.PostgresConnection,
			crossbyte.db.mysql.MySQLConnection,
			crossbyte.db.sql.sqlite.SQLiteConnection
		];

		for (driver in drivers) {
			var instance:Dynamic = Type.createEmptyInstance(driver);
			Assert.isTrue(Std.isOfType(instance, ITransactionalConnection), Type.getClassName(driver));
		}
	}
}
