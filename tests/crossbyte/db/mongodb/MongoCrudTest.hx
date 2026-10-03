package crossbyte.db.mongodb;

#if (sys && !js)
import crossbyte.db.mongodb.FakeMongoServer.ReceivedCommand;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.ArgumentError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.test.Require;
import haxe.Int64;
import utest.Assert;

/**
	Reads and writes against `FakeMongoServer`: what goes on the wire for
	each command, cursors paging with getMore and closing with killCursors,
	write errors and write concern, and the statement API over all of it.
**/
class MongoCrudTest extends utest.Test {
	private var server:FakeMongoServer;
	private var connection:MongoConnection;

	public function setup():Void {
		server = new FakeMongoServer();
		connection = null;
	}

	public function teardown():Void {
		if (connection != null) {
			try connection.close() catch (_:Dynamic) {}
		}

		server.stop();
	}

	public function testInsertSendsASequenceWithEachIdFirst():Void {
		__start();
		var given = ObjectId.fromHex("0123456789abcdef01234567");
		var result:MongoWriteResult = connection.insert("people", [{name: "Ada"}, {_id: given, name: "Grace"}, {name: "Edsger"}]);

		Assert.equals(3, result.inserted);
		Assert.equals(3, connection.affectedRows);
		Assert.equals(3, result.insertedIds.length);
		Assert.isTrue((result.insertedIds[1] : ObjectId).equals(given));
		Assert.equals(result.insertedIds[2], connection.lastInsertId);

		var insert:ReceivedCommand = server.commands("insert")[0];
		// As a document sequence beside the body, not an array inside it.
		Assert.same(["documents"], insert.sequences);
		Assert.equals("people", insert.body.get("insert"));
		Assert.equals("app", insert.body.get("$db"));

		var stored:Array<BsonDocument> = server.documents("app.people");
		Assert.equals(3, stored.length);

		for (i in 0...3) {
			Assert.equals("_id", stored[i].keyAt(0), 'document $i');
			Assert.isTrue((stored[i].get("_id") : ObjectId).equals(result.insertedIds[i]));
		}

		Assert.equals("Edsger", stored[2].get("name"));

		var barbara:Dynamic = connection.insertOne("people", {name: "Barbara"});
		Assert.isTrue(Std.isOfType(barbara, ObjectId));
		Assert.equals(barbara, connection.lastInsertId);
	}

	public function testFindSendsItsOptionsAndTheSortInOrder():Void {
		__start();
		server.seed("app.people", [
			__person(1, "Hopper", "Grace", 85),
			__person(2, "Lovelace", "Ada", 36),
			__person(3, "Hopper", "Alan", 40),
			__person(4, "Dijkstra", "Edsger", 72)
		]);

		var sort = new BsonDocument().add("last", 1).add("first", -1);
		var found:Array<Dynamic> = connection.find("people", {age: {"$gt": 38}}, {
			sort: sort,
			projection: {first: 1},
			limit: 2,
			maxTimeMS: 500,
			comment: "report"
		}).toArray();

		Assert.equals(2, found.length);
		Assert.equals("Edsger", found[0].first);
		Assert.equals("Grace", found[1].first);
		Assert.isFalse(Reflect.hasField(found[0], "last"), "projection");

		var find:BsonDocument = server.commands("find")[0].body;
		Assert.equals("find", find.keyAt(0));
		Assert.same(["last", "first"], (find.get("sort") : BsonDocument).keys());
		Assert.equals(2, find.get("limit"));
		Assert.equals(500, find.get("maxTimeMS"));
		Assert.equals("report", find.get("comment"));
	}

