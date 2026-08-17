# Proposal 0015 — Schema migrations

**Status:** Implemented on branch `server-hardening`

**Motivation:** CrossByte supplies every piece of a service skeleton except
one. `Config`, `Logger`, `Metrics`, `ProcessLifecycle` with service control,
`ConnectionPool` and `AsyncDatabase` all exist. Schema versioning does not,
so the first thing any service using the database layer has to write is the
part that decides whether its tables exist yet — the piece where getting it
subtly wrong produces two deployments with the same version number and
different schemas.

---

## What landed

All additions. Nothing existing changed.

### `Migration<T>`

One forward step, identified by a version that never changes once applied.

- `Migration.ofSql(version, name, sql)` — a single statement.
- `Migration.ofStatements(version, name, statements)` — several, in order.
- `Migration.of(version, name, up, ?checksum)` — an arbitrary function, for
  what a statement cannot express: a backfill that reads rows before writing
  them.

Statements are supplied individually rather than as one string full of
semicolons. Splitting SQL on `;` breaks on the first string literal, trigger
body or quoted identifier that contains one, and most drivers reject multiple
statements per call anyway. Refusing to parse SQL is the whole reason this
stays driver-agnostic.

The statement forms are fingerprinted with SHA-256 automatically. The function
form takes an optional checksum, because there is nothing to hash.

### `SchemaMigrator<T>`

Applies pending migrations in version order, one transaction each, recording
every one before the next begins.

The driver-specific work is three callbacks, not an interface — the same
choice `ConnectionPool` and `AsyncDatabase.transaction` make, and for the same
reason: the drivers in this package share no base type, and demanding one
would exclude every driver written outside it.

```haxe
var migrator = new SchemaMigrator<MyConnection>({
	execute: (c, sql) -> c.execute(sql),
	readApplied: readAppliedRows,
	recordApplied: insertAppliedRow,
	begin: c -> c.execute("BEGIN"),
	commit: c -> c.execute("COMMIT"),
	rollback: c -> c.execute("ROLLBACK")
});

migrator.addAll([
	Migration.ofSql(1, "create accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY)"),
	Migration.ofSql(2, "create devices", "CREATE TABLE devices (id INTEGER PRIMARY KEY)")
]);

var report = migrator.migrate(connection);
```

`recordApplied` is the caller's because generating that `INSERT` here would
mean putting a migration name into SQL text. Handing it to the driver's own
parameter binding is the only version of this that is not a small injection
hole waiting for a migration named with an apostrophe.

`defaultTableSql(tableName)` supplies a bookkeeping table accepted by SQLite,
PostgreSQL and MySQL, used automatically unless `ensureTable` is supplied.
`applied_at` is nullable so a `recordApplied` that does not set it still works.

## What it refuses to do

The interesting behaviour is the refusals, since each one is a way a schema
quietly diverges:

- **An edited migration that was already applied.** The edit will never re-run,
  so this database keeps the old schema and so does every other one that ran
  the original — while the file says otherwise. Reported by comparing the
  recorded checksum, with a message that says to add a new migration.
  Renaming is fine: the name is documentation, the version is identity.
- **A pending migration numbered below one already applied.** The shape a merge
  produces — version 7 arriving in a database already holding 8. Applying it
  yields a schema no in-order database will ever have, because the ones that
  ran 8 first will never go back for 7. Refused unless `allowOutOfOrder` is
  set.
- **Two migrations sharing a version.** One of them would never run, and which
  one would depend on registration order.
- **A half-supplied transaction.** `begin` without `rollback` would open one
  with no way to undo it, which is worse than not opening one at all.
- **A bookkeeping table name that is not a plain identifier**, since it is
  interpolated into the default DDL and table names arrive from configuration.

A migration that throws is rolled back, is not recorded, and stops the run.
Later migrations are not attempted: they were written against the schema the
failed one was meant to produce.

There is deliberately no `down`. A rollback has to be written before the
failure it undoes is understood, which makes it guesswork, and one that drops
a column destroys the data the incident needed.

## Testing

Sixteen cases in `SchemaMigratorTest`, driven against an in-memory fake
connection so every target runs them and the assertions are about the
migrator's decisions rather than SQL dialects: version ordering independent of
registration order, idempotent re-runs, drift detection, rename tolerance,
rollback and run-abort on failure, failure without a transaction, out-of-order
refusal and opt-in, `pending()` not applying anything, function-bodied
migrations, checksum sensitivity, lock scope and release, and each rejection
above.

Verified the tests can fail, which for a component whose value is its refusals
is the part that matters. Disabling the drift check, the out-of-order check
and the rollback produced five failures across exactly those three cases and
left the other nine passing. Removing the lock release on failure produced
three more, across exactly the two cases that assert it — including the
refusal path, which leaves `migrate()` before any migration runs and is just
as capable of stranding the lock as a failing statement is.

The checksum case includes the two mutations a naive join would miss:
`["A", "B"]` must not hash equal to `["AB"]`, and reordering statements must
change the hash. That is why the join separator is one the split cannot
contain.

## Seams left open

- **No file loader.** Migrations are registered in code. Reading a directory of
  `.sql` files is a small helper, but it commits to a naming convention and a
  location, and the runner is more useful without an opinion on either.
- **No MySQL transactional guarantee, and it cannot be given one.** MySQL DDL
  is not transactional: a failed migration there has to be repaired by hand
  whatever is passed for `begin`/`commit`/`rollback`. Documented on the option
  rather than left to be discovered during an incident.
- **The advisory lock is a seam, not a default.** `lock`/`unlock` are held
  across the whole of `migrate()` so two processes cannot both read an empty
  bookkeeping table and both apply migration 1 — the shape a rolling deploy
  produces, where several instances start within a second of each other. It
  cannot have a default because the primitive is engine-specific:
  PostgreSQL has `pg_advisory_lock(key)`, MySQL `GET_LOCK(name, timeout)`, and
  SQLite has no equivalent and needs none, since a single file is not shared
  between hosts. The lock is released on every path out, including a refusal
  that happens before any migration runs — one left held would stop every other
  instance from ever migrating, turning one bad deploy into a fleet that cannot
  start.
