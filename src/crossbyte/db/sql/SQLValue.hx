package crossbyte.db.sql;

import haxe.Int64;
import haxe.io.Bytes;

/**
	A value for a statement parameter: `null`, a `Bool`, an `Int`, a `Float`,
	an `Int64`, a `String`, `Bytes` or a `Date`.

	The type of `parameters` on `SQLiteStatement`, `MySQLStatement` and
	`PostgresStatement`. Any of those converts to it implicitly, so
	`statement.parameters.id = 7` and `statement.parameters.name = "bob"`
	compile as they read; anything else does not.

	What each becomes:
	- **SQLite** binds it: `null` as NULL, a `Bool` as 1 or 0, an `Int` or
	  `Int64` as an integer, a `Float` as a real (a whole one within 2^53 as
	  an integer), a `String` as text (as a blob of its UTF-8
	  when it holds a NUL), `Bytes` as a blob, a `Date` as the text
	  `Std.string` gives it, local time.
	- **MySQL** writes it as a literal: `NULL`, `TRUE`/`FALSE`, a number,
	  `X'...'` for `Bytes`, a `Date` as `'YYYY-MM-DD hh:mm:ss[.mmm]'` in UTC,
	  and a `String` quoted.
	- **Postgres** writes it as a literal: `NULL`, `TRUE`/`FALSE`, a number,
	  `'\x...'` for `Bytes` (a `bytea`), a `Date` as an ISO 8601 UTC
	  timestamp, and a `String` quoted. `executeParams` binds instead.

	Read back, a parameter is its value as `Dynamic`; cast it to the type it
	holds (`var name:String = statement.parameters.name`).
**/
abstract SQLValue(Dynamic) from Int from Float from Bool from String from Bytes from Date from Int64 to Dynamic {}
