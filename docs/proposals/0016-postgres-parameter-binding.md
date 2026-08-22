# Proposal 0016 — Postgres parameter binding

**Status:** Implemented

**Motivation:** The driver had no parameter binding. Statements were assembled
as SQL text with values escaped into them, and results came back as JSON with
every value stringified. Three consequences, in order of severity:

1. **Binary data could not survive a round trip.** `PQescapeStringConn` works
   on NUL-terminated C strings, so a value is truncated at its first zero byte
   — silently, with no error. A ciphertext blob written through that path
   became a fragment of itself. For an encrypted event log that is data loss,
   not a performance note.
2. **Values that are not valid UTF-8 could not be returned at all**, because
   the result path put every value through JSON.
3. **Escaping correctness depended on `standard_conforming_strings`.** Binding
   removes the question rather than answering it.

---

## What landed

`PostgresConnection.requestParams(sql, params)` runs a statement through
`PQexecParams` with `$1`-style placeholders. Values never enter the statement
text, so quoting stops being a question that has to be got right.

```haxe
connection.requestParams("INSERT INTO events (id, payload) VALUES ($1, $2)",
	[Text(Std.string(id)), Binary(ciphertext)]);
```

`PostgresParameter` is `Text`, `Binary` or `Null`. Numbers and booleans go as
`Text`: PostgreSQL parses a text parameter according to the column it is being
assigned to, which is one less thing to get wrong than encoding every type in
binary. `Null` is distinct from an empty value — the wire format carries `-1`
rather than `0`, and libpq is handed a null pointer rather than a zero-length
one, because collapsing those makes a NULL and an empty string the same row
and only shows up much later in a `WHERE` clause.

### The wire format

Both directions are length-prefixed rather than delimited or escaped, which is
the property the old path lacked. Every integer is signed little-endian 32-bit,
written a byte at a time so neither side depends on host byte order.
`PostgresWire` documents both blocks and is the only place that knows them.

The result block is returned as a pointer plus a length rather than a C string,
for the same reason the parameters are length-prefixed: it carries NUL bytes.
Values arrive as `haxe.io.Bytes`.

### Text results, not binary

`PQexecParams` is called with `resultFormat` 0. `bytea` then arrives as its
`\x…` hex rendering, which is exact, and `PostgresWire.decodeByteaHex` turns it
back into bytes. The alternative — binary results — would mean decoding every
column type from its network representation by OID, which is a much larger
surface for no gain on the case that mattered. `PQgetlength` rather than
`strlen` measures each value, since a text column may legitimately contain NUL.

## Testing

**Locally verifiable, and verified:** `PostgresWireTest`, eleven cases run on
every target, covering the encoding on both sides — NULL against empty, a
binary parameter carrying NUL bytes, text sent verbatim, parameter ordering,
row and field decoding, values that are not valid UTF-8, an error block raising
the server message, a truncated block raising rather than reading past the end
of the buffer, and `bytea` hex round-tripping including the cases where a
`text` column legitimately begins `\x` and must be left alone.

**Verified by compilation only:** the C++ in `NativePostgres.cpp`. It builds as
part of the native suite, so its types and syntax are checked, but nothing on
a machine without libpq and a server can execute it.

**Verified on the first CI run, not before:** five integration cases added to
`PostgresIntegrationTest` — a NUL-carrying blob round-tripping through `bytea`,
a hostile string stored verbatim rather than executed, `NULL` staying distinct
from `""` in both directions, fields and `affectedRows` from a bound statement,
and a failing bound statement raising the server message while leaving the
connection usable.

This split is stated because it is the honest shape of the work: the encoding
decisions are covered, the native call is not, and the difference matters when
reading a green local run.

## Seams left open

- **`PostgresStatement.execute()` still substitutes, by design.** Its
  `parameters` are named and `PQexecParams` is positional, so mapping one onto
  the other means scanning statements for placeholders — and getting that wrong
  around string literals, dollar-quoting or comments would reintroduce the bug
  behind an API that looks safe. `executeParams(params)` binds positionally
  instead, reporting results through the same machinery, and the named path is
  unchanged and documented for what it cannot carry. A scanner good enough to
  make the named path bind is a separate piece of work with its own risk.
- **`MySQLStatement` cannot be given the same fix.** It runs on Haxe's
  `sys.db.Mysql`, whose `Connection` exposes `request`, `escape` and `quote`
  and no binding at all, so there is nothing to bind through. Documented on
  `parameters` rather than left to be discovered; a bound path there needs a
  native libmysqlclient bridge of the kind the Postgres driver has.
- **No typed results.** Values are bytes, and callers convert. Returning typed
  values means an OID table and a decision about every type, which belongs in
  its own change.
- **No prepared statements.** `PQprepare`/`PQexecPrepared` would save the parse
  on a hot repeated statement. Worth having, and separable.
