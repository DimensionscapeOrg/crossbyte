import utest.Runner;

/**
 * Postgres integration suite (`ci/postgres-tests.hxml`).
 *
 * Separate from every other entry point because it needs a live PostgreSQL
 * server, which no other suite does. The `Data | Postgres` CI job supplies one
 * through a service container; anywhere `CROSSBYTE_PG_HOST` is unset the cases
 * skip and the run stays green.
 */
@:access(crossbyte.core.CrossByte)
class PostgresIntegrationMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		runner.addCase(new crossbyte.db.PostgresIntegrationTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
