package crossbyte.db.mongodb;

#if (sys && !js)
import crossbyte.db.mongodb.FakeMongoServer.ReceivedCommand;
import crossbyte.db.AsyncDatabase;
import crossbyte.db.ConnectionPool;
import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.test.Require;
import haxe.Int64;
import utest.Assert;

/**
	Transactions on a connection's session, and the pool that has to end
	the ones a borrower leaves open.

	`inTransaction` always read false and `lastInsertRowID` always 0,
	whatever had happened; a pool trusting the first would hand the next
	borrower a transaction the last one left.
**/
class MongoTransactionTest extends utest.Test {
	private var server:FakeMongoServer;
	private var connection:MongoConnection;

	public function setup():Void {
		server = new FakeMongoServer();
		server.setName = "rs0";
		connection = null;
	}

	public function teardown():Void {
		if (connection != null) {
			try connection.close() catch (_:Dynamic) {}
		}

		server.stop();
	}

	public function testATransactionCarriesItsSessionAndStartsOnce():Void {
		__start();
		var events:Array<String> = [];

		for (type in [SQLEvent.BEGIN, SQLEvent.COMMIT]) {
			connection.addEventListener(type, e -> events.push(e.type));
		}

		connection.begin();
		Assert.isTrue(connection.inTransaction);
		connection.insert("accounts", [{_id: 1, balance: 100}]);
		connection.update("accounts", {_id: 1}, {"$inc": {balance: -25}});
		Assert.equals(1, server.openTransactions());
		connection.commit();

		Assert.isFalse(connection.inTransaction);
		Assert.same([SQLEvent.BEGIN, SQLEvent.COMMIT], events);
		Assert.equals(0, server.openTransactions());
		Assert.equals(75, server.documents("app.accounts")[0].get("balance"));

		var insert:BsonDocument = server.commands("insert")[0].body;
		var update:BsonDocument = server.commands("update")[0].body;
		var commit:BsonDocument = server.commands("commitTransaction")[0].body;

		// The first statement starts it; each carries the session and number.
		Assert.equals(true, insert.get("startTransaction"));
		Assert.isFalse(update.exists("startTransaction"));

		for (body in [insert, update, commit]) {
			Assert.equals(false, body.get("autocommit"));
			Assert.isTrue(Std.isOfType(body.get("txnNumber"), BsonInt64), "txnNumber is an int64");
			Assert.equals(BsonBinary.UUID, ((body.get("lsid") : BsonDocument).get("id") : BsonBinary).subtype);
		}

		Assert.equals(__session(insert), __session(commit));
		Assert.equals("admin", commit.get("$db"));
	}

	public function testRollbackUndoesAndTheNextTransactionHasTheNextNumber():Void {
		__start();
		connection.insert("accounts", [{_id: 1, balance: 100}]);

		connection.begin();
		connection.update("accounts", {_id: 1}, {"$set": {balance: 0}});
		connection.rollback();
		Assert.isFalse(connection.inTransaction);
		Assert.equals(100, server.documents("app.accounts")[0].get("balance"));

		connection.begin();
		connection.update("accounts", {_id: 1}, {"$set": {balance: 1}});
		connection.commit();

		var numbers:Array<String> = [for (c in server.commands("update")) (c.body.get("txnNumber") : BsonInt64).toString()];
		Assert.same(["1", "2"], numbers);
		Assert.equals(1, server.commands("abortTransaction").length);
	}

	public function testAnEmptyTransactionSendsNothing():Void {
		__start();
		connection.begin();
		connection.commit();
		connection.begin();
		connection.rollback();
		Assert.equals(0, server.commands("commitTransaction").length);
		Assert.equals(0, server.commands("abortTransaction").length);
		Assert.isFalse(connection.inTransaction);
	}

	public function testAStandaloneServerCannotBeginOne():Void {
		server.setName = null;
		__start();
		var errors:Int = 0;
		connection.addEventListener(SQLErrorEvent.ERROR, _ -> errors++);

		Assert.raises(() -> connection.begin(), SQLError);
		Assert.isFalse(connection.inTransaction);
		Assert.equals(1, errors);
	}

	public function testAFailedStatementLeavesTheTransactionToBeRolledBack():Void {
		__start();
		connection.createIndex("users", {email: 1}, {unique: true});
		connection.insert("users", [{email: "a@example.com"}]);

		connection.begin();
		connection.insert("users", [{email: "b@example.com"}]);
		Assert.raises(() -> connection.insert("users", [{email: "a@example.com"}]), MongoError);

		// The server has aborted it; it is still open here until ended, which
		// is what makes the pool end it.
		Assert.isTrue(connection.inTransaction);
		Assert.equals(0, server.openTransactions());

		// And ending it succeeds: NoSuchTransaction means over, as asked.
		connection.rollback();
		Assert.isFalse(connection.inTransaction);
		Assert.equals(1, server.documents("app.users").length);
	}

