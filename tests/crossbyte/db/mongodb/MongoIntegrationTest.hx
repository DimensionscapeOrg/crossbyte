package crossbyte.db.mongodb;

#if (sys && !js)
import crossbyte.db.ConnectionPool;
import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.BsonRegex;
import crossbyte.db.mongodb.bson.BsonTimestamp;
import crossbyte.db.mongodb.bson.Decimal128;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.IOError;
import crossbyte.test.Require;
import haxe.Int64;
import haxe.io.Bytes;
import utest.Assert;

/**
	The driver against a real MongoDB server.

	`FakeMongoServer` runs everywhere and checks what the driver sends; this
	checks that a real server agrees -- that it takes the handshake, the
	SCRAM proof, the OP_MSG sequences and the BSON, and that a TTL index acts
	on the dates. Three servers, each named by an environment variable, and
	each part skipped when its variable is unset:

	- `CROSSBYTE_MONGO_URI`: a standalone server requiring authentication,
	  with a root user in `admin`.
	- `CROSSBYTE_MONGO_RS_URI`: a replica set member, for transactions.
	- `CROSSBYTE_MONGO_TLS_URI` and `CROSSBYTE_MONGO_TLS_CA`: a server
	  requiring TLS, and the authority its certificate was issued by.

	`CROSSBYTE_MONGO_REQUIRED` makes an unset `CROSSBYTE_MONGO_URI` a failure,
	which is what keeps the CI job from passing without reaching a server.
**/
@:suiteExempt("needs a live MongoDB server; run by the Data | MongoDB CI job")
class MongoIntegrationTest extends utest.Test {
	private var connection:MongoConnection;
	private var database:String;

	public function setup():Void {
		database = "crossbyte_it_" + Std.random(0x7FFFFFF);
		connection = null;

		if (__uri() != null) {
			connection = __open(__uri());
		}
	}

	public function teardown():Void {
		if (connection != null) {
			try {
				connection.runCommand(new BsonDocument().add("dropDatabase", 1));
			} catch (_:Dynamic) {}

			try connection.close() catch (_:Dynamic) {}
			connection = null;
		}
	}

	public function testTheServerTakesTheHandshake():Void {
		if (__skip()) {
			return;
		}

		Assert.isTrue(connection.connected);
		Assert.isTrue(connection.ping());
		Assert.isTrue(connection.serverVersion.length > 0, connection.serverVersion);
		Assert.isTrue(Reflect.field(connection.serverInfo, "maxWireVersion") >= 6);
	}

	public function testBothScramMechanismsSignIn():Void {
		if (__skip()) {
			return;
		}

		for (mechanism in ["SCRAM-SHA-256", "SCRAM-SHA-1"]) {
			var other = new MongoConnection();
			other.open({uri: __uri(), authMechanism: mechanism, database: database});
			Assert.equals(0, other.count("nothing"), mechanism);
			other.close();
		}
	}

	public function testAWrongPasswordIsTheServersRefusal():Void {
		if (__skip()) {
			return;
		}

		var error:MongoError = null;

		try {
			new MongoConnection().open({uri: __uri(), password: "definitely not it"});
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.AUTHENTICATION_FAILED, error.errorID);
	}

	public function testEveryTypeSurvivesTheServer():Void {
		if (__skip()) {
			return;
		}

		var id = new ObjectId();
		var document = new BsonDocument()
			.add("_id", id)
			.add("double", 1.5)
			.add("string", "Zürich \u{1F680}")
			.add("nested", new BsonDocument().add("inner", true))
			.add("array", ([1, "two", null] : Array<Dynamic>))
			.add("binary", Bytes.ofHex("00ff10"))
			.add("uuid", BsonBinary.randomUuid())
			.add("date", BsonDateTime.parse("2040-01-01T00:00:00.250Z"))
			.add("regex", new BsonRegex("^a.*z$", "i"))
			.add("int32", -7)
			.add("int64", new BsonInt64(Int64.parseString("9007199254740993")))
			.add("decimal", Decimal128.fromString("-12345678901234567890.123456789"))
			.add("timestamp", new BsonTimestamp(1790769600, 3));

		connection.insert("types", [document]);
		var exact = __open(__uri(), true);
		var back:Dynamic = exact.findOne("types", {_id: id});
		exact.close();

		Require.notNull(back);
		Assert.equals(1.5, back.double);
		Assert.equals("Zürich \u{1F680}", back.string);
		Assert.equals(true, back.nested.inner);
		Assert.equals("00ff10", (back.binary : Bytes).toHex());
		Assert.equals(BsonBinary.UUID, (back.uuid : BsonBinary).subtype);
		Assert.equals("2208988800250", Int64.toStr((back.date : BsonDateTime).millis));
		Assert.equals("i", (back.regex : BsonRegex).options);
		Assert.equals(-7, back.int32);
		Assert.equals("9007199254740993", Int64.toStr(back.int64));
		Assert.equals("-12345678901234567890.123456789", (back.decimal : Decimal128).toString());
		Assert.equals(3, (back.timestamp : BsonTimestamp).increment);
	}