	public function testACursorPagesWithGetMoreAndItsIdSurvivesExactly():Void {
		__start();
		server.seed("app.events", [for (i in 0...250) new BsonDocument().add("_id", i).add("n", i)]);

		var cursor:MongoCursor = connection.find("events", null, {batchSize: 100, sort: {n: 1}});
		// The server's id has high bits set: an id that lost anything on the
		// way back would name no cursor, or another.
		Assert.equals(0x7ABCDEF0, cursor.id.high);
		Assert.equals(100, cursor.buffered);

		var seen:Int = 0;
		var ordered:Bool = true;

		for (event in cursor) {
			if (event.n != seen) {
				ordered = false;
			}

			seen++;
		}

		Assert.equals(250, seen);
		Assert.isTrue(ordered);
		Assert.isTrue(cursor.closed);

		var getMores:Array<ReceivedCommand> = server.commands("getMore");
		Assert.equals(2, getMores.length);
		Assert.isTrue(Std.isOfType(getMores[0].body.get("getMore"), BsonInt64), "the id went back as an int64");
		Assert.isTrue((getMores[0].body.get("getMore") : BsonInt64).value == Int64.make(0x7ABCDEF0, 1), "the id went back exactly");
		Assert.equals("events", getMores[0].body.get("collection"));
		Assert.equals(100, getMores[0].body.get("batchSize"));
		Assert.equals(0, server.openCursors());
	}

	public function testClosingACursorPartWayKillsItOnTheServer():Void {
		__start();
		server.seed("app.events", [for (i in 0...250) new BsonDocument().add("_id", i)]);

		var cursor:MongoCursor = connection.find("events", null, {batchSize: 10});

		for (_ in 0...5) {
			cursor.next();
		}

		Assert.equals(1, server.openCursors());
		var id:Int64 = cursor.id;
		cursor.close();

		var kill:BsonDocument = server.commands("killCursors")[0].body;
		Assert.equals("events", kill.get("killCursors"));
		Assert.isTrue((kill.get("cursors")[0] : BsonInt64).value == id);
		Assert.equals(0, server.openCursors());
		Assert.isFalse(cursor.hasNext());

		// Closing twice sends nothing more.
		cursor.close();
		Assert.equals(1, server.commands("killCursors").length);
	}

	public function testFindOneLeavesNoCursorBehind():Void {
		__start();
		server.seed("app.people", [for (i in 0...5) __person(i, "L" + i, "F" + i, 20 + i)]);

		var one:Dynamic = connection.findOne("people", {last: "L3"});
		Require.notNull(one);
		Assert.equals("F3", one.first);
		Assert.isNull(connection.findOne("people", {last: "nobody"}));
		Assert.equals(0, server.openCursors());
	}

	public function testUpdateCountsWhatItMatchedAndChangedAndUpserts():Void {
		__start();
		server.seed("app.people", [__person(1, "Hopper", "Grace", 85), __person(2, "Hopper", "Alan", 40)]);

		var one:MongoWriteResult = connection.update("people", {last: "Hopper"}, {"$set": {status: "retired"}});
		Assert.equals(1, one.matched);
		Assert.equals(1, one.modified);

		var many:MongoWriteResult = connection.update("people", {last: "Hopper"}, {"$set": {status: "retired"}}, {multi: true});
		Assert.equals(2, many.matched);
		// One already held the value.
		Assert.equals(1, many.modified);

		var upsert:MongoWriteResult = connection.update("people", {last: "Knuth"}, {"$set": {first: "Donald"}}, {upsert: true});
		Assert.equals(0, upsert.matched);
		Assert.equals(1, upsert.upserted.length);
		Assert.isTrue(Std.isOfType(upsert.upserted[0], MongoWriteResult.MongoUpserted));
		Assert.equals(0, upsert.upserted[0].index);
		Assert.isTrue(Std.isOfType(upsert.upserted[0].id, ObjectId));
		Assert.equals(upsert.upserted[0].id, connection.lastInsertId);

		var statement:BsonDocument = (server.commands("update")[2].body.get("updates") : Array<Dynamic>)[0];
		Assert.equals(true, statement.get("upsert"));
		Assert.same(["updates"], server.commands("update")[0].sequences);

		Assert.raises(() -> connection.update("people", null, {"$set": {x: 1}}), ArgumentError);
	}

