package crossbyte.db.mongodb;

#if (sys && !js)
import crossbyte.db.mongodb.FakeMongoServer.ReceivedCommand;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	The connection itself against `FakeMongoServer`: the hello, SCRAM, and a
	server that misbehaves.

	MongoDB was reachable from no CrossByte target before this, its one
	backend was PHP's extension, and that stopped compiling, so opening a
	connection at all is the first thing held here, with the API the old
	class already had.
**/
class MongoWireTest extends utest.Test {
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

	public function testOpensAndPingsAServer():Void {
		server.start();
		// Only what MongoConnection already offered: open with a host, a port
		// and a database; connected; ping; close.
		connection = new MongoConnection();
		connection.open({host: "127.0.0.1", port: server.port, database: "app"});

		Assert.isTrue(connection.connected);
		Assert.isTrue(connection.ping());
		Assert.isFalse(connection.inTransaction);

		connection.close();
		Assert.isFalse(connection.connected);
		Assert.isFalse(connection.ping());
	}

	public function testTheHelloSaysWhoIsAsking():Void {
		server.start();
		__open({appName: "billing"});

		var hello:ReceivedCommand = server.commands("hello")[0];
		Require.notNull(hello);
		Assert.equals("hello", hello.body.keyAt(0));
		Assert.equals("admin", hello.body.get("$db"));
		var client:BsonDocument = hello.body.get("client");
		Assert.equals("crossbyte", (client.get("driver") : BsonDocument).get("name"));
		Assert.equals("billing", (client.get("application") : BsonDocument).get("name"));
		Assert.notNull((client.get("os") : BsonDocument).get("type"));
		// Compression is never offered, so it is never agreed.
		Assert.same([], hello.body.get("compression"));
		Assert.equals(21, Reflect.field(connection.serverInfo, "maxWireVersion"));
	}

	public function testAServerOlderThanHelloIsAskedIsMaster():Void {
		server.legacyHello = true;
		server.start();
		__open();

		Assert.equals(1, server.commands("hello").length);
		Assert.equals(1, server.commands("isMaster").length);
		Assert.isTrue(connection.ping());
	}

	public function testScramSha256RidesOnTheHello():Void {
		server.requireAuth = true;
		server.addUser("app", "p@ss:w/rd");
		server.start();
		__open({username: "app", password: "p@ss:w/rd"});

		// The first step went with the hello, so one round trip finished it.
		var hello:BsonDocument = server.commands("hello")[0].body;
		var speculative:BsonDocument = hello.get("speculativeAuthenticate");
		Require.notNull(speculative);
		Assert.equals("SCRAM-SHA-256", speculative.get("mechanism"));
		Assert.equals(0, server.commands("saslStart").length);
		Assert.equals(1, server.commands("saslContinue").length);
		Assert.equals("admin.app", hello.get("saslSupportedMechs"));

		// And the server takes commands from it.
		Assert.equals(0, connection.count("things"));
	}

	public function testScramSha256WhenTheServerDoesNotSpeculate():Void {
		server.requireAuth = true;
		server.speculativeAuth = false;
		server.addUser("app", "secret");
		server.start();
		__open({username: "app", password: "secret"});

		var start:BsonDocument = server.commands("saslStart")[0].body;
		Assert.equals("SCRAM-SHA-256", start.get("mechanism"));
		Assert.equals("admin", start.get("$db"));
		Assert.equals(1, server.commands("saslContinue").length);
		Assert.equals(0, connection.count("things"));
	}

	public function testScramSha1ForAUserWithoutSha256():Void {
		server.requireAuth = true;
		server.addUser("old", "secret", ["SCRAM-SHA-1"]);
		server.start();
		__open({username: "old", password: "secret"});

		// The speculative SHA-256 start was not taken; the user's mechanism list
		// said SHA-1.
		Assert.equals("SCRAM-SHA-1", server.commands("saslStart")[0].body.get("mechanism"));
		Assert.equals(0, connection.count("things"));
	}

	public function testAServerThatSkipsNothingGetsItsEmptyLastTurn():Void {
		server.requireAuth = true;
		server.skipEmptyExchange = false;
		server.addUser("app", "secret");
		server.start();
		__open({username: "app", password: "secret", authSource: "admin", database: "app"});

		Assert.equals(2, server.commands("saslContinue").length);
		Assert.equals(0, connection.count("things"));
	}

	public function testPlainSignsInAgainstExternal():Void {
		server.requireAuth = true;
		server.addUser("ldapuser", "ldap-secret", ["PLAIN"], "$external");
		server.start();
		__open({username: "ldapuser", password: "ldap-secret", authMechanism: "PLAIN"});

		var start:BsonDocument = server.commands("saslStart")[0].body;
		Assert.equals("PLAIN", start.get("mechanism"));
		// A user outside MongoDB is checked in $external, whatever database
		// the connection uses.
		Assert.equals("$external", start.get("$db"));
		Assert.equals(0, connection.count("things"));
	}

