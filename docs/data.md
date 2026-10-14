# Databases

CrossByte's database clients are blocking drivers with one shape: every SQL driver's statements take `parameters` as
`SQLValue`s, and read a result row by row and column by column with `executeEach` and `SQLRow`. None is built for
JavaScript.

| Database | Where | How |
| --- | --- | --- |
| SQLite | natively; php | natively with statements prepared once and their parameters bound; on php through PHP's `sqlite3` extension |
| MySQL, MariaDB | natively; the jvm | natively through hxcpp's bundled client; on the jvm through Connector/J on the class path, without the TLS or limit settings |
| PostgreSQL | natively; php | natively through libpq, loaded at run time, with bound parameters, statement and connect timeouts and `cancel()`; on php through PDO |
| MongoDB | hxcpp, the jvm, the interpreter, hl, neko | its wire protocol: OP_MSG, SCRAM, TLS, cursors, transactions |

## SQLite

Natively, SQLite is compiled in: each statement is prepared once and kept, its parameters are bound, rows can be
read by column with `executeEach`, `openAsync()` runs the connection on a worker, and `cancel()` interrupts a
statement that is running.

On PHP, `SQLiteConnection` uses PHP's `sqlite3` extension, which has to be enabled in `php.ini`. Connections open
with `open()`, and a statement's parameters are written into its text as quoted literals. `openAsync()`,
`executeEach` and interrupting a running statement are native only. PHP's `sqlite3` runs a statement again to read
its rows, so there a write with `RETURNING` is made twice: read what a write changed with a `SELECT` after it, in
the same transaction.

## MySQL and MariaDB

Natively, the client logs in with `caching_sha2_password` or `mysql_native_password`, uses TLS when the server offers
it (`MySQLConfig.sslMode`), bounds its waits and can `cancel()` a statement.

It takes the server's answers as untrusted, since whoever answers in the server's place writes them, and refuses one
no server sends (a column count or a length that would otherwise have it allocate gigabytes or write out of bounds)
with error 2027. `MySQLConnection` lists what it bounds.

`sslMode` stays `PREFERRED`, as in MySQL's own clients, which encrypts without checking whose certificate it is.
Across a network you do not trust, use `VERIFY_IDENTITY` with `sslCa`; `MySQLConfig.sslMode` says why insisting on
TLS alone would not keep out a man in the middle.

## Keeping blocking drivers off the runtime

`ConnectionPool` and `AsyncDatabase` keep the blocking drivers off the runtime's thread, and bound the wait.
`AsyncDatabase` fails a job still queued after `queueTimeout` (30 s), at the deadline even though every worker is
busy, and refuses one past `maxQueued` (100,000). For both of these, and for the pool's `acquireTimeout` (10 s), 0 is
no limit.

## Migrations

`SchemaMigrator` applies numbered migrations once each, in order, and records them. It takes the few things that
differ by driver as functions, and `SchemaMigrator.sqlite()` and `SchemaMigrator.postgres()` supply them for SQLite
and PostgreSQL: each migration in a transaction, the record written with its values bound, and for PostgreSQL an
advisory lock held across the run, so instances starting together migrate one at a time.

```haxe
import crossbyte.db.Migration;
import crossbyte.db.SchemaMigrator;
import crossbyte.db.sql.sqlite.SQLiteConnection;

// Given connection:SQLiteConnection.
var migrator:SchemaMigrator<SQLiteConnection> = SchemaMigrator.sqlite();
migrator.add(Migration.ofSql(1, "create accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT)"));
migrator.migrate(connection);
```

Settings read from a configuration file go through `fromString` on the modes (`JournalMode`, `SynchronousMode`,
`TempStoreMode`, `PostgresSSLMode` and `MySQLSSLMode`), which refuse a value they do not know with an `ArgumentError`.

## A key/value store

`crossbyte.db.kv` keeps records by string key, each with a revision, in the shape etcd and Consul keep theirs: for
what a server holds of its users, sessions, groups, chat and leaderboards when a key, or a range of keys, is all it
asks by. `KVStore` is the interface. `MemoryKVStore` keeps the records in memory, on every target, and any thread may
use it.

```haxe
import crossbyte.db.kv.MemoryKVStore;
import haxe.io.Bytes;

var store = new MemoryKVStore();
var created = store.put("users/alice", Bytes.ofString("{\"level\":1}"));
trace(created.revision); // 1, then one more with each write
```

Each record carries its value's bytes, its `revision`, and `createdAt` and `updatedAt` in seconds since the epoch.

### Compare-and-set

A read, a change and a write back lose a write made in between. `compareAndSet` writes only if the record is still
at the revision that was read, in one step no other write can come between, and answers null when it is not, as
etcd's transactions and Consul's `?cas=` do. Revision 0 means only if there is no record.

```haxe
// Given store:crossbyte.db.kv.KVStore.
import haxe.io.Bytes;

function addPoints(player:String, points:Int):Void {
	var key = "scores/" + player;
	while (true) {
		var record = store.get(key);
		var score:Int = record == null ? 0 : Std.parseInt(record.value.toString());
		var expected:Float = record == null ? 0 : record.revision;
		if (store.compareAndSet(key, Bytes.ofString(Std.string(score + points)), expected) != null) {
			return;
		}
		// Someone else wrote it first: read it again.
	}
}
```

A delete leaves a tombstone at the next revision, and a write after it goes on from there, so a revision read
before the delete cannot be taken for the value written after it. `purgeTombstones(before)` removes the old ones,
as etcd's compaction does, once nothing still holds a revision from before them.