	public function testDeleteTakesOneOrAll():Void {
		__start();
		server.seed("app.people", [for (i in 0...4) __person(i, "Same", "F" + i, 30)]);

		Assert.equals(1, connection.delete("people", {last: "Same"}, {justOne: true}).deleted);
		Assert.equals(3, connection.delete("people", {last: "Same"}).deleted);
		Assert.equals(0, server.documents("app.people").length);

		var statements:Array<Dynamic> = server.commands("delete")[0].body.get("deletes");
		Assert.equals(1, (statements[0] : BsonDocument).get("limit"));
		// A null filter is refused rather than read as "everything".
		Assert.raises(() -> connection.delete("people", null), ArgumentError);
	}

	public function testAggregateAndCount():Void {
		__start();
		server.seed("app.people", [for (i in 0...10) __person(i, "L", "F" + i, 20 + i)]);

		var older:Array<Dynamic> = connection.aggregate("people", [{"$match": {age: {"$gte": 25}}}, {"$sort": {age: -1}}, {"$limit": 3}]).toArray();
		Assert.equals(3, older.length);
		Assert.equals(29, older[0].age);

		var counted:Array<Dynamic> = connection.aggregate("people", [{"$match": {age: {"$lt": 23}}}, {"$count": "n"}]).toArray();
		Assert.equals(3, counted[0].n);

		Assert.equals(10, connection.count("people"));
		Assert.equals(5, connection.count("people", {age: {"$gte": 25}}));

		var aggregate:BsonDocument = server.commands("aggregate")[0].body;
		Assert.isTrue(aggregate.exists("cursor"), "aggregate needs its cursor field");
	}

	public function testIndexesKeepTheirKeyOrderAndTtl():Void {
		__start();
		var name:String = connection.createIndex("sessions", new BsonDocument().add("userId", 1).add("expiresAt", -1));
		Assert.equals("userId_1_expiresAt_-1", name);

		connection.createIndexes("sessions", [{key: {expiresAt: 1}, name: "ttl", expireAfterSeconds: 0}, {key: {token: 1}, unique: true}]);
		var specs:Array<BsonDocument> = server.indexes("app.sessions");
		Assert.equals(3, specs.length);
		Assert.same(["userId", "expiresAt"], (specs[0].get("key") : BsonDocument).keys());
		Assert.equals(0, specs[1].get("expireAfterSeconds"));
		Assert.equals("token_1", specs[2].get("name"));
		Assert.equals(true, specs[2].get("unique"));
	}

	public function testHintsAndCollationsGoOutAsDocuments():Void {
		__start();
		server.seed("app.people", [__person(1, "Muller", "Anna", 30)]);

		connection.find("people", {last: "muller"}, {hint: {last: 1}, collation: {locale: "de", strength: 1, numericOrdering: true}}).toArray();
		connection.count("people", null, {hint: "last_1"});
		connection.update("people", {last: "Muller"}, {"$set": {seen: true}}, {
			hint: new BsonDocument().add("last", 1).add("first", 1),
			collation: {locale: "de", strength: 2}
		});
		connection.delete("people", {last: "nobody"}, {collation: {locale: "fr", backwards: true}});
		connection.aggregate("people", [{"$match": {}}], {collation: {locale: "sv"}}).toArray();
		connection.createIndexes("people", [{key: {last: 1}, collation: {locale: "de", caseFirst: "upper"}}]);

		var find:BsonDocument = server.commands("find")[0].body;
		Assert.same(["last"], (find.get("hint") : BsonDocument).keys());
		var collation:BsonDocument = find.get("collation");
		// Only the fields set, in the order MongoDB documents them.
		Assert.same(["locale", "strength", "numericOrdering"], collation.keys());
		Assert.equals("de", collation.get("locale"));
		Assert.equals(1, collation.get("strength"));
		Assert.equals(true, collation.get("numericOrdering"));

		Assert.equals("last_1", server.commands("count")[0].body.get("hint"));

		var update:BsonDocument = (server.commands("update")[0].body.get("updates") : Array<Dynamic>)[0];
		Assert.same(["last", "first"], (update.get("hint") : BsonDocument).keys());
		Assert.same(["locale", "strength"], (update.get("collation") : BsonDocument).keys());

		var delete:BsonDocument = (server.commands("delete")[0].body.get("deletes") : Array<Dynamic>)[0];
		Assert.same(["locale", "backwards"], (delete.get("collation") : BsonDocument).keys());

		Assert.equals("sv", (server.commands("aggregate")[0].body.get("collation") : BsonDocument).get("locale"));

		var spec:BsonDocument = server.indexes("app.people")[0];
		Assert.equals("upper", (spec.get("collation") : BsonDocument).get("caseFirst"));
	}

