package crossbyte.db;

import crossbyte.db.SchemaMigrator.AppliedMigration;
import crossbyte.db.SchemaMigrator.SchemaMigratorOptions;
import utest.Assert;

/**
 * Driven against an in-memory connection rather than a real database, so every
 * target runs it and the assertions are about the migrator's decisions —
 * ordering, idempotency, drift, refusal — rather than about SQL dialects.
 */
class SchemaMigratorTest extends utest.Test {
	public function testAppliesInVersionOrderRegardlessOfRegistrationOrder():Void {
		var connection = new FakeConnection();
		var migrator = __migrator(connection);

		// Registered 3, 1, 2 on purpose: version order is the contract,
		// registration order is not.
		migrator.addAll([
			Migration.ofSql(3, "third", "CREATE TABLE c (id INTEGER)"),
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")
		]);

		var report = migrator.migrate(connection);

		Assert.same([1, 2, 3], report.applied);
		Assert.equals(0, report.alreadyApplied);
		Assert.same([1, 2, 3], __recordedVersions(connection));

		// The bookkeeping table first, then the migrations in order.
		Assert.equals(SchemaMigrator.defaultTableSql("schema_migrations"), connection.executed[0]);
		Assert.equals("CREATE TABLE a (id INTEGER)", connection.executed[1]);
		Assert.equals("CREATE TABLE b (id INTEGER)", connection.executed[2]);
		Assert.equals("CREATE TABLE c (id INTEGER)", connection.executed[3]);
	}

	public function testSecondRunAppliesNothing():Void {
		var connection = new FakeConnection();

		__migrator(connection).addAll(__twoMigrations()).migrate(connection);
		var executedAfterFirst = connection.executed.length;

		// A fresh migrator over the same connection: a restarted process, which
		// is the only way this is ever really run twice.
		var report = __migrator(connection).addAll(__twoMigrations()).migrate(connection);

		Assert.same([], report.applied);
		Assert.equals(2, report.alreadyApplied);
		Assert.same([1, 2], __recordedVersions(connection));
		// Only the CREATE TABLE IF NOT EXISTS, nothing else re-run.
		Assert.equals(executedAfterFirst + 1, connection.executed.length);
	}

	public function testEditingAnAppliedMigrationIsReported():Void {
		var connection = new FakeConnection();
		__migrator(connection).add(Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)")).migrate(connection);

		var edited = __migrator(connection).add(Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER, name TEXT)"));

		// The edit would never re-run, so every database that applied the
		// original stays on it. Silence here is how two deployments end up with
		// different schemas and the same version number.
		Assert.raises(() -> edited.migrate(connection));
		Assert.raises(() -> edited.pending(connection));
	}

	public function testRenamingAnAppliedMigrationIsAllowed():Void {
		var connection = new FakeConnection();
		__migrator(connection).add(Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)")).migrate(connection);

		// Same statements, different label: the name is documentation, not
		// identity, so this must not trip drift detection.
		var renamed = __migrator(connection).add(Migration.ofSql(1, "create table a", "CREATE TABLE a (id INTEGER)"));

		Assert.same([], renamed.migrate(connection).applied);
	}

	public function testFailedMigrationRollsBackAndStopsTheRun():Void {
		var connection = new FakeConnection();
		connection.failOn = "CREATE TABLE b";

		var migrator = __migrator(connection).addAll([
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)"),
			Migration.ofSql(3, "third", "CREATE TABLE c (id INTEGER)")
		]);

		Assert.raises(() -> migrator.migrate(connection));

		// 1 committed, 2 rolled back and not recorded.
		Assert.same([1], __recordedVersions(connection));
		Assert.same(["begin", "commit", "begin", "rollback"], connection.events);

