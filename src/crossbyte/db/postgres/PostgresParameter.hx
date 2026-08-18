package crossbyte.db.postgres;

import haxe.io.Bytes;

/**
 * A value bound to a `$1`-style placeholder by
 * `PostgresConnection.requestParams`.
 *
 * Bound values never become part of the statement text, which is the whole
 * point: the driver's other path builds SQL by substitution, so a value is only
 * ever as safe as the escaping applied to it, and no escaping at all can carry
 * a NUL byte — `PQescapeStringConn` works on NUL-terminated C strings, so a
 * ciphertext blob is silently truncated at its first zero.
 *
 * ```haxe
 * connection.requestParams("INSERT INTO events (id, payload) VALUES ($1, $2)",
 * 	[Text(Std.string(id)), Binary(ciphertext)]);
 * ```
 *
 * Numbers and booleans go as `Text`: PostgreSQL parses a text parameter
 * according to the column it is being compared or assigned to, so
 * `Text("42")` into an `integer` column is an integer. That is one less thing
 * to get wrong than encoding every type in binary would be.
 */
enum PostgresParameter {
	/**
	 * A textual value. Sent verbatim; it is not quoted, escaped, or inspected,
	 * because it never enters the statement text.
	 */
	Text(value:String);

	/**
	 * A byte-exact value, sent in binary format. The only form that survives
	 * NUL bytes and sequences that are not valid UTF-8, which is to say the
	 * only form usable for ciphertext.
	 */
	Binary(value:Bytes);

	/**
	 * SQL `NULL`, which is distinct from an empty string and from a
	 * zero-length blob.
	 */
	Null;
}