	public function testDropAnswersWhetherThereWasACollection():Void {
		__start();
		connection.insert("scratch", [{x: 1}]);
		Assert.isTrue(connection.drop("scratch"));
		Assert.isFalse(connection.drop("scratch"));
	}

	public function testADuplicateKeyIsAMongoErrorWithItsWriteErrors():Void {
		__start();
		connection.createIndex("users", {email: 1}, {unique: true});
		connection.insert("users", [{email: "a@example.com"}]);

		var ordered:MongoError = null;

		try {
			connection.insert("users", [{email: "b@example.com"}, {email: "a@example.com"}, {email: "c@example.com"}]);
		} catch (e:MongoError) {
			ordered = e;
		}

		Require.notNull(ordered);
		Assert.equals(MongoError.DUPLICATE_KEY, ordered.errorID);
		Assert.equals("DuplicateKey", ordered.codeName);
		Assert.equals(1, ordered.writeErrors.length);
		Assert.isTrue(Std.isOfType(ordered.writeErrors[0], MongoError.MongoWriteError));
		Assert.equals(1, ordered.writeErrors[0].index);
		// Stopped at the failure: one stored before it, none after.
		Assert.equals(1, ordered.result.inserted);
		Assert.equals(2, server.documents("app.users").length);
		Assert.isTrue(Std.isOfType(ordered, crossbyte.errors.SQLError));

		var unordered:MongoError = null;

		try {
			connection.insert("users", [{email: "a@example.com"}, {email: "d@example.com"}, {email: "b@example.com"}], {ordered: false});
		} catch (e:MongoError) {
			unordered = e;
		}

		Require.notNull(unordered);
		Assert.equals(2, unordered.writeErrors.length);
		Assert.equals(1, unordered.result.inserted);
		Assert.equals(unordered.result.insertedIds[1], connection.lastInsertId, "the last document stored, not the last sent");
	}

	public function testAServerErrorCarriesItsCodeAndLeavesTheConnectionUsable():Void {
		__start();
		server.replyNext("find", FakeMongoServer.__error(50, "MaxTimeMSExpired", "operation exceeded time limit"));

		var error:MongoError = null;

		try {
			connection.find("slow", null, {maxTimeMS: 1});
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.MAX_TIME_MS_EXPIRED, error.errorID);
		Assert.equals("MaxTimeMSExpired", error.codeName);
		Assert.equals("find", error.operation);
		Assert.isTrue(error.message.indexOf("operation exceeded time limit") >= 0);
		Assert.isTrue(connection.ping());
	}

	public function testAWriteConcernErrorSaysWhatWasWritten():Void {
		__start({writeConcern: {w: "majority", wtimeout: 100}});
		server.replyNext("insert", new BsonDocument()
			.add("n", 1)
			.add("writeConcernError", new BsonDocument().add("code", 64).add("codeName", "WriteConcernFailed").add("errmsg", "waiting for replication timed out"))
			.add("ok", 1));

		var error:MongoError = null;

		try {
			connection.insert("things", [{x: 1}]);
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.WRITE_CONCERN_FAILED, error.errorID);
		Require.notNull(error.writeConcernError);
		Assert.equals(1, error.result.inserted);

		var concern:BsonDocument = server.commands("insert")[0].body.get("writeConcern");
		Assert.equals("majority", concern.get("w"));
		Assert.equals(100, concern.get("wtimeout"));
	}

