package crossbyte.db.mongodb;

/**
	Connection settings for `MongoConnection`.

	Either a connection string in `uri`, or the fields, or both: a field set
	here overrides what the string says, so a URI from configuration can take
	its password from somewhere else.

	```haxe
	// Given connection:MongoConnection, secret:String.
	connection.open({uri: "mongodb://app@db1.example.com:27017/app?tls=true&authSource=admin", password: secret});
	connection.open({host: "127.0.0.1", database: "app", username: "app", password: secret});
	```
**/
typedef MongoConfig = {
	/**
		A `mongodb://` connection string: credentials, one or more hosts,
		the default database, and options such as `authSource`,
		`authMechanism`, `tls`, `tlsCAFile`, `tlsCertificateKeyFile`,
		`tlsAllowInvalidCertificates`, `connectTimeoutMS`, `socketTimeoutMS`,
		`appName`, `w`, `wtimeoutMS`, `journal`, `directConnection` and
		`replicaSet`. `mongodb+srv://` needs DNS SRV lookups and is refused.
	**/
	@:optional var uri:String;

	/** The server's host name or address. Defaults to `127.0.0.1`. **/
	@:optional var host:String;

	/** Defaults to 27017. **/
	@:optional var port:Int;

	/** The database commands go to when they name none. Defaults to `test`. **/
	@:optional var database:String;

	@:optional var username:String;
	@:optional var password:String;

	/**
		The database the user is defined in. Defaults to `database` when one
		is given, as MongoDB's drivers do with a connection string's database,
		and to `admin` otherwise, so a user made in `admin`, as the official
		container image makes its root user, needs `authSource: "admin"`
		beside a `database`.
	**/
	@:optional var authSource:String;

	/**
		`SCRAM-SHA-256`, `SCRAM-SHA-1`, `MONGODB-X509` or `PLAIN`. Left out, the
		server is asked which SCRAM mechanisms the user has, and SHA-256 is
		preferred.
	**/
	@:optional var authMechanism:String;

	/** Connect with TLS. **/
	@:optional var tls:Bool;

	/** A PEM file of the certificate authorities to trust, instead of the system's. **/
	@:optional var tlsCAFile:String;

	/** A PEM file holding this client's certificate and private key, for servers that ask for one, and for `MONGODB-X509`. **/
	@:optional var tlsCertificateKeyFile:String;

	@:optional var tlsCertificateKeyFilePassword:String;

	/**
		Accept any certificate the server presents. The traffic is still
		encrypted, but anything able to sit in the middle can present its
		own: for a development server only.
	**/
	@:optional var tlsAllowInvalidCertificates:Bool;

	/**
		Seconds `open()` may take with each server it tries (the connect,
		TLS, the hello and the login together) before that server fails
		with an `IOError`, as MySQL's `connectTimeout` covers its login.
		Defaults to 10; 0 for no limit. Once open, a read waits on
		`socketTimeout` instead. Looking a host name up is not bounded by it.

		On the interpreter (eval) the connect and a TLS handshake have no
		limit (eval connects blocking, and fails an expired socket timeout
		by aborting the process), so only the hello and the login are
		bounded. On hl the connect is bounded where the system applies a
		send timeout to it: on Linux, not on Windows.
	**/
	@:optional var connectTimeout:Float;

	/**
		Seconds a read may wait for the server once the connection is open,
		or 0 (the default, as in MongoDB's drivers) for no limit. A long
		aggregation may legitimately run for minutes; bound a single
		operation with its `maxTimeMS` option instead, which the server
		enforces. Not applied on the interpreter, which fails an expired
		socket timeout by aborting the process. A server that has stopped
		answering altogether is found by `keepAlive` instead.
	**/
	@:optional var socketTimeout:Float;

	/**
		TCP keepalive, on unless set `false`, so a connection to a server that
		has vanished (a partition, a host that died without closing) is
		noticed instead of waited on: about two minutes with the timings
		below. With no keepalive and no `socketTimeout`, a read waiting on
		such a server would wait for ever, holding the connection and
		whatever worker was using it.

		Keepalive probes only a connection with nothing unacknowledged in
		flight: a command sent to a host that has just vanished waits instead
		for the system to give up retransmitting it, about fifteen minutes on
		Linux.

		Natively it is set on every system, the count from Windows 10 (1703)
		on. On the jvm keepalive is turned on everywhere, but its timings need
		Java 11 or later: on Java 8 the system's apply, two hours before the
		first probe. The interpreter, hl and neko have no such option, and
		connect without it.
	**/
	@:optional var keepAlive:Bool;

	/** Idle seconds before the first keepalive probe: 60 when unset, 0 for the system's own. **/
	@:optional var keepAliveIdle:Int;

	/** Seconds between unanswered probes: 10 when unset, 0 for the system's own. **/
	@:optional var keepAliveInterval:Int;

	/**
		Unanswered probes before the connection is dropped: 6 when unset, 0
		for the system's own. Windows before 10 (1703) fixes the count at 10
		and ignores this.
	**/
	@:optional var keepAliveCount:Int;

	/** A name the server records in its log and in `currentOp` for this client. **/
	@:optional var appName:String;

	/** The write concern for writes that do not give their own. The server's default when left out. **/
	@:optional var writeConcern:MongoWriteConcern;

	/** Use the server named even when it is not a replica set's primary. **/
	@:optional var directConnection:Bool;

	/**
		Decode BSON dates as `BsonDateTime`, exact everywhere, rather than as
		`Date`, which on hl and neko holds whole seconds between 1901 and 2038.
	**/
	@:optional var exactDates:Bool;
}

/**
	How much acknowledgement a write waits for.
**/
typedef MongoWriteConcern = {
	/**
		How many members must apply the write: a number, or `"majority"`.
		`0` asks for no acknowledgement at all: the write is sent and not
		waited for, and its result reads `acknowledged: false`.
	**/
	@:optional var w:MongoW;

	/** Wait for the write to reach the on-disk journal. **/
	@:optional var journal:Bool;

	/** Milliseconds to wait for `w` members before reporting a write concern error. **/
	@:optional var wtimeout:Int;
}

/**
	A write concern's `w`: how many members must apply a write, or a tag
	such as `"majority"`. A config loaded from JSON holds whatever the JSON
	did; the server refuses anything else.
**/
abstract MongoW(Dynamic) from Int from String to Dynamic {}
