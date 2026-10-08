package crossbyte.db.mongodb;

import crossbyte.db.mongodb._internal.MongoUri;
import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	Connection strings, read as MongoDB's connection string specification lays
	them out, and the config fields over them.
**/
class MongoUriTest extends utest.Test {
	public function testCredentialsAreDecodedAndAPlusStaysAPlus():Void {
		// StringTools.urlDecode reads + as a space, as a form does, so a password
		// holding a plus would become another password.
		var s = MongoUri.settings({uri: "mongodb://ad%40min:p%40ss%3Aw%2Frd+x@db.example.com:27018/app?authSource=admin"});
		Assert.equals("ad@min", s.username);
		Assert.equals("p@ss:w/rd+x", s.password);
		Assert.equals("db.example.com", s.hosts[0].host);
		Assert.equals(27018, s.hosts[0].port);
		Assert.equals("app", s.database);
		Assert.equals("admin", s.effectiveAuthSource());
	}

	public function testSeveralHostsAndIpv6():Void {
		var s = MongoUri.settings({uri: "mongodb://a.example.com,[::1]:27019,10.0.0.5:27020/?replicaSet=rs0&directConnection=false"});
		Assert.equals(3, s.hosts.length);
		Assert.equals("a.example.com", s.hosts[0].host);
		Assert.equals(27017, s.hosts[0].port);
		Assert.equals("::1", s.hosts[1].host);
		Assert.equals(27019, s.hosts[1].port);
		Assert.equals(27020, s.hosts[2].port);
		Assert.equals("rs0", s.replicaSet);
		Assert.isFalse(s.directConnection);
	}

	public function testAuthSourceDefaultsAsTheDriversDo():Void {
		Assert.equals("app", MongoUri.settings({uri: "mongodb://u:p@h/app"}).effectiveAuthSource());
		Assert.equals("admin", MongoUri.settings({uri: "mongodb://u:p@h/"}).effectiveAuthSource());
		Assert.equals("admin", MongoUri.settings({host: "h", username: "u", password: "p"}).effectiveAuthSource());
		Assert.equals("app", MongoUri.settings({host: "h", database: "app", username: "u", password: "p"}).effectiveAuthSource());
		Assert.equals("$external", MongoUri.settings({uri: "mongodb://u@h/?authMechanism=PLAIN", password: "p"}).effectiveAuthSource());
	}

	public function testOptionsAreReadWithoutRegardToCase():Void {
		var s = MongoUri.settings({
			uri: "mongodb://u:p@h/?TLS=true&tlsCAFile=%2Fetc%2Fca.pem&tlsAllowInvalidCertificates=true&connectTimeoutMS=2500&socketTimeoutMS=0&appName=billing&w=majority&wtimeoutMS=500&journal=true&authMechanism=scram-sha-256"
		});
		Assert.isTrue(s.tls);
		Assert.equals("/etc/ca.pem", s.tlsCAFile);
		Assert.isTrue(s.tlsAllowInvalidCertificates);
		Assert.equals(2.5, s.connectTimeout);
		Assert.equals(0.0, s.socketTimeout);
		Assert.equals("billing", s.appName);
		Assert.equals("majority", s.writeConcern.w);
		Assert.equals(500, s.writeConcern.wtimeout);
		Assert.isTrue(s.writeConcern.journal);
		Assert.equals("SCRAM-SHA-256", s.authMechanism);
		Assert.equals(2, MongoUri.settings({uri: "mongodb://h/?w=2"}).writeConcern.w);
	}

	public function testFieldsOverrideTheString():Void {
		var s = MongoUri.settings({uri: "mongodb://app:old@h:1234/app", password: "new", port: 4321});
		Assert.equals("app", s.username);
		Assert.equals("new", s.password);
		Assert.equals(4321, s.hosts[0].port);

		var d = MongoUri.settings({});
		Assert.equals("127.0.0.1", d.hosts[0].host);
		Assert.equals(27017, d.hosts[0].port);
		Assert.equals("test", d.database);
	}

	public function testOptionsForAbsentMachineryAreIgnoredAndNamed():Void {
		var s = MongoUri.settings({uri: "mongodb://h/?maxPoolSize=10&compressors=zstd&retryWrites=true"});
		Assert.same(["maxpoolsize", "compressors", "retrywrites"], s.ignored);
	}

	public function testWhatCannotBeHonouredIsRefused():Void {
		var refused:Array<String> = [
			"mongodb+srv://cluster.example.com/",
			"postgres://h/",
			"mongodb://",
			"mongodb://h:0/",
			"mongodb://h:70000/",
			"mongodb://h:port/",
			"mongodb://::1/",
			"mongodb://[::1/",
			"mongodb://%2Ftmp%2Fmongodb-27017.sock/",
			"mongodb://h/?readPreference=secondary",
			"mongodb://h/?tlsAllowInvalidHostnames=true",
			"mongodb://h/?authMechanism=GSSAPI",
			"mongodb://h/?tls=maybe",
			"mongodb://h/?connectTimeoutMS=-1",
			"mongodb://h/?loadBalanced=true",
			"mongodb://:p@h/",
			"mongodb://u:%zz@h/",
			"mongodb://h/?authMechanism=MONGODB-X509"
		];

		for (uri in refused) {
			Assert.raises(() -> MongoUri.settings({uri: uri}), ArgumentError, uri);
		}
	}

	/**
		Keepalive is on with MySQL's timings unless told otherwise: with no
		socket timeout (the default), a read waiting on a server gone silent
		would wait for good.
	**/
	public function testKeepAliveIsOnWithTimingsByDefault():Void {
		var s = MongoUri.settings({});
		Assert.isTrue(s.keepAlive);
		Assert.equals("60 10 6", [s.keepAliveIdle, s.keepAliveInterval, s.keepAliveCount].join(" "));

		var off = MongoUri.settings({keepAlive: false, keepAliveIdle: 45, keepAliveInterval: 7, keepAliveCount: 4});
		Assert.isFalse(off.keepAlive);
		Assert.equals("45 7 4", [off.keepAliveIdle, off.keepAliveInterval, off.keepAliveCount].join(" "));

		Assert.raises(() -> MongoUri.settings({keepAliveIdle: -1}), ArgumentError);
		Assert.raises(() -> MongoUri.settings({keepAliveCount: -1}), ArgumentError);
	}

	/**
		A timeout of NaN is refused, as a negative one is: it compares false
		with everything, so a NaN connect timeout would be no limit at all.
	**/
	public function testATimeoutOfNaNIsRefused():Void {
		Assert.raises(() -> MongoUri.settings({connectTimeout: Math.NaN}), ArgumentError);
		Assert.raises(() -> MongoUri.settings({socketTimeout: Math.NaN}), ArgumentError);
	}

	public function testNamingACertificateTurnsTlsOn():Void {
		// Credentials would otherwise go out in the clear under a config that
		// reads as if they did not.
		Assert.isTrue(MongoUri.settings({host: "h", tlsCAFile: "ca.pem"}).tls);
	}
}
