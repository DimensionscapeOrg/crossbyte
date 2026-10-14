package crossbyte.db;

import crossbyte.db.postgres.PostgresSSLMode;
import crossbyte.db.sql.sqlite.JournalMode;
import crossbyte.db.sql.sqlite.SynchronousMode;
import crossbyte.db.sql.sqlite.TempStoreMode;
import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	The storage modes read from configuration text: `fromString` on
	`SynchronousMode`, `TempStoreMode` and `PostgresSSLMode`. Pure, so every
	target runs it, PHP included.
**/
class StorageModesTest extends utest.Test {
	public function testSynchronousModesAreReadByNameOrNumber():Void {
		Assert.equals(SynchronousMode.OFF, SynchronousMode.fromString("off"));
		Assert.equals(SynchronousMode.NORMAL, SynchronousMode.fromString("NORMAL"));
		Assert.equals(SynchronousMode.FULL, SynchronousMode.fromString(" Full "));
		Assert.equals(SynchronousMode.EXTRA, SynchronousMode.fromString("extra"));
		Assert.equals(SynchronousMode.OFF, SynchronousMode.fromString("0"));
		Assert.equals(SynchronousMode.NORMAL, SynchronousMode.fromString("1"));
		Assert.equals(SynchronousMode.FULL, SynchronousMode.fromString("2"));
		Assert.equals(SynchronousMode.EXTRA, SynchronousMode.fromString("3"));
		for (bad in [null, "", "4", "-1", "normall", "on"]) {
			Assert.raises(() -> SynchronousMode.fromString(bad), ArgumentError, bad);
		}
	}

	public function testTempStoreModesAreReadByNameOrNumber():Void {
		Assert.equals(TempStoreMode.DEFAULT, TempStoreMode.fromString("default"));
		Assert.equals(TempStoreMode.FILE, TempStoreMode.fromString("FILE"));
		Assert.equals(TempStoreMode.MEMORY, TempStoreMode.fromString(" memory"));
		Assert.equals(TempStoreMode.DEFAULT, TempStoreMode.fromString("0"));
		Assert.equals(TempStoreMode.FILE, TempStoreMode.fromString("1"));
		Assert.equals(TempStoreMode.MEMORY, TempStoreMode.fromString("2"));
		for (bad in [null, "", "3", "ram", "mem"]) {
			Assert.raises(() -> TempStoreMode.fromString(bad), ArgumentError, bad);
		}
	}

	public function testPostgresSslModesAreReadAsLibpqSpellsThem():Void {
		Assert.equals(PostgresSSLMode.DISABLE, PostgresSSLMode.fromString("disable"));
		Assert.equals(PostgresSSLMode.ALLOW, PostgresSSLMode.fromString("allow"));
		Assert.equals(PostgresSSLMode.PREFER, PostgresSSLMode.fromString("Prefer"));
		Assert.equals(PostgresSSLMode.REQUIRE, PostgresSSLMode.fromString("REQUIRE"));
		Assert.equals(PostgresSSLMode.VERIFY_CA, PostgresSSLMode.fromString("verify-ca"));
		Assert.equals(PostgresSSLMode.VERIFY_FULL, PostgresSSLMode.fromString("VERIFY_FULL"));
		Assert.equals(PostgresSSLMode.VERIFY_FULL, PostgresSSLMode.fromString(" verify-full "));
		// A mistyped mode is refused rather than read as a weaker one.
		for (bad in [null, "", "verify", "verifyfull", "required", "true"]) {
			Assert.raises(() -> PostgresSSLMode.fromString(bad), ArgumentError, bad);
		}
	}

	public function testJournalModesStillReadAsBefore():Void {
		Assert.equals(JournalMode.WAL, JournalMode.fromString("wal"));
		Assert.equals(JournalMode.DELETE, JournalMode.fromString("delete"));
	}
}
