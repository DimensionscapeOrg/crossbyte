import utest.Runner;

/**
 * MySQL and MariaDB integration suite (`ci/mysql-tests.hxml`).
 *
 * Separate from every other entry point because it needs a live server, which
 * no other suite does. The `Data | MySQL` jobs in `.github/workflows/mysql.yml`
 * supply one through a service container -- MySQL 8.4 and MariaDB 11 -- and
 * anywhere `CROSSBYTE_MYSQL_HOST` is unset the cases skip and the run stays
 * green.
 */
@:topologyExempt("One case, needing a live MySQL or MariaDB server no other suite has. A group of one would say less than this does.")
@:access(crossbyte.core.CrossByte)
class MySQLIntegrationMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		runner.addCase(new crossbyte.db.MySQLIntegrationTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
