package crossbyte.db;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.SQLError;

/**
 * A row of the bookkeeping table: what was applied, and the fingerprint it had
 * at the time.
 */
typedef AppliedMigration = {
	var version:Int;
	var name:String;
	var checksum:Null<String>;
}

/**
 * The driver-specific seams `SchemaMigrator` needs.
 *
 * Callbacks rather than an interface, for the same reason `ConnectionPool` and
 * `AsyncDatabase.transaction` take them: the drivers in this package share no
 * base type, and requiring one would exclude every driver written outside it.
 */
typedef SchemaMigratorOptions<T> = {
	/**
	 * Runs one statement that returns no rows.
	 */
	var execute:T->String->Void;

	/**
	 * Reads every row of the bookkeeping table. Order does not matter.
	 */
	var readApplied:T->Array<AppliedMigration>;

	/**
	 * Records one migration as applied. Written by the caller rather than
	 * generated here so that the values go through the driver's own parameter
	 * binding — building this INSERT from strings would put a migration name
	 * into SQL text.
	 */
	var recordApplied:T->AppliedMigration->Void;

	/**
	 * Creates the bookkeeping table if it is absent. Defaults to executing
	 * `SchemaMigrator.defaultTableSql(tableName)`, which is accepted by SQLite,
	 * PostgreSQL and MySQL.
	 */
	@:optional var ensureTable:T->Void;

	/**
	 * Bookkeeping table name. Defaults to `schema_migrations`. Must be a plain
	 * identifier, since it is interpolated into the default DDL.
	 */
	@:optional var tableName:String;

	/**
	 * Wraps each migration, so a failure leaves the schema as it was rather
	 * than half-changed. Strongly advised where the engine supports
	 * transactional DDL — SQLite and PostgreSQL do, MySQL does not, and on
	 * MySQL a failed migration has to be repaired by hand whatever is passed
	 * here.
	 *
	 * All three are needed together; supplying some but not all is rejected.
	 */
	@:optional var begin:T->Void;

	@:optional var commit:T->Void;

	@:optional var rollback:T->Void;

	/**
	 * Allows a pending migration numbered below one already applied. Defaults
	 * to `false`, which is what catches the merge that lands version 7 in a
	 * database already holding 8: applying it now produces a schema no other
	 * database will ever have, because the ones that ran 8 first will never go
	 * back for it.
	 */
	@:optional var allowOutOfOrder:Bool;
}

/**
 * What a `migrate()` call did.
 */
typedef MigrationReport = {
	/**
	 * Versions applied by this call, in the order applied. Empty when the
	 * schema was already current.
	 */
	var applied:Array<Int>;

	/**
	 * Registered migrations that were already recorded and so were left alone.
	 */
	var alreadyApplied:Int;
}

/**
 * Applies schema migrations in version order, exactly once each, and records
 * what it did so the next run knows where it left off.
 *
 * Driver-agnostic: it never builds SQL for your data and never parses your
 * statements. It needs three things it cannot do itself — run a statement, read
 * the bookkeeping table, write a row to it — and everything else is ordering,
 * bookkeeping and refusing to do the unsafe thing.
 *
 * ```haxe
 * var migrator = new SchemaMigrator<MyConnection>({
 * 	execute: (c, sql) -> c.execute(sql),
 * 	readApplied: readAppliedRows,
 * 	recordApplied: insertAppliedRow,
 * 	begin: c -> c.execute("BEGIN"),
 * 	commit: c -> c.execute("COMMIT"),
 * 	rollback: c -> c.execute("ROLLBACK")
 * });
 *
 * migrator.addAll([
 * 	Migration.ofSql(1, "create accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY)"),
 * 	Migration.ofSql(2, "create devices", "CREATE TABLE devices (id INTEGER PRIMARY KEY)")
 * ]);
 *
 * var report = migrator.migrate(connection);
 * ```
 *
 * Running it twice is a no-op; running it against a database that is ahead of
 * the registered set is also a no-op, since only forward steps exist. There is
 * deliberately no `down`: a rollback that has to be written before the failure
 * it undoes is understood is guesswork, and one that drops a column destroys
 * the data the incident needed.
 *
 * @author Christopher Speciale
 */
