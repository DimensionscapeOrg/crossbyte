package crossbyte.db.mongodb;

/**
	Connection settings for `MongoConnection`.

	Either a connection string in `uri`, or the fields, or both: a field set
	here overrides what the string says, so a URI from configuration can take
	its password from somewhere else.

	```haxe
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
		and to `admin` otherwise -- so a user made in `admin`, as the official
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

	/** Seconds to wait for a connection. Defaults to 10. **/
	@:optional var connectTimeout:Float;

	/**
		Seconds a read may wait for the server, or 0 -- the default, as in
		MongoDB's drivers -- for no limit. A long aggregation may legitimately
		run for minutes; bound a single operation with its `maxTimeMS` option
		instead, which the server enforces.
	**/
	@:optional var socketTimeout:Float;

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
		How many members must apply the write -- a number, or `"majority"`.
		`0` asks for no acknowledgement at all: the write is sent and not
		waited for, and its result reads `acknowledged: false`.
	**/
	@:optional var w:Dynamic;

	/** Wait for the write to reach the on-disk journal. **/
	@:optional var journal:Bool;

	/** Milliseconds to wait for `w` members before reporting a write concern error. **/
	@:optional var wtimeout:Int;
}
