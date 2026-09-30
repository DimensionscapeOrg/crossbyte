package crossbyte.db;

import crossbyte.db.mongodb.FakeMongoServer;
import crossbyte.db.mongodb.MongoConnection;
import crossbyte.db.mongodb.MongoStatement;
import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.test.Require;
import utest.Assert;

/**
	What `MongoConnection` promises before and around the wire: that it is
	available, and that its failures arrive as errors carrying text.

	It was unsupported everywhere but php, where it no longer compiled. And
	on the jvm every failure path passed the exception itself where
	`IOError` and `SQLError` take a `String` -- a ClassCastException there,
	which escaped the statement's catch, left its listeners unrun, and lost
	what had actually gone wrong.
**/
class MongoConnectionTest extends utest.Test {
	public function testSupportedWhereverThereAreBlockingSockets():Void {
		Assert.isTrue(MongoConnection.isSupported);
	}

	@:access(crossbyte.db.mongodb.MongoConnection)
	public function testAConfigWrittenAsAConnectionStringReadsBackTheSame():Void {
		// Credentials holding the characters that delimit a connection string,
		// and a plus, which form decoding would read as a space.
		var uri:String = new MongoConnection().__buildUri({host: "db.example.com", port: 27018, username: "ad@min:x", password: "p@ss:w/rd+%"});
		var settings = crossbyte.db.mongodb._internal.MongoUri.settings({uri: uri});

		Assert.equals("ad@min:x", settings.username);
		Assert.equals("p@ss:w/rd+%", settings.password);
		Assert.equals("db.example.com", settings.hosts[0].host);
		Assert.equals(27018, settings.hosts[0].port);
	}

	public function testAStatementNeedsAConnection():Void {
		var statement = new MongoStatement();
		Assert.isTrue(__throws(() -> statement.execute()));
	}

	public function testAnUnreachableServerIsAnIOErrorCarryingText():Void {
		// A port obtained and then released, rather than one assumed free.
		var probe = new sys.net.Socket();
		probe.bind(new sys.net.Host("127.0.0.1"), 0);
		probe.listen(1);
		var port:Int = probe.host().port;
		probe.close();

		var connection = new MongoConnection();
		var error:IOError = null;

		try {
			connection.open({host: "127.0.0.1", port: port, connectTimeout: 5});
		} catch (e:IOError) {
			error = e;
		}

		// On the jvm the refusal is a java.net.ConnectException; it has to
		// arrive as the message, not as itself.
		Require.notNull(error);
		Assert.isTrue(Std.isOfType(error.message, String));
		Assert.isTrue(error.message.indexOf('127.0.0.1:$port') >= 0, error.message);
		Assert.isFalse(connection.connected);
	}

	public function testAStatementWhoseConnectionFailsReachesItsListeners():Void {
		var server = new FakeMongoServer().start();

		try {
			var connection = new MongoConnection();
			connection.open({host: "127.0.0.1", port: server.port});
			server.closeNext("find");

			var statement = new MongoStatement();
			statement.sqlConnection = connection;
			statement.text = '{"find": "things"}';
			var caught:SQLError = null;
			statement.addEventListener(SQLErrorEvent.ERROR, event -> caught = event.error);

			// Nothing escapes execute: the failure is the listener's.
			statement.execute();

			Require.notNull(caught);
			Assert.isTrue(Std.isOfType(caught.details(), String));
			Assert.isTrue(caught.details().indexOf("closed the connection") >= 0, caught.details());
			Assert.isFalse(connection.connected);
		} catch (e:Dynamic) {
			Assert.fail("escaped: " + Std.string(e));
		}

		server.stop();
	}

	public function testATransactionThatCannotBeginIsAnSQLErrorCarryingText():Void {
		var server = new FakeMongoServer().start();
		var connection = new MongoConnection();

		try {
			connection.open({host: "127.0.0.1", port: server.port});
			var dispatched:SQLError = null;
			connection.addEventListener(SQLErrorEvent.ERROR, event -> dispatched = event.error);
			var thrown:SQLError = null;

			try {
				connection.begin();
			} catch (e:SQLError) {
				thrown = e;
			}

			Require.notNull(thrown);
			Assert.equals(thrown, dispatched);
			Assert.isTrue(thrown.details().indexOf("standalone") >= 0, thrown.details());
			Assert.isFalse(connection.inTransaction);
		} catch (e:Dynamic) {
			Assert.fail("escaped: " + Std.string(e));
		}

		try connection.close() catch (_:Dynamic) {}
		server.stop();
	}

	private static function __throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