	public function testACursorPagesThroughAThousandDocumentsAndCloses():Void {
		if (__skip()) {
			return;
		}

		connection.insert("events", [for (i in 0...1000) {n: i}]);

		var seen:Int = 0;

		for (_ in connection.find("events", null, {batchSize: 100, sort: {n: 1}})) {
			seen++;
		}

		Assert.equals(1000, seen);

		// Closed part-way: the server no longer has it, so a getMore for it is
		// refused as CursorNotFound.
		var cursor = connection.find("events", null, {batchSize: 10});
		cursor.next();
		var id:Int64 = cursor.id;
		cursor.close();

		var error:MongoError = null;

		try {
			connection.runCommand(new BsonDocument().add("getMore", new BsonInt64(id)).add("collection", "events"));
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.CURSOR_NOT_FOUND, error.errorID);
	}

	public function testWritesReportWhatTheyDid():Void {
		if (__skip()) {
			return;
		}

		Assert.equals(3, connection.insert("people", [{name: "a", age: 30}, {name: "b", age: 40}, {name: "c", age: 50}]).inserted);
		var update = connection.update("people", {age: {"$gte": 40}}, {"$set": {senior: true}}, {multi: true});
		Assert.equals(2, update.matched);
		Assert.equals(2, update.modified);
		var upsert = connection.update("people", {name: "d"}, {"$set": {age: 60}}, {upsert: true});
		Assert.equals(1, upsert.upserted.length);
		Assert.equals(4, connection.count("people"));
		var total:Dynamic = connection.aggregate("people", [{"$group": {_id: null, total: {"$sum": "$age"}}}]).next();
		Assert.equals(180, total.total);
		Assert.equals(1, connection.delete("people", {name: "a"}).deleted);
		Assert.equals(3, connection.delete("people", {}).deleted);
		Assert.isTrue(connection.drop("people"));
		// Dropped again. A server before 7.0 says there was nothing to drop;
		// 7.0 and later report success for a collection that is not there,
		// and CI runs 7.
		var major:Null<Int> = Std.parseInt(connection.serverVersion.split(".")[0]);
		Assert.equals(major != null && major < 7 ? false : true, connection.drop("people"), "server " + connection.serverVersion);
	}

	public function testADuplicateKeyCarriesItsCodeAndPosition():Void {
		if (__skip()) {
			return;
		}

		connection.createIndex("users", {email: 1}, {unique: true});
		connection.insert("users", [{email: "a@example.com"}]);
		var error:MongoError = null;

		try {
			connection.insert("users", [{email: "b@example.com"}, {email: "a@example.com"}]);
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.DUPLICATE_KEY, error.errorID);
		Assert.equals(1, error.writeErrors[0].index);
		Assert.equals(1, error.result.inserted);
	}

	public function testATtlIndexDeletesByTheDateItHolds():Void {
		if (__skip()) {
			return;
		}

		// The TTL monitor wakes every 60 seconds; asked to wake every second,
		// the test sees it act. Needs the root user the job connects as.
		connection.runCommand(new BsonDocument().add("setParameter", 1).add("ttlMonitorSleepSecs", 1), "admin");
		connection.createIndexes("sessions", [{key: {expiresAt: 1}, name: "ttl", expireAfterSeconds: 0}]);
		// time of day: a session expires at an instant on the wall clock.
		var past:Date = Date.fromTime(Date.now().getTime() - 60000.0);
		connection.insert("sessions", [{_id: "s_expired", expiresAt: past}, {_id: "s_live", expiresAt: Date.fromTime(Date.now().getTime() + 3600000.0)}]);

		var deadline:Float = haxe.Timer.stamp() + 60.0;

		while (connection.count("sessions", {_id: "s_expired"}) > 0 && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.5);
		}