class SchemaMigrator<T> {
	/**
	 * Bookkeeping table used when `tableName` is not supplied.
	 */
	public static inline var DEFAULT_TABLE_NAME:String = "schema_migrations";

	/**
	 * The table this migrator records against.
	 */
	public var tableName(default, null):String;

	@:noCompletion private var __options:SchemaMigratorOptions<T>;
	@:noCompletion private var __migrations:Array<Migration<T>> = [];
	@:noCompletion private var __versions:Map<Int, Bool> = new Map();
	@:noCompletion private var __transactional:Bool;

	public function new(options:SchemaMigratorOptions<T>) {
		if (options == null || options.execute == null || options.readApplied == null || options.recordApplied == null) {
			throw new ArgumentError("SchemaMigrator requires execute, readApplied and recordApplied.");
		}

		var supplied:Int = (options.begin != null ? 1 : 0) + (options.commit != null ? 1 : 0) + (options.rollback != null ? 1 : 0);

		if (supplied != 0 && supplied != 3) {
			// A half-supplied transaction is worse than none: it would open one
			// and then have no way to close or undo it.
			throw new ArgumentError("SchemaMigrator needs begin, commit and rollback together, or none of them.");
		}

		__options = options;
		__transactional = supplied == 3;
		tableName = options.tableName == null ? DEFAULT_TABLE_NAME : options.tableName;

		if (!~/^[A-Za-z_][A-Za-z0-9_]*$/.match(tableName)) {
			// It is interpolated into DDL, and a table name is exactly the kind
			// of value that arrives from configuration.
			throw new ArgumentError('Invalid bookkeeping table name "$tableName": expected a plain identifier.');
		}
	}

	/**
	 * The default bookkeeping table, accepted by SQLite, PostgreSQL and MySQL.
	 * `applied_at` is nullable so that a `recordApplied` which does not set it
	 * still works.
	 */
	public static function defaultTableSql(tableName:String):String {
		return 'CREATE TABLE IF NOT EXISTS $tableName ('
			+ 'version INTEGER NOT NULL PRIMARY KEY, '
			+ 'name TEXT NOT NULL, '
			+ 'checksum TEXT, '
			+ 'applied_at TEXT)';
	}

	/**
	 * Registers a migration. Order of registration does not matter; version
	 * order does. Returns `this` so calls chain.
	 */
	public function add(migration:Migration<T>):SchemaMigrator<T> {
		if (migration == null) {
			throw new ArgumentError("SchemaMigrator.add requires a migration.");
		}

		if (__versions.exists(migration.version)) {
			// Two migrations sharing a version means one of them would never
			// run, and which one would depend on registration order.
			throw new ArgumentError('Duplicate migration version ${migration.version}.');
		}

		__versions.set(migration.version, true);
		__migrations.push(migration);
		__migrations.sort((a, b) -> a.version - b.version);
		return this;
	}

	/**
	 * Registers several migrations. Returns `this` so calls chain.
	 */
	public function addAll(migrations:Array<Migration<T>>):SchemaMigrator<T> {
		if (migrations == null) {
			throw new ArgumentError("SchemaMigrator.addAll requires an array.");
		}

		for (migration in migrations) {
			add(migration);
		}

		return this;
	}

	/**
	 * Every registered migration, in version order.
	 */
	public function migrations():Array<Migration<T>> {
		return __migrations.copy();
	}

	/**
	 * Migrations not yet recorded against this connection, in version order.
	 * Creates the bookkeeping table if absent, and validates checksums, so a
	 * drifted migration is reported here as well as by `migrate()`.
	 */
	public function pending(connection:T):Array<Migration<T>> {
		__ensureTable(connection);
		return __pendingFrom(__readApplied(connection));
	}