	public function testAWrongPasswordIsAMongoErrorAndClosesTheConnection():Void {
		server.requireAuth = true;
		server.addUser("app", "right");
		server.start();

		connection = new MongoConnection();
		var error:MongoError = null;

		try {
			connection.open({host: "127.0.0.1", port: server.port, username: "app", password: "wrong"});
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.AUTHENTICATION_FAILED, error.errorID);
		Assert.equals("AuthenticationFailed", error.codeName);
		Assert.isFalse(connection.connected);
	}

	public function testAServerThatCannotProveItKnowsThePasswordIsRefused():Void {
		server.requireAuth = true;
		server.speculativeAuth = false;
		server.addUser("app", "secret");
		// A server that answers the proof with "done" and a signature it made
		// up, what a man in the middle without the user's keys can send.
		server.replyNext("saslContinue", new BsonDocument()
			.add("conversationId", 1)
			.add("done", true)
			.add("payload", Bytes.ofString("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
			.add("ok", 1));
		server.start();

		connection = new MongoConnection();
		Assert.raises(() -> connection.open({host: "127.0.0.1", port: server.port, username: "app", password: "secret"}), IOError);
		Assert.isFalse(connection.connected);
	}

	public function testAnUnauthenticatedCommandIsTheServersRefusal():Void {
		server.requireAuth = true;
		server.start();
		__open();

		var error:MongoError = null;

		try {
			connection.find("things").toArray();
		} catch (e:MongoError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MongoError.UNAUTHORIZED, error.errorID);
		// A refusal is not a broken connection.
		Assert.isTrue(connection.ping());
	}

	public function testALostConnectionIsAnIOErrorAndClosesIt():Void {
		server.start();
		__open();
		server.closeNext("find");

		Assert.raises(() -> connection.find("things"), IOError);
		Assert.isFalse(connection.connected);
		Assert.isFalse(connection.ping());
		// And later calls say so rather than writing to a dead socket.
		Assert.raises(() -> connection.count("things"), IOError);
	}

	public function testAHostileLengthIsRefusedBeforeAnythingIsAllocated():Void {
		server.start();
		__open();

		// A header claiming 2 GB. Read and trusted, it would make the client
		// reserve that much before reading a byte of it.
		var header:Bytes = Bytes.alloc(16);
		header.setInt32(0, 0x7FFFFFF0);
		header.setInt32(4, 1);
		header.setInt32(8, 1);
		header.setInt32(12, 2013);
		server.rawNext("find", header);

		var started:Float = haxe.Timer.stamp();
		Assert.raises(() -> connection.find("things"), IOError);
		Assert.isTrue(haxe.Timer.stamp() - started < 5.0);
		Assert.isFalse(connection.connected);
	}

	public function testAReplyToAnotherRequestIsRefused():Void {
		server.start();
		__open();

		var writer:BsonWriter = new BsonWriter();
		writer.int32(0);
		writer.int32(77);
		// Answers request 999999, which nothing sent.
		writer.int32(999999);
		writer.int32(2013);
		writer.int32(0);
		writer.byte(0);
		writer.document(new BsonDocument().add("ok", 1));
		writer.patchInt32(0, writer.length);
		server.rawNext("find", writer.toBytes());

		Assert.raises(() -> connection.find("things"), IOError);
		Assert.isFalse(connection.connected);
	}

	public function testRepliesCarryingAChecksumAreRead():Void {
		server.checksums = true;
		server.start();
		__open();
		connection.insert("things", [{n: 1}, {n: 2}]);
		Assert.equals(2, connection.count("things"));
	}

	public function testAServerTooOldForOpMsgIsRefused():Void {
		server.maxWireVersion = 5;
		server.start();

		connection = new MongoConnection();
		var error:IOError = null;

		try {
			connection.open({host: "127.0.0.1", port: server.port});
		} catch (e:IOError) {
			error = e;
		}

		Require.notNull(error);
		Assert.isTrue(error.message.indexOf("wire version 5") >= 0, error.message);
		Assert.isFalse(connection.connected);
	}

	public function testASecondaryIsFollowedToItsPrimary():Void {
		var primary = new FakeMongoServer();
		primary.setName = "rs0";
		primary.start();

		server.setName = "rs0";
		server.helloExtra = new BsonDocument()
			.add("isWritablePrimary", false)
			.add("ismaster", false)
			.add("secondary", true)
			.add("primary", '127.0.0.1:${primary.port}');
		server.start();

		try {
			connection = new MongoConnection();
			connection.open({uri: 'mongodb://127.0.0.1:${server.port}/app?replicaSet=rs0'});

			Assert.equals(1, primary.connections(), "the primary was not reached");
			connection.insert("things", [{n: 1}]);
			Assert.equals(1, primary.documents("app.things").length);
			Assert.equals(0, server.documents("app.things").length);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try connection.close() catch (_:Dynamic) {}
		connection = null;
		primary.stop();
	}

	public function testDirectConnectionTakesTheServerNamed():Void {
		server.setName = "rs0";
		server.helloExtra = new BsonDocument().add("isWritablePrimary", false).add("ismaster", false).add("secondary", true);
		server.start();
		__open({directConnection: true});
		Assert.isTrue(connection.ping());
	}

	public function testOpeningAnOpenConnectionIsRefusedAndAClosedOneReopens():Void {
		server.start();
		__open();
		Assert.raises(() -> connection.open({host: "127.0.0.1", port: server.port}), IllegalOperationError);

		connection.close();
		connection.open({host: "127.0.0.1", port: server.port});
		Assert.isTrue(connection.ping());
		Assert.equals(2, server.connections());
	}

	// Not on eval, whose sys.ssl.Socket cannot listen, setCertificate is not
	// implemented there, so there is no server for its client to reach.
	#if !eval
	public function testTlsVerifiesTheServerAgainstTheAuthorityItIsGiven():Void {
		// A certificate for localhost and 127.0.0.1, made with the openssl CLI;
		// a machine without it has nothing to serve TLS with.
		var fixture = crossbyte.net.TLSTestFixture.trusted();

		if (fixture == null) {
			Assert.pass();
			return;
		}

		server.tls = {certificatePath: fixture.certificatePath, keyPath: fixture.keyPath};
		server.requireAuth = true;
		server.addUser("app", "secret");
		server.start();

		// Told to trust the certificate's own authority: connects, signs in,
		// and works, all of it over TLS.
		connection = new MongoConnection();
		connection.open({uri: 'mongodb://app:secret@127.0.0.1:${server.port}/app?tls=true&authSource=admin', tlsCAFile: fixture.certificatePath});
		connection.insert("things", [{x: 1}]);
		Assert.equals(1, connection.count("things"));
		connection.close();
		connection = null;

		// Not told to: the system's authorities have never heard of it, so the
		// server is refused before a credential is sent.
		var refused = new MongoConnection();
		Assert.raises(() -> refused.open({host: "127.0.0.1", port: server.port, tls: true, username: "app", password: "secret"}), IOError);
		Assert.isFalse(refused.connected);

		// And told not to check, it connects anyway, which is what the
		// option's name warns of. Not on neko, whose sys.ssl.Socket verifies
		// the certificate whatever verifyCert says: it fails closed there.
		#if !neko
		var careless = new MongoConnection();
		careless.open({host: "127.0.0.1", port: server.port, tls: true, tlsAllowInvalidCertificates: true, username: "app", password: "secret"});
		Assert.isTrue(careless.ping());
		careless.close();
		#end
	}

	public function testX509SignsInWithTheClientCertificate():Void {
		var fixture = crossbyte.net.TLSTestFixture.trusted();

		if (fixture == null) {
			Assert.pass();
			return;
		}

		// The certificate and its key in one file, as tlsCertificateKeyFile
		// takes them, beside the fixture's own.
		var combined:String = haxe.io.Path.join([haxe.io.Path.directory(fixture.certificatePath), "client-" + Std.random(0x7FFFFFF) + ".pem"]);
		sys.io.File.saveContent(combined, sys.io.File.getContent(fixture.certificatePath) + "\n" + sys.io.File.getContent(fixture.keyPath));

		server.tls = {certificatePath: fixture.certificatePath, keyPath: fixture.keyPath};
		server.requireAuth = true;
		server.start();

		try {
			connection = new MongoConnection();
			connection.open({
				host: "127.0.0.1",
				port: server.port,
				tls: true,
				tlsCAFile: fixture.certificatePath,
				tlsCertificateKeyFile: combined,
				authMechanism: "MONGODB-X509"
			});

			// Signed in by the hello itself, no separate authenticate.
			var hello:BsonDocument = server.commands("hello")[0].body;
			Assert.equals("MONGODB-X509", (hello.get("speculativeAuthenticate") : BsonDocument).get("mechanism"));
			Assert.equals(0, server.commands("authenticate").length);
			Assert.equals(0, connection.count("things"));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try sys.FileSystem.deleteFile(combined) catch (_:Dynamic) {}
	}
	#end

	public function testTheServerVersionIsAskedForOnce():Void {
		server.start();
		__open();
		Assert.equals("7.0.99-fake", connection.serverVersion);
		Assert.equals("7.0.99-fake", connection.serverVersion);
		Assert.equals(1, server.commands("buildInfo").length);
	}

	private function __open(?config:MongoConfig):Void {
		var cfg:MongoConfig = config == null ? {} : config;
		cfg.host = "127.0.0.1";
		cfg.port = server.port;
		connection = new MongoConnection();
		connection.open(cfg);
	}
}
#end