	public function testCountsPastThirtyTwoBitsAreWhole():Void {
		// MongoDB counts in 64 bits: an update or delete over a large
		// collection answers past 2^31, as an int64. Every count was read as
		// an Int, held at 2^31 - 1, so three billion documents updated read
		// 2147483647 -- and affectedRows, count() and a statement's
		// rowsAffected with them.
		__start();
		server.replyNext("update", new BsonDocument()
			.add("n", Int64.fromFloat(3000000000.0))
			.add("nModified", Int64.fromFloat(2500000000.0))
			.add("ok", 1));
		var update:MongoWriteResult = connection.update("people", {}, {"$set": {seen: true}}, {multi: true});
		Assert.equals(3000000000.0, update.matched);
		Assert.equals(2500000000.0, update.modified);
		Assert.equals(3000000000.0, connection.affectedRows);

		server.replyNext("delete", new BsonDocument().add("n", Int64.fromFloat(5000000001.0)).add("ok", 1));
		Assert.equals(5000000001.0, connection.delete("people", {}).deleted);
		Assert.equals(5000000001.0, connection.affectedRows);

		server.replyNext("count", new BsonDocument().add("n", Int64.fromFloat(6000000000.0)).add("ok", 1));
		Assert.equals(6000000000.0, connection.count("people"));
		// A count can come back as a double, too.
		server.replyNext("count", new BsonDocument().add("n", 7000000000.0).add("ok", 1));
		Assert.equals(7000000000.0, connection.count("people"));

		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"delete": "people", "deletes": [{"q": {}, "limit": 0}]}';
		server.replyNext("delete", new BsonDocument().add("n", Int64.fromFloat(4000000000.0)).add("ok", 1));
		statement.execute();
		Assert.equals(4000000000.0, Require.notNull(statement.getResult()).rowsAffected);