	/**
	 * Applies every pending migration in version order, each one recorded
	 * before the next begins.
	 *
	 * Throws without applying anything when a registered migration's checksum
	 * disagrees with what was recorded, or when a pending migration is numbered
	 * below one already applied and `allowOutOfOrder` is not set. A migration
	 * that throws is rolled back where a transaction was supplied, is not
	 * recorded, and stops the run: later migrations are not attempted, because
	 * they were written against a schema that now does not exist.
	 */
	public function migrate(connection:T):MigrationReport {
		__ensureTable(connection);

		var applied:Map<Int, AppliedMigration> = __readApplied(connection);
		var pending:Array<Migration<T>> = __pendingFrom(applied);
		var report:MigrationReport = {
			applied: [],
			alreadyApplied: __migrations.length - pending.length
		};

		for (migration in pending) {
			__applyOne(connection, migration);
			report.applied.push(migration.version);
		}

		return report;
	}

	@:noCompletion private function __applyOne(connection:T, migration:Migration<T>):Void {
		if (__transactional) {
			__options.begin(connection);
		}

		try {
			migration.apply(connection, __options.execute);
			__options.recordApplied(connection, {
				version: migration.version,
				name: migration.name,
				checksum: migration.checksum
			});
		} catch (e:Dynamic) {
			if (__transactional) {
				// Swallowed deliberately: the original failure is what the
				// caller needs, and a rollback that also fails would otherwise
				// replace it with a less useful one.
				try {
					__options.rollback(connection);
				} catch (_:Dynamic) {}
			}

			throw new SQLError("migrate", Std.string(e), 'Migration ${migration.version} ("${migration.name}") failed: ${Std.string(e)}');
		}

		if (__transactional) {
			__options.commit(connection);
		}
	}

	@:noCompletion private function __ensureTable(connection:T):Void {
		if (__options.ensureTable != null) {
			__options.ensureTable(connection);
			return;
		}

		__options.execute(connection, defaultTableSql(tableName));
	}

	@:noCompletion private function __readApplied(connection:T):Map<Int, AppliedMigration> {
		var rows:Array<AppliedMigration> = __options.readApplied(connection);
		var applied:Map<Int, AppliedMigration> = new Map();

		if (rows == null) {
			return applied;
		}

		for (row in rows) {
			if (row != null) {
				applied.set(row.version, row);
			}
		}

		return applied;
	}

	@:noCompletion private function __pendingFrom(applied:Map<Int, AppliedMigration>):Array<Migration<T>> {
		var highestApplied:Int = 0;

		for (version in applied.keys()) {
			if (version > highestApplied) {
				highestApplied = version;
			}
		}

		var pending:Array<Migration<T>> = [];

		for (migration in __migrations) {
			var record:AppliedMigration = applied.get(migration.version);

			if (record == null) {
				pending.push(migration);
				continue;
			}

			// Both sides have to have a fingerprint for the comparison to mean
			// anything; a function-bodied migration without one is exempt.
			if (migration.checksum != null && record.checksum != null && migration.checksum != record.checksum) {
				throw new SQLError("migrate", 'recorded=${record.checksum} current=${migration.checksum}',
					'Migration ${migration.version} ("${migration.name}") has changed since it was applied. '
					+ 'Editing an applied migration does not re-run it, so this database and any that ran the original are now different. '
					+ 'Add a new migration instead.');
			}
		}

		if (!__allowOutOfOrder()) {
			for (migration in pending) {
				if (migration.version < highestApplied) {
					throw new SQLError("migrate", 'version=${migration.version} highestApplied=$highestApplied',
						'Migration ${migration.version} ("${migration.name}") is numbered below the applied version $highestApplied. '
						+ 'Applying it now produces a schema no database that migrated in order will ever have. '
						+ 'Renumber it above $highestApplied, or set allowOutOfOrder.');
				}
			}
		}

		return pending;
	}

	@:noCompletion private inline function __allowOutOfOrder():Bool {
		return __options.allowOutOfOrder == true;
	}
}
