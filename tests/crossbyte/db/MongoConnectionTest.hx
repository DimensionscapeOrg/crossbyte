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

	It is supported everywhere, not only on php. And on the jvm a failure
	path must pass text, not the exception itself, where `IOError` and
	`SQLError` take a `String`: a ClassCastException there would escape the
	statement's catch, leave its listeners unrun, and lose what had
	actually gone wrong.
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

	public function testAServerThatNeverAnswersFailsTheOpenAtConnectTimeout():Void {
		// connectTimeout bounds the connect alone, and the hello and the login
		// then wait on socketTimeout, which is 0, no limit, by default (and on
		// the interpreter on nothing at all), so a server that accepted and
		// never answered must still not hold open() for good.
		var listener:sys.net.Socket = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(4);
		var port:Int = listener.host().port;
		var connection:MongoConnection = new MongoConnection();
		var error:Dynamic = null;
		var started:Float = haxe.Timer.stamp();

		try {
			// socketTimeout bounds the wait where it applies, so a failure here
			// is a slow one rather than a suite that never ends.
			connection.open({host: "127.0.0.1", port: port, connectTimeout: 0.5, socketTimeout: 8});
		} catch (e:Dynamic) {
			error = e;
		}

		var took:Float = haxe.Timer.stamp() - started;
		listener.close();

		Require.notNull(error);
		var failure:IOError = Std.downcast(error, IOError);
		Require.notNull(failure, "not an IOError: " + Std.string(error));
		Assert.isTrue(took < 3.0, 'open() gave up after $took s, of a 0.5 s connectTimeout');
		Assert.isTrue(failure.message.indexOf("0.5") >= 0, "the error does not say what ran out: " + failure.message);
		Assert.isFalse(connection.connected);
	}

	#if !eval
	public function testAConnectNobodyAnswersFailsAtConnectTimeout():Void {
		// The connect itself has no limit where the system applies no send
		// timeout to it (Windows natively, and on the jvm for TLS: 21 s to a
		// host that drops the SYN). Here, a listener that never accepts with its
		// one slot taken: the next SYN goes unanswered, on Linux for good and on
		// Windows until it refuses a couple of seconds later. The interpreter
		// connects with no limit at all (see MongoConfig.connectTimeout).
		#if hl
		if (crossbyte.sys.System.isWindows) {
			// Nor does HashLink on Windows, which applies no send timeout to
			// a connect, as connectTimeout says.
			Assert.pass();
			return;
		}
		#end
		var listener:sys.net.Socket = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(0);
		var port:Int = listener.host().port;
		var filler:sys.net.Socket = new sys.net.Socket();
		filler.setTimeout(2.0);

		try {
			filler.connect(new sys.net.Host("127.0.0.1"), port);
		} catch (_:Dynamic) {}

		var connection:MongoConnection = new MongoConnection();
		var error:Dynamic = null;
		var started:Float = haxe.Timer.stamp();

		try {
			connection.open({host: "127.0.0.1", port: port, connectTimeout: 0.4});
		} catch (e:Dynamic) {
			error = e;
		}

		var took:Float = haxe.Timer.stamp() - started;
		filler.close();
		listener.close();

		Require.notNull(error);
		Assert.isTrue(took < 1.5, 'the connect was not bounded: $took s, of a 0.4 s connectTimeout');
	}
	#end

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

			// Reported both ways, as every statement does: to the listener, and
			// thrown, as the same error, and as text, never as the native exception
			// it began as.
			var thrown:Dynamic = null;
			try {
				statement.execute();
			} catch (e:Dynamic) {
				thrown = e;
			}

			Require.notNull(caught);
			Assert.equals(caught, thrown, "what was thrown and what was dispatched differ");
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
