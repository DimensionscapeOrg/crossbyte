# Databases

CrossByte's database clients are blocking drivers with one shape: every SQL driver's statements take `parameters` as
`SQLValue`s, and read a result row by row and column by column with `executeEach` and `SQLRow`. None is built for
JavaScript.

| Database | Where | How |
| --- | --- | --- |
| SQLite | natively | statements prepared once and their parameters bound |
| MySQL, MariaDB | natively; the jvm | natively through hxcpp's bundled client; on the jvm through Connector/J on the class path, without the TLS or limit settings |
| PostgreSQL | natively; php | natively through libpq, loaded at run time, with bound parameters, statement and connect timeouts and `cancel()`; on php through PDO |
| MongoDB | hxcpp, the jvm, the interpreter, hl, neko | its wire protocol: OP_MSG, SCRAM, TLS, cursors, transactions |

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

## A database host gone silent

Natively, the MySQL, PostgreSQL and MongoDB clients keep TCP keepalive on with MySQL's timings: a probe after 60
idle seconds, then every 10, and the connection dropped after 6 unanswered. So a database host gone silent (a
partition, a crash) is found in about two minutes rather than hours, or never. MongoDB's client does the same on the
jvm, with the timings from Java 11, and cannot on the interpreter, hl and neko; `MongoConfig.keepAlive` says what
each target can.
