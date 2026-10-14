package crossbyte.db.kv;

#if !js
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.errors.IllegalOperationError;
import utest.Assert;

/**
	Where each SQL store is, on every target that builds it: where its driver
	opens a database, with a refusal that says so everywhere else.
**/
class KVSupportTest extends utest.Test {
	public function testTheSQLiteStoreIsWhereSQLiteIs():Void {
		Assert.equals(SQLiteConnection.isSupported, SQLiteKVStore.isSupported);

		if (SQLiteKVStore.isSupported) {
			SQLiteKVStore.open(null).close();
		} else {
			Assert.raises(() -> new SQLiteKVStore(new SQLiteConnection()), IllegalOperationError);
			Assert.raises(() -> SQLiteKVStore.open(null));
		}
	}

	public function testThePostgresStoreIsNativeOnly():Void {
		// Where the driver binds its values; PHP's PDO does not.
		if (PostgresKVStore.isSupported) {
			Assert.isTrue(PostgresConnection.isSupported);
		} else {
			Assert.raises(() -> new PostgresKVStore(new PostgresConnection()), IllegalOperationError);
			Assert.raises(() -> PostgresKVStore.open({host: "localhost"}), IllegalOperationError);
		}
	}
}
#end