		// Deleted by the server for its date: the JSON path could only ever
		// have stored the date as text, which a TTL index ignores.
		Assert.equals(0, connection.count("sessions", {_id: "s_expired"}));
		Assert.equals(1, connection.count("sessions", {_id: "s_live"}));
		connection.runCommand(new BsonDocument().add("setParameter", 1).add("ttlMonitorSleepSecs", 60), "admin");
	}

	public function testTheSessionStoreTheAuditTriedToBuild():Void {
		if (__skip()) {
			return;
		}

		// The program the old driver could not run: sessions upserted with a
		// real date, read back by id, through the statement API as well.
		connection.createIndexes("sessions", [{key: {expiresAt: 1}, name: "ttl", expireAfterSeconds: 0}]);
		var sid:String = "s_abc123";
		var expires:Date = Date.fromTime(Date.now().getTime() + 3600000.0);
		connection.update("sessions", {_id: sid}, {"$set": {userId: 42, expiresAt: expires}}, {upsert: true});

		var session:Dynamic = connection.findOne("sessions", {_id: sid});
		Require.notNull(session);
		Assert.equals(42, session.userId);
		Assert.isTrue(Std.isOfType(session.expiresAt, Date));

		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"find": "sessions", "filter": {"_id": :sid, "expiresAt": {"$$gt": :now}}}';
		statement.parameters.sid = sid;
		statement.parameters.now = Date.now();
		statement.execute();
		var result = statement.getResult();
		Require.notNull(result);
		Assert.equals(1, result.data.length);
	}

	public function testTransactionsCommitAndRollBack():Void {
		var uri:String = Sys.getEnv("CROSSBYTE_MONGO_RS_URI");

		if (uri == null || uri == "") {
			Assert.pass();
			return;
		}

		var rs = new MongoConnection();
		rs.open({uri: uri, database: database});

		try {
			// A collection has to exist before a transaction writes to it on
			// servers before 4.4.
			rs.insert("accounts", [{_id: 1, balance: 100}]);

			rs.begin();
			rs.update("accounts", {_id: 1}, {"$inc": {balance: -25}});
			Assert.isTrue(rs.inTransaction);
			rs.commit();
			Assert.equals(75, rs.findOne("accounts", {_id: 1}).balance);

			rs.begin();
			rs.update("accounts", {_id: 1}, {"$set": {balance: 0}});
			rs.rollback();
			Assert.equals(75, rs.findOne("accounts", {_id: 1}).balance);

			// Left open and released: the pool ends it before anyone else has it.
			var pool = new ConnectionPool<MongoConnection>({factory: () -> rs, maxSize: 1});
			var borrowed = pool.acquire();
			borrowed.begin();
			borrowed.update("accounts", {_id: 1}, {"$set": {balance: -1}});
			pool.release(borrowed);
			Assert.isFalse(rs.inTransaction);
			Assert.equals(75, rs.findOne("accounts", {_id: 1}).balance);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try rs.runCommand(new BsonDocument().add("dropDatabase", 1)) catch (_:Dynamic) {}
		rs.close();
	}

	public function testTlsIsVerifiedAgainstTheAuthorityGiven():Void {
		var uri:String = Sys.getEnv("CROSSBYTE_MONGO_TLS_URI");
		var ca:String = Sys.getEnv("CROSSBYTE_MONGO_TLS_CA");

		if (uri == null || uri == "" || ca == null || ca == "") {
			Assert.pass();
			return;
		}

		var trusted = new MongoConnection();
		trusted.open({uri: uri, tls: true, tlsCAFile: ca});
		Assert.isTrue(trusted.ping());
		trusted.close();

		Assert.raises(() -> new MongoConnection().open({uri: uri, tls: true}), IOError);
	}

	private function __open(uri:String, exactDates:Bool = false):MongoConnection {
		var c = new MongoConnection();
		c.open({uri: uri, database: database, exactDates: exactDates});
		return c;
	}

	private function __skip():Bool {
		if (connection != null) {
			return false;
		}

		if (Sys.getEnv("CROSSBYTE_MONGO_REQUIRED") != null) {
			// Without it a broken service container would skip every case and
			// report a green run.
			Assert.fail("CROSSBYTE_MONGO_REQUIRED is set but CROSSBYTE_MONGO_URI is not: the server this job exists to test was never reached.");
			return true;
		}

		Assert.pass();
		return true;
	}

	private static function __uri():String {
		var uri:String = Sys.getEnv("CROSSBYTE_MONGO_URI");
		return uri == null || uri == "" ? null : uri;
	}
}
#end
