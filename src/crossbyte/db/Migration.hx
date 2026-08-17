package crossbyte.db;

import crossbyte.errors.ArgumentError;
import haxe.crypto.Sha256;

/**
 * One forward step of a schema, identified by a version that must never change
 * once it has been applied anywhere.
 *
 * A migration is either a list of statements or an arbitrary function. The
 * statement form is the common one and lets `SchemaMigrator` fingerprint it for
 * you; the function form is for anything a statement cannot express, such as a
 * backfill that has to read rows before writing them.
 *
 * Statements are supplied individually rather than as one string with
 * semicolons in it. Splitting SQL on `;` is wrong the moment a statement
 * contains a string literal, a trigger body, or a quoted identifier, and most
 * drivers reject multiple statements in one call regardless.
 *
 * ```haxe
 * Migration.ofSql(1, "create accounts", "CREATE TABLE accounts (id INTEGER PRIMARY KEY)");
 *
 * Migration.ofStatements(2, "add device index", [
 * 	"ALTER TABLE devices ADD COLUMN account_id INTEGER",
 * 	"CREATE INDEX devices_account ON devices (account_id)"
 * ]);
 *
 * Migration.of(3, "backfill display names", function(connection:MyConnection):Void {
 * 	// whatever the driver needs
 * });
 * ```
 *
 * Versions are `Int`, which is 32-bit: a `YYYYMMDDnn` scheme fits, a full
 * `YYYYMMDDHHMMSS` timestamp does not.
 *
 * @author Christopher Speciale
 */
class Migration<T> {
	/**
	 * Order key, unique within a `SchemaMigrator` and stable forever.
	 */
	public var version(default, null):Int;

	/**
	 * Human-readable label, recorded alongside the version. Not an identifier:
	 * renaming a migration is harmless, renumbering one is not.
	 */
	public var name(default, null):String;

	/**
	 * Fingerprint compared against the value recorded when this migration was
	 * applied, so that editing an already-applied migration is reported rather
	 * than silently ignored — the edit does not re-run, and every database that
	 * ran the old text stays on it.
	 *
	 * Derived from the statements automatically. `null` for a function-bodied
	 * migration unless one is supplied, since there is nothing to hash, and a
	 * `null` on either side skips the comparison.
	 */
	public var checksum(default, null):Null<String>;

	@:noCompletion private var __statements:Array<String>;
	@:noCompletion private var __up:T->Void;

	/**
	 * A migration made of a single statement.
	 */
	public static function ofSql<T>(version:Int, name:String, sql:String):Migration<T> {
		if (sql == null || StringTools.trim(sql) == "") {
			throw new ArgumentError("Migration.ofSql requires a statement.");
		}

		return ofStatements(version, name, [sql]);
	}

	/**
	 * A migration made of several statements, applied in the order given.
	 */
	public static function ofStatements<T>(version:Int, name:String, statements:Array<String>):Migration<T> {
		if (statements == null || statements.length == 0) {
			throw new ArgumentError("Migration.ofStatements requires at least one statement.");
		}

		for (statement in statements) {
			if (statement == null || StringTools.trim(statement) == "") {
				throw new ArgumentError('Migration $version ("$name") contains an empty statement.');
			}
		}

		var migration = new Migration<T>(version, name);
		migration.__statements = statements.copy();
		// Joined with a separator that cannot appear in the split, so that
		// moving a fragment between two statements still changes the hash.
		migration.checksum = Sha256.encode(statements.join("\n;\n"));
		return migration;
	}

	/**
	 * A migration whose body is a function. Supply `checksum` to opt into drift
	 * detection; without one, editing this migration after it has been applied
	 * cannot be reported.
	 */
	public static function of<T>(version:Int, name:String, up:T->Void, ?checksum:String):Migration<T> {
		if (up == null) {
			throw new ArgumentError("Migration.of requires a body.");
		}

		var migration = new Migration<T>(version, name);
		migration.__up = up;
		migration.checksum = checksum;
		return migration;
	}

	/**
	 * Runs this migration. `execute` is only consulted for the statement form.
	 */
	public function apply(connection:T, execute:T->String->Void):Void {
		if (__up != null) {
			__up(connection);
			return;
		}

		if (execute == null) {
			throw new ArgumentError('Migration $version ("$name") is statement-based and needs an execute function.');
		}

		for (statement in __statements) {
			execute(connection, statement);
		}
	}

	/**
	 * The statements this migration runs, or an empty array for the function
	 * form. A copy: mutating it does not change the migration.
	 */
	public function statements():Array<String> {
		return __statements == null ? [] : __statements.copy();
	}

	public function toString():String {
		return '$version:$name';
	}

	@:noCompletion private function new(version:Int, name:String) {
		if (version <= 0) {
			// Zero is what "nothing applied yet" reads as, so it cannot also be
			// a real version without making an empty database ambiguous.
			throw new ArgumentError("Migration versions start at 1.");
		}

		if (name == null || StringTools.trim(name) == "") {
			throw new ArgumentError('Migration $version requires a name.');
		}

		this.version = version;
		this.name = name;
	}
}