		// And an insert's counts add up past it, batch by batch.
		var result:MongoWriteResult = new MongoWriteResult(true);
		result.__add(2000000000, 0, 0, 0);
		result.__add(2000000000, 0, 0, 0);
		Assert.equals(4000000000.0, result.inserted);
	}

	public function testAnUnacknowledgedWriteIsNotWaitedFor():Void {
		__start();
		var result:MongoWriteResult = connection.insert("fire", [{x: 1}], {writeConcern: {w: 0}});
		Assert.isFalse(result.acknowledged);

		// moreToCome: the server sends nothing back, so nothing is read, and
		// the next reply is the next command's.
		Assert.isTrue(connection.ping());
		var insert:ReceivedCommand = server.commands("insert")[0];
		Assert.equals(2, insert.flags & 2);
		Assert.equals(1, server.documents("app.fire").length);
	}

	public function testInsertsAreSplitAtTheServersBatchLimit():Void {
		server.maxWriteBatchSize = 10;
		__start();

		var result:MongoWriteResult = connection.insert("bulk", [for (i in 0...25) {n: i}]);
		Assert.equals(25, result.inserted);
		Assert.equals(3, server.commands("insert").length);

		var stored:Array<BsonDocument> = server.documents("app.bulk");
		Assert.equals(25, stored.length);
		var match:Bool = true;

		for (i in 0...25) {
			if (stored[i].get("n") != i || !(stored[i].get("_id") : ObjectId).equals(result.insertedIds[i])) {
				match = false;
			}
		}

		Assert.isTrue(match);
	}

	public function testABatchRefusedWholeSaysWhatEarlierBatchesStored():Void {
		server.maxWriteBatchSize = 2;
		__start();
		server.passNext("insert");
		server.replyNext("insert", FakeMongoServer.__error(10107, "NotWritablePrimary", "not primary"));

		var error:MongoError = null;

		try {
			connection.insert("bulk", [for (i in 0...5) {n: i}]);
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(10107, error.errorID);
		// The first batch went in before the second was refused.
		Require.notNull(error.result);
		Assert.equals(2, error.result.inserted);
		Assert.equals(2, server.documents("app.bulk").length);
	}

	public function testInsertsAreSplitAtTheServersMessageLimit():Void {
		// Limits the server announces in its hello, small so the test is.
		server.maxMessageSize = 4000;
		server.maxBsonObjectSize = 2000;
		__start();

		var padding:String = StringTools.lpad("", "x", 900);
		var result:MongoWriteResult = connection.insert("big", [for (i in 0...12) {n: i, pad: padding}]);
		Assert.equals(12, result.inserted);
		Assert.isTrue(server.commands("insert").length >= 3, '${server.commands("insert").length} messages');
		Assert.equals(12, server.documents("app.big").length);

		// A document larger than the server takes is refused before sending.
		var sent:Int = server.commands("insert").length;
		Assert.raises(() -> connection.insert("big", [{pad: StringTools.lpad("", "x", 2500)}]), ArgumentError);
		Assert.equals(sent, server.commands("insert").length);
		Assert.isTrue(connection.ping(), "a refusal before sending leaves the connection in step");
	}

	public function testRequestRunsExtendedJsonWithBoundValues():Void {
		__start();
		var at:BsonDateTime = BsonDateTime.parse("2026-09-30T00:00:00Z");
		connection.insert("sessions", [{sid: "s_abc123", userId: 42, expiresAt: at}]);

		var found:Array<Dynamic> = [];

		for (doc in connection.request('{"find": "sessions", "filter": {"sid": :sid, "expiresAt": {"$$gte": {"$$date": "2026-09-29T00:00:00Z"}}}}', ["sid" => "s_abc123"])) {
			found.push(doc);
		}

		Assert.equals(1, found.length);
		Assert.equals(42, found[0].userId);
		Assert.isTrue(Std.isOfType(found[0].expiresAt, Date));

		var filter:BsonDocument = server.commands("find")[0].body.get("filter");
		Assert.isTrue(Std.isOfType((filter.get("expiresAt") : BsonDocument).get("$gte"), Date) || Std.isOfType((filter.get("expiresAt") : BsonDocument).get("$gte"), BsonDateTime));

		// A command without a cursor answers with its reply as the one row.
		var reply:Dynamic = connection.request('{"ping": 1}').next();
		Assert.equals(1, reply.ok);
	}

	public function testExactDatesComeBackExact():Void {
		__start({exactDates: true});
		connection.insert("t", [{at: BsonDateTime.parse("2040-01-01T00:00:00.250Z")}]);
		var back:Dynamic = connection.findOne("t");
		Assert.isTrue(Std.isOfType(back.at, BsonDateTime));
		Assert.equals("2208988800250", Int64.toStr((back.at : BsonDateTime).millis));
	}

	public function testOrderSensitiveArgumentsRefuseAnonymousObjectsOfSeveralFields():Void {
		__start();
		// An anonymous object's fields are not kept in order on most targets,
		// so "sort by a then b" would sort by whichever came first there.
		Assert.raises(() -> connection.find("people", null, {sort: {last: 1, first: 1}}), ArgumentError);
		Assert.raises(() -> connection.createIndex("people", {last: 1, first: 1}), ArgumentError);
		Assert.raises(() -> connection.runCommand({find: "people", filter: {}}), ArgumentError);

		// One field is fine, and so is a BsonDocument or Extended JSON text.
		Assert.equals(0, connection.find("people", null, {sort: {last: 1}}).toArray().length);
		Assert.equals(1, Reflect.field(connection.runCommand({ping: 1}), "ok"));
		Assert.equals(1, Reflect.field(connection.runCommand('{"count": "people", "query": {}}'), "ok"));
	}

	public function testAStatementPagesThroughACursor():Void {
		__start();
		server.seed("app.events", [for (i in 0...250) new BsonDocument().add("_id", i).add("kind", i % 2 == 0 ? "even" : "odd")]);

		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"find": "events", "filter": {"kind": :kind}, "sort": {"_id": 1}, "batchSize": 40}';
		statement.parameters.kind = "even";

		var results:Int = 0;
		statement.addEventListener(SQLEvent.RESULT, _ -> results++);

		statement.execute(50);
		var first = statement.getResult();
		Require.notNull(first);
		Assert.equals(50, first.data.length);
		Assert.isFalse(first.complete);
		Assert.isTrue(statement.executing);

		statement.next(100);
		var second = statement.getResult();
		Require.notNull(second);
		Assert.equals(75, second.data.length);
		Assert.isTrue(second.complete);
		Assert.isFalse(statement.executing);
		Assert.equals(248, second.data[74]._id);
		Assert.equals(2, results);
		Assert.equals(0, server.openCursors());
	}

	public function testAStatementBindsParametersAsBsonValues():Void {
		__start();
		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"insert": "sessions", "documents": [{"sid": :sid, "userId": :user, "expiresAt": :expires, "big": :big}]}';
		statement.parameters.sid = '"}]}, "drop": "sessions';
		statement.parameters.user = 42;
		statement.parameters.expires = BsonDateTime.parse("2026-09-30T00:00:00Z");
		statement.parameters.big = Int64.make(0x7FFFFFFF, -1);
		statement.execute();

		var result = statement.getResult();
		Require.notNull(result);
		Assert.equals(1, result.rowsAffected);

		var stored:Array<BsonDocument> = server.documents("app.sessions");
		Assert.equals(1, stored.length);
		Assert.equals('"}]}, "drop": "sessions', stored[0].get("sid"));
		Assert.equals(42, stored[0].get("userId"));
		Assert.isTrue(Std.isOfType(stored[0].get("expiresAt"), Date) || Std.isOfType(stored[0].get("expiresAt"), BsonDateTime), "a BSON date");
		Assert.equals("9223372036854775807", Int64.toStr((stored[0].get("big") : BsonInt64).value));
		Assert.equals(0, server.commands("drop").length);
	}

	public function testAParameterSetToNullIsBoundAsNull():Void {
		// A parameter set to null was refused as "no parameter named email",
		// though it was there: Extended JSON was asked for its value alone, and
		// null meant absent. It is a BSON null now; one never set is still
		// refused.
		__start();
		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"insert": "users", "documents": [{"name": :name, "email": :email}]}';
		statement.parameters.name = "bob";
		statement.parameters.email = null;
		statement.execute();

		var stored:Array<BsonDocument> = server.documents("app.users");
		Assert.equals(1, stored.length);
		if (stored.length == 1) {
			Assert.equals("bob", stored[0].get("name"));
			Assert.isTrue(stored[0].keys().indexOf("email") >= 0, "the field was left out");
			Assert.isNull(stored[0].get("email"));
		}

		statement.text = '{"find": "users", "filter": {"email": :unset}}';
		Assert.raises(() -> statement.execute(), crossbyte.errors.SQLError);

		// And through request(), whose parameters are a Map.
		var cursor = connection.request('{"find": "users", "filter": {"email": :email}}', ["email" => null]);
		Assert.equals(1, [for (document in cursor) document].length);
	}

	public function testAFailedStatementReachesItsListenersWithTheServersCode():Void {
		__start();
		server.replyNext("find", FakeMongoServer.__error(13, "Unauthorized", "not authorized on app to execute command"));

		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"find": "secrets"}';
		var caught:crossbyte.errors.SQLError = null;
		statement.addEventListener(SQLErrorEvent.ERROR, event -> caught = event.error);

		// Thrown as well as dispatched, as MySQL's statements do: a caller
		// not listening read a refused command as one that had run.
		Assert.raises(() -> statement.execute(), MongoError);

		Require.notNull(caught);
		Assert.isTrue(Std.isOfType(caught, MongoError));
		Assert.equals(13, (cast caught : MongoError).errorID);
		Assert.isTrue(caught.details().indexOf("not authorized") >= 0);
		Assert.isFalse(statement.executing);

		// Malformed text reaches the listener too, as text.
		statement.text = '{"find": ';
		caught = null;
		Assert.raises(() -> statement.execute(), crossbyte.errors.SQLError);
		Require.notNull(caught);
		Assert.isTrue(Std.isOfType(caught.details(), String));
	}

	/**
		Pages read ahead of `getResult()` say complete only for the last. Each
		said `!executing` as it was taken, so once the last page had been read
		every page still waiting said it was the last.
	**/
	public function testOnlyTheLastPageReadAheadIsComplete():Void {
		__start();
		server.seed("app.counted", [for (i in 1...6) new BsonDocument().add("_id", i)]);

		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.text = '{"find": "counted", "sort": {"_id": 1}}';
		statement.execute(2);
		while (statement.executing) {
			statement.next(2);
		}

		var pages:Array<String> = [];
		var page = statement.getResult();
		while (page != null) {
			pages.push([for (row in page.data) Std.string(Reflect.field(row, "_id"))].join(",") + (page.complete ? "+" : ""));
			page = statement.getResult();
		}
		Assert.equals("1,2 3,4 5+", pages.join(" "));
	}

	public function testRepliesAreAnonymousObjectsCarryingTheirSequences():Void {
		// The connection decodes every reply into anonymous objects, never
		// into BsonDocuments: the branches MongoWire and MongoStatement kept
		// for one were never taken, and are gone.
		__start();
		var reply:Dynamic = connection.runCommand({ping: 1});
		Assert.isFalse(Std.isOfType(reply, BsonDocument));
		Assert.isTrue(BsonWriter.isPlainObject(reply));

		// A reply with a document sequence beside its body: the sequence is
		// an array field of the body, its documents plain too.
		var next:Int = @:privateAccess connection.__wire.__requestId + 1;
		var writer:BsonWriter = new BsonWriter();
		writer.int32(0);
		writer.int32(5);
		writer.int32(next);
		writer.int32(2013);
		writer.int32(0);
		writer.byte(0);
		writer.document(new BsonDocument().add("ok", 1));
		writer.byte(1);
		var sequence:Int = writer.length;
		writer.int32(0);
		writer.cstring("items");
		writer.document(new BsonDocument().add("n", 1));
		writer.document(new BsonDocument().add("n", 2));
		writer.patchInt32(sequence, writer.length - sequence);
		writer.patchInt32(0, writer.length);
		server.rawNext("ping", writer.toBytes());

		var carried:Dynamic = connection.runCommand({ping: 1});
		Assert.isTrue(BsonWriter.isPlainObject(carried));
		var items:Array<Dynamic> = carried.items;
		Require.notNull(items);
		Assert.equals(2, items.length);
		Assert.equals(2, items[1].n);
		Assert.isTrue(BsonWriter.isPlainObject(items[0]));

		// A statement's one row for a command with no cursor is that reply,
		// made an instance of itemClass like any document.
		var statement = new MongoStatement();
		statement.sqlConnection = connection;
		statement.itemClass = PingReply;
		statement.text = '{"ping": 1}';
		statement.execute();
		var row:Dynamic = Require.notNull(statement.getResult()).data[0];
		Assert.isTrue(Std.isOfType(row, PingReply));
		Assert.equals(1, (row : PingReply).ok);
	}

	private function __start(?config:MongoConfig):Void {
		server.start();
		var cfg:MongoConfig = config == null ? {} : config;
		cfg.host = "127.0.0.1";
		cfg.port = server.port;
		cfg.database = "app";
		connection = new MongoConnection();
		connection.open(cfg);
	}

	private static function __person(id:Int, last:String, first:String, age:Int):BsonDocument {
		return new BsonDocument().add("_id", id).add("last", last).add("first", first).add("age", age);
	}
}

/** A ping's reply, as a statement's itemClass. **/
class PingReply {
	public var ok:Dynamic;

	public function new() {}
}
#end