		// 3 is not attempted: it was written against the schema 2 was meant to
		// produce, which does not exist.
		Assert.isFalse(connection.executed.indexOf("CREATE TABLE c (id INTEGER)") >= 0);
	}

	public function testFailureWithoutATransactionStillStopsAndDoesNotRecord():Void {
		var connection = new FakeConnection();
		connection.failOn = "CREATE TABLE a";

		var migrator = __migrator(connection, false).add(Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"));

		Assert.raises(() -> migrator.migrate(connection));
		Assert.same([], __recordedVersions(connection));
		Assert.same([], connection.events);
	}

	public function testOutOfOrderIsRefusedByDefault():Void {
		var connection = new FakeConnection();
		__migrator(connection).add(Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")).migrate(connection);

		// Version 1 arriving after 2 is already applied: the shape a merge
		// produces. Applying it makes a schema no in-order database will have.
		var late = __migrator(connection).addAll([
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")
		]);

		Assert.raises(() -> late.migrate(connection));
		Assert.same([2], __recordedVersions(connection));
	}

	public function testOutOfOrderRunsWhenOptedIn():Void {
		var connection = new FakeConnection();
		__migrator(connection).add(Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")).migrate(connection);

		var late = __migrator(connection, true, true).addAll([
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")
		]);

		Assert.same([1], late.migrate(connection).applied);
		Assert.same([2, 1], __recordedVersions(connection));
	}

	public function testPendingListsUnappliedInVersionOrderWithoutApplyingThem():Void {
		var connection = new FakeConnection();
		var migrator = __migrator(connection).addAll(__twoMigrations());

		var pending = migrator.pending(connection);

		Assert.equals(2, pending.length);
		Assert.equals(1, pending[0].version);
		Assert.equals(2, pending[1].version);
		Assert.same([], __recordedVersions(connection));

		migrator.migrate(connection);
		Assert.equals(0, migrator.pending(connection).length);
	}

	public function testFunctionMigrationRunsAndNeedsNoChecksum():Void {
		var connection = new FakeConnection();
		var ran = 0;

		var migrator = __migrator(connection).add(Migration.of(1, "backfill", function(c:FakeConnection):Void {
			ran++;
			c.execute("BACKFILL");
		}));

		Assert.same([1], migrator.migrate(connection).applied);
		Assert.equals(1, ran);
		Assert.isTrue(connection.executed.indexOf("BACKFILL") >= 0);

		// No checksum on either side, so nothing to compare and nothing to trip.
		Assert.isNull(connection.recorded[0].checksum);
		Assert.same([], __migrator(connection).add(Migration.of(1, "backfill", _ -> ran++)).migrate(connection).applied);
		Assert.equals(1, ran);
	}

	public function testChecksumFollowsStatementContent():Void {
		var a = Migration.ofSql(1, "x", "CREATE TABLE a (id INTEGER)");
		var same = Migration.ofSql(1, "different name", "CREATE TABLE a (id INTEGER)");
		var different = Migration.ofSql(1, "x", "CREATE TABLE a (id TEXT)");

		Assert.equals(a.checksum, same.checksum);
		Assert.notEquals(a.checksum, different.checksum);

		// Moving a fragment across the statement boundary has to change the
		// hash, which is why the join uses a separator the split cannot contain.
		Assert.notEquals(Migration.ofStatements(1, "x", ["A", "B"]).checksum, Migration.ofStatements(1, "x", ["AB"]).checksum);
		Assert.notEquals(Migration.ofStatements(1, "x", ["A", "B"]).checksum, Migration.ofStatements(1, "x", ["B", "A"]).checksum);
	}

	public function testRejectsMalformedConfiguration():Void {
		var connection = new FakeConnection();

		// Duplicate version: one of the two would never run, and which one would
		// depend on registration order.
		Assert.raises(() -> __migrator(connection).addAll([
			Migration.ofSql(1, "a", "SELECT 1"),
			Migration.ofSql(1, "b", "SELECT 2")
		]));

		Assert.raises(() -> Migration.ofSql(0, "zero", "SELECT 1"));
		Assert.raises(() -> Migration.ofSql(1, "empty", "   "));
		Assert.raises(() -> Migration.ofStatements(1, "none", []));
		Assert.raises(() -> Migration.of(1, "null body", null));

		// A table name reaching the default DDL from configuration.
		Assert.raises(() -> new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			tableName: "migrations; DROP TABLE accounts"
		}));

		// A half-supplied transaction would open one with no way to close it.
		Assert.raises(() -> new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			begin: c -> c.events.push("begin")
		}));

		Assert.raises(() -> new SchemaMigrator<FakeConnection>({
			execute: null,
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row)
		}));
	}

	public function testHonoursACustomTableNameAndEnsureHook():Void {
		var connection = new FakeConnection();
		var ensured = 0;

		var migrator = new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			ensureTable: c -> ensured++,
			tableName: "cb_schema_version"
		});

		Assert.equals("cb_schema_version", migrator.tableName);
		Assert.isTrue(SchemaMigrator.defaultTableSql("cb_schema_version").indexOf("cb_schema_version") >= 0);

		migrator.add(Migration.ofSql(1, "first", "SELECT 1")).migrate(connection);

		// The hook replaces the default DDL rather than running alongside it.
		Assert.equals(1, ensured);
		Assert.same(["SELECT 1"], connection.executed);
	}

	public function testLockIsHeldAcrossTheWholeRunAndReleasedAfter():Void {
		var connection = new FakeConnection();
		var migrator = __lockingMigrator(connection).addAll(__twoMigrations());

		migrator.migrate(connection);

		// Taken before the bookkeeping table is even read, and released only
		// once every migration is recorded. Anything narrower lets two
		// processes both read an empty table and both apply migration 1.
		Assert.equals("lock", connection.events[0]);
		Assert.equals("unlock", connection.events[connection.events.length - 1]);
		Assert.equals(1, __countEvents(connection, "lock"));
		Assert.equals(1, __countEvents(connection, "unlock"));
		Assert.same([1, 2], __recordedVersions(connection));
	}

	public function testLockIsReleasedWhenAMigrationFails():Void {
		var connection = new FakeConnection();
		connection.failOn = "CREATE TABLE b";

		var migrator = __lockingMigrator(connection).addAll(__twoMigrations());

		Assert.raises(() -> migrator.migrate(connection));

		// The failure must not leave the lock held: every other instance would
		// then block for good, turning one bad deploy into a fleet that cannot
		// start.
		Assert.equals(1, __countEvents(connection, "unlock"));
		Assert.equals("unlock", connection.events[connection.events.length - 1]);
	}

	public function testLockIsReleasedWhenTheRunIsRefused():Void {
		var connection = new FakeConnection();
		__lockingMigrator(connection).add(Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")).migrate(connection);

		// A refusal happens before any migration runs, which is a different
		// path out of migrate() and just as capable of stranding the lock.
		var late = __lockingMigrator(connection).addAll([
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")
		]);

		Assert.raises(() -> late.migrate(connection));
		Assert.equals(__countEvents(connection, "lock"), __countEvents(connection, "unlock"));
	}

	public function testLockAndUnlockAreRequiredTogether():Void {
		Assert.raises(() -> new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			lock: c -> c.events.push("lock")
		}));

		Assert.raises(() -> new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			unlock: c -> c.events.push("unlock")
		}));
	}

	private function __lockingMigrator(connection:FakeConnection):SchemaMigrator<FakeConnection> {
		return new SchemaMigrator<FakeConnection>({
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			begin: c -> c.events.push("begin"),
			commit: c -> c.events.push("commit"),
			rollback: c -> c.events.push("rollback"),
			lock: c -> c.events.push("lock"),
			unlock: c -> c.events.push("unlock")
		});
	}

	private function __countEvents(connection:FakeConnection, event:String):Int {
		var count = 0;
		for (entry in connection.events) {
			if (entry == event) {
				count++;
			}
		}
		return count;
	}

	private function __migrator(connection:FakeConnection, transactional:Bool = true, allowOutOfOrder:Bool = false):SchemaMigrator<FakeConnection> {
		var options:SchemaMigratorOptions<FakeConnection> = {
			execute: (c, sql) -> c.execute(sql),
			readApplied: c -> c.recorded.copy(),
			recordApplied: (c, row) -> c.recorded.push(row),
			allowOutOfOrder: allowOutOfOrder
		};

		if (transactional) {
			options.begin = c -> c.events.push("begin");
			options.commit = c -> c.events.push("commit");
			options.rollback = c -> c.events.push("rollback");
		}

		return new SchemaMigrator<FakeConnection>(options);
	}

	private function __twoMigrations():Array<Migration<FakeConnection>> {
		return [
			Migration.ofSql(1, "first", "CREATE TABLE a (id INTEGER)"),
			Migration.ofSql(2, "second", "CREATE TABLE b (id INTEGER)")
		];
	}

	private function __recordedVersions(connection:FakeConnection):Array<Int> {
		return [for (row in connection.recorded) row.version];
	}
}

/**
 * The smallest thing that can stand in for a driver: it remembers what it was
 * asked to run, what was recorded, and can be told to fail on one statement.
 */
private class FakeConnection {
	public var executed:Array<String> = [];
	public var recorded:Array<AppliedMigration> = [];
	public var events:Array<String> = [];
	public var failOn:String = null;

	public function new() {}

	public function execute(sql:String):Void {
		if (failOn != null && sql.indexOf(failOn) >= 0) {
			throw 'fake driver failure on: $sql';
		}

		executed.push(sql);
	}
}
