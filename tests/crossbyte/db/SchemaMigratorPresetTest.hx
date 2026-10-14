package crossbyte.db;

#if (cpp || php)
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.errors.SQLError;
import utest.Assert;

/**
	`SchemaMigrator.sqlite()` against a real SQLite database, natively and on
	PHP, where SQLite opens one. The PostgreSQL preset runs against the
	stand-in libpq in `NativePostgresBridgeTest` and a real server in
	`PostgresIntegrationTest`.
**/
class SchemaMigratorPresetTest extends utest.Test {
	private var __connection:AppConnection;

	public function setup():Void {
		__connection = new AppConnection();
		__connection.open(null, SQLiteMode.CREATE, false, 4096);
	}

	public function teardown():Void {
		if (__connection != null && __connection.connected) {
			__connection.close();
		}
		__connection = null;
	}

	public function testTheSqlitePresetAppliesAndRecordsEachMigrationOnce():Void {
		var migrator:SchemaMigrator<AppConnection> = SchemaMigrator.sqlite();
		migrator.addAll([
			Migration.ofSql(1, "accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT)"),
			Migration.ofStatements(2, "devices's table", ["CREATE TABLE devices (id INTEGER PRIMARY KEY)", "CREATE INDEX idx_devices ON devices(id)"]),
			Migration.of(3, "seed", (c:AppConnection) -> c.request("INSERT INTO accounts (name) VALUES ('first')"))
		]);

		var report = migrator.migrate(__connection);
		Assert.same([1, 2, 3], report.applied);
		Assert.equals(0, report.alreadyApplied);
		Assert.isFalse(__connection.inTransaction);

		var rows = __rows("SELECT version, name, checksum, applied_at FROM schema_migrations ORDER BY version");
		Assert.equals(3, rows.length);
		Assert.equals("devices's table", rows[1].name);
		Assert.equals(migrator.migrations()[0].checksum, rows[0].checksum);
		Assert.isNull(rows[2].checksum);
		// SQLite's UTC time, as ISO-8601 to the millisecond.
		Assert.isTrue(~/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.match(Std.string(rows[0].applied_at)), Std.string(rows[0].applied_at));

		// A second run, as the next start of the service makes, does nothing.
		var again:SchemaMigrator<AppConnection> = SchemaMigrator.sqlite();
		again.addAll(migrator.migrations());
		var second = again.migrate(__connection);
		Assert.same([], second.applied);
		Assert.equals(3, second.alreadyApplied);
		Assert.equals(1, __rows("SELECT name FROM accounts").length);
	}

	public function testAFailedMigrationIsRolledBackAndNotRecorded():Void {
		var migrator:SchemaMigrator<AppConnection> = SchemaMigrator.sqlite();
		migrator.add(Migration.ofSql(1, "accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY)"));
		migrator.add(Migration.ofStatements(2, "half", ["CREATE TABLE half (id INTEGER)", "INSERT INTO nowhere VALUES (1)"]));

		Assert.raises(() -> migrator.migrate(__connection), SQLError);
		Assert.isFalse(__connection.inTransaction);
		Assert.same([1], [for (row in __rows("SELECT version FROM schema_migrations")) Std.int(row.version)]);
		// The table the failed migration made went with it.
		Assert.equals(0, __rows("SELECT name FROM sqlite_master WHERE name = 'half'").length);
	}

	public function testAnEditedMigrationIsCaughtFromWhatWasRecorded():Void {
		var first:SchemaMigrator<AppConnection> = SchemaMigrator.sqlite("app_migrations");
		first.add(Migration.ofSql(1, "accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY)"));
		first.migrate(__connection);
		Assert.equals(1, __rows("SELECT version FROM app_migrations").length);

		var edited:SchemaMigrator<AppConnection> = SchemaMigrator.sqlite("app_migrations");
		edited.add(Migration.ofSql(1, "accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT)"));
		Assert.raises(() -> edited.migrate(__connection), SQLError);
	}

	public function testOutOfOrderFollowsTheSetting():Void {
		var first:SchemaMigrator<SQLiteConnection> = SchemaMigrator.sqlite();
		first.add(Migration.ofSql(2, "two", "CREATE TABLE two (id INTEGER)"));
		first.migrate(__connection);

		var refusing:SchemaMigrator<SQLiteConnection> = SchemaMigrator.sqlite();
		refusing.addAll([Migration.ofSql(1, "one", "CREATE TABLE one (id INTEGER)"), Migration.ofSql(2, "two", "CREATE TABLE two (id INTEGER)")]);
		Assert.raises(() -> refusing.migrate(__connection), SQLError);

		var allowing:SchemaMigrator<SQLiteConnection> = SchemaMigrator.sqlite(null, true);
		allowing.addAll(refusing.migrations());
		Assert.same([1], allowing.migrate(__connection).applied);
	}

	private function __rows(sql:String):Array<Dynamic> {
		return [for (row in __connection.request(sql)) row];
	}
}

/** A service's own connection class, as Bifrost has. **/
private class AppConnection extends SQLiteConnection {
	public function new() {
		super();
	}
}
#end