### Scans

`scan` reads records in key order a page at a time: those under a `prefix`, from `startAt`, after `startAfter` and
before `endBefore`, up to `limit` (100 unless given). Keys sort by code point, the order of their UTF-8 bytes, the
same on every target and in every backend. A page's `next` is the key to start after for the next one:

```haxe
// Given store:crossbyte.db.kv.KVStore.
var page = store.scan({prefix: "scores/", limit: 50});
while (true) {
	for (record in page.items) {
		trace(record.key);
	}
	if (page.next == null) {
		break;
	}
	page = store.scan({prefix: "scores/", limit: 50, startAfter: page.next});
}
```

Tombstones are left out unless the scan sets `includeTombstones`, for a reader keeping a copy that needs to hear of a
delete.

### In SQLite

`SQLiteKVStore` keeps the records in an SQLite table, natively and on PHP:

```haxe
import crossbyte.db.kv.SQLiteKVStore;
import haxe.io.Bytes;

var store = SQLiteKVStore.open("data/game.db");
store.put("users/alice", Bytes.ofString("{}"));
store.close();
```

`open` puts a file in WAL mode, so readers do not wait for a writer. The store makes its table (`kv` unless
`KVOptions.table` names another) through `SchemaMigrator.sqlite()`, recorded in `kv_migrations`, and
`SQLiteKVStore.migrations()` gives the migration for a migrator of your own. `new SQLiteKVStore(connection)` puts a
store on a connection already open, whose own statements can then share the store's transactions.

Each write is one statement, an upsert with the revision check in its `WHERE`, so no other connection can come
between the check and the write. A page of a scan is one statement too, which reads only the values it returns. A
store is used by one thread at a time, as its connection is: several threads share a database through a
`ConnectionPool` of stores, each its own connection to the file.

### In PostgreSQL

`PostgresKVStore` keeps them in PostgreSQL, natively, for records several servers share:

```haxe
import crossbyte.db.kv.PostgresKVStore;

var store = PostgresKVStore.open({host: "127.0.0.1", user: "game", password: "secret", database: "game"});
```

Its table is made through `SchemaMigrator.postgres()`, whose advisory lock keeps instances starting together from
both making it, and its key is in the "C" collation, so keys sort by their bytes there as everywhere else and a scan
is one index range. Every statement binds its values (a value as a binary `bytea`) and every write is one statement
with the revision check in its `WHERE`. At READ COMMITTED, the server's default, a compare-and-set another
connection's write overtook waits for it and answers null; inside a REPEATABLE READ or SERIALIZABLE transaction the
server fails it instead, with an `SQLError` to retry the transaction on. PHP's PDO driver binds nothing, so the store
is native only.

### Typed values

A `KVRepo<T>` reads and writes the values under one key prefix through a `KVCodec<T>`, and keeps the codec's `schema`
beside each value it writes. `KVCodecs.json()` writes JSON; `KVCodecs.rpc(RPCCodecs.of(Ship))` writes an `RPCStruct`
class as the RPC lane sends it, a few bytes a field, its schema the class's layout; `text()` and `bytes()` are the
plain ones.

```haxe
import crossbyte.db.kv.KVCodecs;
import crossbyte.db.kv.KVRepo;
import crossbyte.db.kv.MemoryKVStore;

var players = new KVRepo<{name:String, level:Int}>(new MemoryKVStore(), "players/", KVCodecs.json());
var saved = players.put("alice", {name: "Alice", level: 1});
players.compareAndSet("alice", {name: "Alice", level: 2}, saved.revision);
trace(players.get("alice").value.level); // 2
```

A record written with another schema (an `RPCStruct` whose fields have changed since, a JSON schema number raised
with `KVCodecs.json(2)`) is refused with a `KVError` of `SchemaMismatch` naming its key, rather than read as the new
format, and bytes its codec cannot read with `Undecodable`. Keys and scans are the repository's own, the prefix taken
off, so several repositories share a store as etcd's clients share one keyspace through its namespaces.

### Transactions and limits

`begin()`, `commit()` and `rollback()` keep writes together. A `MemoryKVStore` transaction holds the store for the
thread that began it; other threads wait for it to end. An `SQLiteKVStore` one begins with `BEGIN IMMEDIATE`, taking
the database's write lock at once, and a `PostgresKVStore` one at the connection's `isolationLevel`.

What a caller can make a store hold is bounded by its `KVOptions`, each a refusal rather than a truncation: a key
of at most `maxKeyBytes` in UTF-8 (1 KiB), a value of at most `maxValueBytes` (1 MiB, as Firestore holds a
document to), a scan of at most `maxScanLimit` records (1,000), and a page of at most `maxPageBytes` of values (4 MiB).
A key holds no NUL, no unpaired surrogate and not U+10FFFF, which the store keeps to bound its scans.

### Which store

`crossbyte.io.Store` is a client's: a few values a page or an application keeps across a reload, on every target
including a browser, with no revisions, scans or transactions. `crossbyte.db.kv` is a server's data.

## A database host gone silent

Natively, the MySQL, PostgreSQL and MongoDB clients keep TCP keepalive on with MySQL's timings: a probe after 60
idle seconds, then every 10, and the connection dropped after 6 unanswered. So a database host gone silent (a
partition, a crash) is found in about two minutes rather than hours, or never. MongoDB's client does the same on the
jvm, with the timings from Java 11, and cannot on the interpreter, hl and neko; `MongoConfig.keepAlive` says what
each target can.
