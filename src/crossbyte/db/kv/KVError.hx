package crossbyte.db.kv;

import crossbyte.errors.Error;

/**
	A record a store or a `KVRepo` will not hand back as it is: one written
	in another format than the repository's codec (`SchemaMismatch`), one
	its codec cannot read (`Undecodable`), or one past the store's limits
	(`TooLarge`). `kind` says
	which, to switch on rather than the message, and `key` names the record.
	`errorId` is the kind's number.

	A refused argument (a key too long, a limit out of range) is an
	`ArgumentError`, a store used after `close()` an `IllegalOperationError`,
	and a database's own failure the driver's `SQLError`.
**/
class KVError extends Error {
	// Not `code`, which an exception has of its own on PHP: `kind`, as Rust's
	// io::Error names it.

	/** Why, to switch on. **/
	public final kind:KVErrorKind;

	/** The record's key, as the store holds it. **/
	public final key:Null<String>;

	public function new(kind:KVErrorKind, key:Null<String>, message:String) {
		super(message, kind);
		name = "KVError";
		this.kind = kind;
		this.key = key;
	}
}