	public function testAFailedCommitSaysWhyAndKeepsTheTransactionToEnd():Void {
		__start();
		connection.begin();
		connection.insert("things", [{x: 1}]);
		server.replyNext("commitTransaction", FakeMongoServer.__error(251, "NoSuchTransaction", "Transaction 1 has been aborted.", [MongoError.TRANSIENT_TRANSACTION_ERROR]));

		var error:MongoError = null;

		try {
			connection.commit();
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.isTrue(error.hasErrorLabel(MongoError.TRANSIENT_TRANSACTION_ERROR));
		Assert.isTrue(connection.inTransaction);
		connection.rollback();
		Assert.isFalse(connection.inTransaction);
	}

	public function testWriteConcernGoesOnTheCommitAlone():Void {
		__start({writeConcern: {w: "majority"}});
		connection.begin();
		connection.insert("things", [{x: 1}]);
		connection.commit();

		Assert.isFalse(server.commands("insert")[0].body.exists("writeConcern"));
		Assert.equals("majority", (server.commands("commitTransaction")[0].body.get("writeConcern") : BsonDocument).get("w"));
	}

	public function testAPoolRollsBackATransactionABorrowerLeftOpen():Void {
		server.start();
		var port:Int = server.port;
		var pool = new ConnectionPool<MongoConnection>({
			factory: () -> {
				var c = new MongoConnection();
				c.open({host: "127.0.0.1", port: port, database: "app"});
				c;
			},
			close: c -> c.close(),
			validate: c -> c.ping(),
			maxSize: 1
		});

		var first = pool.acquire();
		first.begin();
		first.insert("orders", [{item: "left open"}]);
		Assert.equals(1, server.openTransactions());
		// Released without commit or rollback: a bug in the borrower, which
		// the pool mends before anyone else can inherit the transaction.
		pool.release(first);

		Assert.equals(0, server.openTransactions());
		Assert.equals(1, server.commands("abortTransaction").length);
		Assert.equals(0, server.documents("app.orders").length);

		var second = pool.acquire();
		Assert.equals(first, second);
		Assert.isFalse(second.inTransaction);
		pool.release(second);
		pool.close();
	}

	public function testAsyncDatabaseRunsTheWorkOnAWorker():Void {
		server.start();
		var port:Int = server.port;
		var pool = new ConnectionPool<MongoConnection>({
			factory: () -> {
				var c = new MongoConnection();
				c.open({host: "127.0.0.1", port: port, database: "app"});
				c;
			},
			close: c -> c.close(),
			maxSize: 2
		});
		var db = AsyncDatabase.of(pool);
		var inserted:Dynamic = null;
		var found:Dynamic = null;
		var failed:Dynamic = null;

		db.submit(c -> c.insertOne("sessions", {userId: 42}))
			.onComplete(id -> inserted = id)
			.onError(e -> failed = e);

		crossbyte.http.HTTPTestSupport.pumpUntil(() -> inserted != null || failed != null, 10.0);
		Require.notNull(inserted);
		Assert.isTrue(Std.isOfType(inserted, ObjectId));

		var id:ObjectId = inserted;
		db.transaction(c -> c.begin(), c -> c.commit(), c -> c.rollback(), c -> c.findOne("sessions", {_id: id}))
			.onComplete(doc -> found = doc)
			.onError(e -> failed = e);

		crossbyte.http.HTTPTestSupport.pumpUntil(() -> found != null || failed != null, 10.0);
		Assert.isNull(failed);
		Require.notNull(found);
		Assert.equals(42, found.userId);

		db.shutdown();
	}

	public function testClosingEndsTheSession():Void {
		__start();
		connection.begin();
		connection.insert("things", [{x: 1}]);
		var lsid:String = __session(server.commands("insert")[0].body);
		connection.close();
		connection = null;

		// endSessions goes without a reply; wait for the server to see it.
		var deadline:Float = haxe.Timer.stamp() + 5.0;

		while (server.commands("endSessions").length == 0 && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}

		var end:ReceivedCommand = server.commands("endSessions")[0];
		Require.notNull(end);
		var ids:Array<Dynamic> = end.body.get("endSessions");
		Assert.equals(lsid, ((ids[0] : BsonDocument).get("id") : BsonBinary).data.toHex());
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

	private static function __session(body:BsonDocument):String {
		return ((body.get("lsid") : BsonDocument).get("id") : BsonBinary).data.toHex();
	}
}
#end
