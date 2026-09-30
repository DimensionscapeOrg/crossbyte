import utest.Runner;

/**
 * MongoDB integration suite (`ci/mongo-tests.hxml` natively,
 * `ci/mongo-tests-interp.hxml` and `ci/mongo-tests-jvm.hxml` elsewhere).
 *
 * Separate from every other entry point because it needs live MongoDB
 * servers, which no other suite does. The `Data | MongoDB` CI job supplies
 * them; anywhere `CROSSBYTE_MONGO_URI` is unset the cases skip and the run
 * stays green. Everything the driver does without a server is covered on
 * every target by the suites `TestSuites.addDatabase` registers, against
 * `FakeMongoServer`.
 */
@:topologyExempt("One case, needing live MongoDB servers no other suite has. A group of one would say less than this does.")
@:access(crossbyte.core.CrossByte)
class MongoIntegrationMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		runner.addCase(new crossbyte.db.mongodb.MongoIntegrationTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
