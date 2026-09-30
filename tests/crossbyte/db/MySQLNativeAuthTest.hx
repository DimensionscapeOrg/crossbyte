package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLSSLMode;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.errors.IOError;
import crossbyte.net.TLSTestFixture;
import crossbyte.test.Require;
import utest.Assert;

/**
 * Logging in to a MySQL 8 server: `caching_sha2_password`, the auth switch,
 * the utf8mb4_0900 collation, and TLS. The client spoke only
 * `mysql_native_password`, which MySQL 8.4 disables by default and 9.0
 * removes, took an auth switch for a broken packet, threw "Unsupported
 * charset : #255" on every escape against a default MySQL 8 server, and had
 * no TLS. Against `fakemysql/FakeMySQLServer`, which checks the scramble for
 * each plugin, runs TLS through hxcpp's own mbedTLS server side, and
 * decrypts an RSA-encrypted password with `openssl`.
 */
@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLNativeAuthTest extends utest.Test {
	private var __server:FakeMySQLServer;

	public function setup():Void {
		__server = new FakeMySQLServer();
	}

	public function teardown():Void {
		if (__server != null) {
			__server.stop();
			__server = null;
		}
	}

	public function testADefaultMySQL8GreetingCanBeEscapedFor():Void {
		__server.charset = FakeMySQLServer.CHARSET_UTF8MB4_0900;
		__server.plugin = "caching_sha2_password";
		__server.start();
		var connection:MySQLConnection = __open(__config());

		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT * FROM users WHERE email = :email";
		statement.parameters.email = "zoe@example.com";
		statement.execute();

		Assert.equals("SELECT * FROM users WHERE email = 'zoe@example.com'", __server.lastQuery());
		connection.close();
	}

	public function testCachingSha2PasswordFastAuthentication():Void {
		__server.plugin = "caching_sha2_password";
		__server.password = "s3cret pass";
		__server.start();
		var connection:MySQLConnection = __open(__config("s3cret pass"));

		var handshake = __first("handshake");
		Assert.equals("caching_sha2_password", handshake.plugin);
		Assert.equals(32, handshake.authResponse.length);
		Assert.equals("caching_sha2_password", connection.__native.authPlugin);
		Assert.isTrue(connection.ping());
		connection.close();
	}

	public function testAWrongPasswordIsRefused():Void {
		__server.plugin = "caching_sha2_password";
		__server.password = "right";
		__server.start();

		var connection:MySQLConnection = new MySQLConnection();
		var message:String = "";

		try {
			connection.open(__config("wrong"));
		} catch (e:IOError) {
			message = e.message;
		}

		Assert.isTrue(message.indexOf("Access denied") >= 0, message);
		Assert.equals(1, __server.eventsOf("auth denied").length);
	}

	public function testAnAuthSwitchIsFollowed():Void {
		// The greeting names caching_sha2_password; the account is on
		// mysql_native_password, so the server switches the client, with a
		// fresh nonce. That was "Invalid packet error".
		__server.plugin = "caching_sha2_password";
		__server.switchTo = "mysql_native_password";
		__server.password = "secret";
		__server.start();
		var connection:MySQLConnection = __open(__config("secret"));

		Assert.equals(1, __server.eventsOf("auth switch response").length);
		Assert.equals("mysql_native_password", connection.__native.authPlugin);
		connection.close();

		// And the other way.
		__server.stop();
		__server = new FakeMySQLServer();
		__server.plugin = "mysql_native_password";
		__server.switchTo = "caching_sha2_password";
		__server.password = "secret";
		__server.start();
		connection = __open(__config("secret"));
		Assert.equals("caching_sha2_password", connection.__native.authPlugin);
		connection.close();
	}

	public function testFullAuthenticationWithoutTlsNeedsAKey():Void {
		// The server has no cached hash and needs the password itself. Over a
		// connection without TLS it must not go in the clear, and the key to
		// encrypt it with must not be taken from whoever answers unless asked.
		__server.plugin = "caching_sha2_password";
		__server.password = "secret";
		__server.cachedAccount = false;
		__server.start();

		var config:MySQLConfig = __config("secret");
		config.sslMode = MySQLSSLMode.DISABLED;
		var message:String = "";

		try {
			new MySQLConnection().open(config);
		} catch (e:IOError) {
			message = e.message;
		}

		Assert.isTrue(message.indexOf("serverPublicKey") >= 0, message);
		Assert.equals(0, __server.eventsOf("full auth").length, "the password was sent");
	}

	public function testFullAuthenticationWithARetrievedKey():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass("no openssl to make a key with");
			return;
		}

		__server.plugin = "caching_sha2_password";
		__server.password = "secret";
		__server.cachedAccount = false;
		__server.tlsKeyPath = fixture.keyPath;
		__server.start();

		var config:MySQLConfig = __config("secret");
		config.sslMode = MySQLSSLMode.DISABLED;
		config.allowPublicKeyRetrieval = true;
		var connection:MySQLConnection = __open(config);

		Assert.equals(1, __server.eventsOf("public key request").length);
		var full = __first("full auth");
		Assert.equals("rsa", full.text);
		// RSA-2048: the password went as one 256-byte block the server
		// decrypted and checked.
		Assert.equals(256, full.authResponse.length);
		Assert.isFalse(connection.encrypted);
		connection.close();
	}

	public function testFullAuthenticationWithAGivenKey():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass("no openssl to make a key with");
			return;
		}

		__server.plugin = "caching_sha2_password";
		__server.password = "secret";
		__server.cachedAccount = false;
		__server.tlsKeyPath = fixture.keyPath;
		__server.start();

		var config:MySQLConfig = __config("secret");
		config.sslMode = MySQLSSLMode.DISABLED;
		config.serverPublicKey = __server.__publicKeyPem();
		var connection:MySQLConnection = __open(config);

		Assert.equals(0, __server.eventsOf("public key request").length);
		Assert.equals("rsa", __first("full auth").text);
		connection.close();
	}

	public function testFullAuthenticationOverTls():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass("no openssl to make a certificate with");
			return;
		}

		__server.plugin = "caching_sha2_password";
		__server.password = "secret";
		__server.cachedAccount = false;
		__server.tlsCertificatePath = fixture.certificatePath;
		__server.tlsKeyPath = fixture.keyPath;
		__server.start();

		var config:MySQLConfig = __config("secret");
		config.sslMode = MySQLSSLMode.REQUIRED;
		var connection:MySQLConnection = __open(config);

		Assert.isTrue(connection.encrypted);
		Assert.equals(1, __server.eventsOf("tls established").length);
		Assert.equals("tls", __first("full auth").text);

		// And statements go over it.
		connection.request("UPDATE users SET name = 'Zoë' WHERE id = 12");
		Assert.equals("UPDATE users SET name = 'Zoë' WHERE id = 12", __server.lastQuery());
		connection.close();
	}

	public function testTlsIsUsedWhenOfferedByDefault():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass("no openssl to make a certificate with");
			return;
		}

		__server.tlsCertificatePath = fixture.certificatePath;
		__server.tlsKeyPath = fixture.keyPath;
		__server.start();

		var connection:MySQLConnection = __open(__config());
		Assert.isTrue(connection.encrypted);
		connection.close();
	}

	public function testRequiredTlsFailsAgainstAServerWithout():Void {
		__server.start();
		var config:MySQLConfig = __config();
		config.sslMode = MySQLSSLMode.REQUIRED;
		var message:String = "";

		try {
			new MySQLConnection().open(config);
		} catch (e:IOError) {
			message = e.message;
		}

		Assert.isTrue(message.indexOf("does not support TLS") >= 0, message);
		Assert.equals(0, __server.eventsOf("handshake").length, "the credentials went out anyway");
	}

	public function testVerifyingTheCertificate():Void {
		var fixture = TLSTestFixture.trusted();
		var other = TLSTestFixture.selfSignedFor("mysql.other.example");
		if (fixture == null || other == null) {
			Assert.pass("no openssl to make a certificate with");
			return;
		}

		__server.tlsCertificatePath = fixture.certificatePath;
		__server.tlsKeyPath = fixture.keyPath;
		__server.start();

		// Signed by the CA given (the certificate is its own CA), and naming
		// 127.0.0.1.
		var config:MySQLConfig = __config();
		config.sslMode = MySQLSSLMode.VERIFY_IDENTITY;
		config.sslCa = fixture.certificatePath;
		var connection:MySQLConnection = __open(config);
		Assert.isTrue(connection.encrypted);
		connection.close();

		// A CA that did not sign it.
		config.sslMode = MySQLSSLMode.VERIFY_CA;
		config.sslCa = other.certificatePath;
		var message:String = "";

		try {
			new MySQLConnection().open(config);
		} catch (e:IOError) {
			message = e.message;
		}

		Assert.isTrue(message.indexOf("certificate") >= 0, message);
	}

	public function testAnUnknownSslModeIsRefused():Void {
		Assert.raises(() -> MySQLSSLMode.ofString("verify-everything"), crossbyte.errors.ArgumentError);
		var parsed:MySQLSSLMode = "verify-identity";
		Assert.equals("VERIFY_IDENTITY", (parsed : String));
	}

	/** The first event of a kind, stopping the test if there is none. **/
	private function __first(kind:String):FakeMySQLEvent {
		var found = __server.eventsOf(kind);
		return Require.notNull(found.length == 0 ? null : found[0]);
	}

	private function __open(config:MySQLConfig):MySQLConnection {
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(config);
		return connection;
	}

	private function __config(password:String = "secret"):MySQLConfig {
		return {
			host: "127.0.0.1",
			port: __server.port,
			user: "app",
			password: password,
			database: "app"
		};
	}
}
#end
