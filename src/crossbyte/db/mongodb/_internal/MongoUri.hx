package crossbyte.db.mongodb._internal;

import crossbyte.db.mongodb.MongoConfig;
import crossbyte.errors.ArgumentError;

/** One server named by a connection string. **/
typedef MongoHost = {
	var host:String;
	var port:Int;
}

/**
	Everything a connection needs, from a `MongoConfig` and the connection
	string in it.
**/
class MongoSettings {
	public var hosts:Array<MongoHost> = [];
	public var database:String = "test";
	public var username:Null<String> = null;
	public var password:Null<String> = null;
	public var authSource:Null<String> = null;
	public var authMechanism:Null<String> = null;
	public var tls:Bool = false;
	public var tlsCAFile:Null<String> = null;
	public var tlsCertificateKeyFile:Null<String> = null;
	public var tlsCertificateKeyFilePassword:Null<String> = null;
	public var tlsAllowInvalidCertificates:Bool = false;
	public var connectTimeout:Float = 10.0;
	public var socketTimeout:Float = 0.0;
	public var keepAlive:Bool = true;
	public var keepAliveIdle:Int = 60;
	public var keepAliveInterval:Int = 10;
	public var keepAliveCount:Int = 6;
	public var appName:Null<String> = null;
	public var writeConcern:Null<MongoWriteConcern> = null;
	public var directConnection:Bool = false;
	public var replicaSet:Null<String> = null;
	public var exactDates:Bool = false;
	/** Options the string gave that this client has no use for, for a warning. **/
	public var ignored:Array<String> = [];

	public function new() {}

	/** The database credentials are checked against. **/
	public function effectiveAuthSource():String {
		if (authSource != null && authSource != "") {
			return authSource;
		}

		if (authMechanism == "MONGODB-X509" || authMechanism == "PLAIN") {
			return "$external";
		}

		return database != null && database != "" && __databaseGiven ? database : "admin";
	}

	@:noCompletion public var __databaseGiven:Bool = false;
}

/**
	Reads a `mongodb://` connection string, as MongoDB's connection string
	specification lays it out:
	`mongodb://[user[:password]@]host[:port][,host[:port]...][/[database]][?options]`.

	The user name, password and database are percent-decoded, and must be
	percent-encoded where they hold `:`, `@`, `/` or `%`. Option names are
	matched without regard to case.
**/
class MongoUri {
	/**
		The settings a config asks for: its connection string if it has one,
		then any field it sets on top.

		@throws ArgumentError When the string or a field is malformed, or asks
		for something this client does not do.
	**/
	public static function settings(config:MongoConfig):MongoSettings {
		var out:MongoSettings = new MongoSettings();

		if (config.uri != null && config.uri != "") {
			parseInto(config.uri, out);
		}

		if (config.host != null && config.host != "") {
			out.hosts = [{host: config.host, port: config.port != null ? config.port : 27017}];
		} else if (config.port != null) {
			if (out.hosts.length == 0) {
				out.hosts = [{host: "127.0.0.1", port: config.port}];
			} else {
				for (host in out.hosts) {
					host.port = config.port;
				}
			}
		}

		if (out.hosts.length == 0) {
			out.hosts = [{host: "127.0.0.1", port: 27017}];
		}

		if (config.database != null && config.database != "") {
			out.database = config.database;
			out.__databaseGiven = true;
		}

		if (config.username != null && config.username != "") {
			out.username = config.username;
		}

		if (config.password != null) {
			out.password = config.password;
		}

		if (config.authSource != null && config.authSource != "") {
			out.authSource = config.authSource;
		}

		if (config.authMechanism != null && config.authMechanism != "") {
			out.authMechanism = __mechanism(config.authMechanism);
		}

		if (config.tls != null) {
			out.tls = config.tls;
		}

		if (config.tlsCAFile != null) {
			out.tlsCAFile = config.tlsCAFile;
		}

		if (config.tlsCertificateKeyFile != null) {
			out.tlsCertificateKeyFile = config.tlsCertificateKeyFile;
		}

		if (config.tlsCertificateKeyFilePassword != null) {
			out.tlsCertificateKeyFilePassword = config.tlsCertificateKeyFilePassword;
		}

		if (config.tlsAllowInvalidCertificates != null) {
			out.tlsAllowInvalidCertificates = config.tlsAllowInvalidCertificates;
		}

		if (config.connectTimeout != null) {
			out.connectTimeout = config.connectTimeout;
		}

		if (config.socketTimeout != null) {
			out.socketTimeout = config.socketTimeout;
		}

		if (config.keepAlive != null) {
			out.keepAlive = config.keepAlive;
		}

		if (config.keepAliveIdle != null) {
			out.keepAliveIdle = config.keepAliveIdle;
		}

		if (config.keepAliveInterval != null) {
			out.keepAliveInterval = config.keepAliveInterval;
		}

		if (config.keepAliveCount != null) {
			out.keepAliveCount = config.keepAliveCount;
		}

		if (config.appName != null) {
			out.appName = config.appName;
		}

		if (config.writeConcern != null) {
			out.writeConcern = config.writeConcern;
		}

		if (config.directConnection != null) {
			out.directConnection = config.directConnection;
		}

		if (config.exactDates != null) {
			out.exactDates = config.exactDates;
		}

		for (host in out.hosts) {
			if (host.port < 1 || host.port > 65535) {
				throw new ArgumentError('Port ${host.port} of ${host.host} is not between 1 and 65535.');
			}
		}

		// NaN as well: it compares false with everything, so a NaN connect
		// timeout was no limit at all and a NaN socket timeout reached the
		// socket as given.
		if (Math.isNaN(out.connectTimeout) || Math.isNaN(out.socketTimeout) || out.connectTimeout < 0 || out.socketTimeout < 0) {
			throw new ArgumentError("A timeout cannot be negative, or NaN; 0 is no limit.");
		}

		if (out.keepAliveIdle < 0 || out.keepAliveInterval < 0 || out.keepAliveCount < 0) {
			throw new ArgumentError("A keepalive timing cannot be negative; 0 is the system's own.");
		}

		if ((out.tlsCAFile != null || out.tlsCertificateKeyFile != null) && !out.tls) {
			// Naming a CA or a certificate and then connecting in the clear
			// would send credentials unprotected while the config reads as if
			// they were not; MongoDB's drivers make the same call.
			out.tls = true;
		}

		if (out.authMechanism == "MONGODB-X509" && out.tlsCertificateKeyFile == null) {
			throw new ArgumentError("MONGODB-X509 authenticates with a client certificate; set tlsCertificateKeyFile.");
		}

		if (out.authMechanism != null && out.authMechanism != "MONGODB-X509" && out.username == null) {
			throw new ArgumentError('${out.authMechanism} needs a user name.');
		}

		return out;
	}

	/**
		A config's host and credentials as a connection string, the user name
		and password percent-encoded, so one holding `@`, `:` or `/` cannot
		move the authority, `p@ss` in a password naming a host `ss`. What
		`settings` reads back is the config it came from.
	**/
	public static function format(cfg:MongoConfig):String {
		var host:String = cfg.host != null && cfg.host != "" ? cfg.host : "127.0.0.1";
		var port:Int = cfg.port != null ? cfg.port : 27017;
		var credentials:String = "";

		if (cfg.username != null && cfg.username != "") {
			credentials = StringTools.urlEncode(cfg.username) + (cfg.password != null ? ":" + StringTools.urlEncode(cfg.password) : "") + "@";
		}

		return "mongodb://" + credentials + (host.indexOf(":") >= 0 ? "[" + host + "]" : host) + ":" + port;
	}

	/** Reads `uri` into `out`. **/
	public static function parseInto(uri:String, out:MongoSettings):Void {
		var scheme:String = "mongodb://";

		if (StringTools.startsWith(uri, "mongodb+srv://")) {
			throw new ArgumentError("mongodb+srv:// needs DNS SRV and TXT lookups, which this client does not do; list the hosts with mongodb:// instead.");
		}

		if (!StringTools.startsWith(uri, scheme)) {
			throw new ArgumentError('A MongoDB connection string starts with mongodb://, not "${uri.substr(0, 16)}".');
		}

		var rest:String = uri.substr(scheme.length);
		var query:String = null;
		var queryAt:Int = rest.indexOf("?");

		if (queryAt >= 0) {
			query = rest.substr(queryAt + 1);
			rest = rest.substr(0, queryAt);
		}

		// The user information ends at the last "@" before the path: a
		// password can hold an unencoded "@" no more than a host can, but
		// splitting at the last one reads the likelier mistake the way it
		// was meant.
		var slash:Int = rest.indexOf("/");
		var authority:String = slash >= 0 ? rest.substr(0, slash) : rest;
		var path:String = slash >= 0 ? rest.substr(slash + 1) : null;
		var at:Int = authority.lastIndexOf("@");

		if (at >= 0) {
			var userInfo:String = authority.substr(0, at);
			authority = authority.substr(at + 1);
			var colon:Int = userInfo.indexOf(":");
			var user:String = colon >= 0 ? userInfo.substr(0, colon) : userInfo;

			if (user == "") {
				throw new ArgumentError("The connection string has credentials with an empty user name.");
			}

			out.username = __decode(user, "user name");
			out.password = colon >= 0 ? __decode(userInfo.substr(colon + 1), "password") : null;
		}

		if (authority == "") {
			throw new ArgumentError("The connection string names no host.");
		}

		out.hosts = [];

		for (entry in authority.split(",")) {
			out.hosts.push(__host(entry));
		}

		if (path != null && path != "") {
			var database:String = __decode(path, "database");

			for (bad in ["/", "\\", " ", "\"", "$"]) {
				if (database.indexOf(bad) >= 0) {
					throw new ArgumentError('"$database" is not a database name.');
				}
			}

			out.database = database;
			out.__databaseGiven = true;
		}

		if (query != null && query != "") {
			for (pair in query.split("&")) {
				if (pair == "") {
					continue;
				}

				var eq:Int = pair.indexOf("=");

				if (eq <= 0) {
					throw new ArgumentError('Connection string option "$pair" has no value.');
				}

				__option(pair.substr(0, eq).toLowerCase(), __decode(pair.substr(eq + 1), "option"), out);
			}
		}
	}

	@:noCompletion private static function __host(entry:String):MongoHost {
		if (entry == "") {
			throw new ArgumentError("The connection string has an empty host.");
		}

		var host:String;
		var portText:String = null;

		if (StringTools.startsWith(entry, "[")) {
			var close:Int = entry.indexOf("]");

			if (close < 0) {
				throw new ArgumentError('"$entry" opens an IPv6 address it does not close.');
			}

			host = entry.substr(1, close - 1);
			var after:String = entry.substr(close + 1);

			if (after != "") {
				if (!StringTools.startsWith(after, ":")) {
					throw new ArgumentError('"$entry" is not a host.');
				}

				portText = after.substr(1);
			}
		} else {
			if (entry.indexOf("%2F") >= 0 || entry.indexOf("%2f") >= 0 || StringTools.endsWith(entry, ".sock")) {
				throw new ArgumentError("Unix domain sockets are not supported; connect over TCP.");
			}

			var colon:Int = entry.lastIndexOf(":");

			if (colon >= 0 && entry.indexOf(":") != colon) {
				throw new ArgumentError('"$entry" looks like an IPv6 address; write it in brackets, [::1]:27017.');
			}

			host = colon >= 0 ? entry.substr(0, colon) : entry;
			portText = colon >= 0 ? entry.substr(colon + 1) : null;
		}

		var port:Int = 27017;

		if (portText != null) {
			port = crossbyte.utils.IntParse.decimal(portText, 65535);

			if (port < 1) {
				throw new ArgumentError('"$portText" is not a port.');
			}
		}

		if (host == "") {
			throw new ArgumentError('"$entry" names no host.');
		}

		return {host: host.toLowerCase(), port: port};
	}

	@:noCompletion private static function __option(name:String, value:String, out:MongoSettings):Void {
		switch (name) {
			case "authsource":
				out.authSource = value;
			case "authmechanism":
				out.authMechanism = __mechanism(value);
			case "tls" | "ssl":
				out.tls = __bool(name, value);
			case "tlscafile":
				out.tlsCAFile = value;
			case "tlscertificatekeyfile":
				out.tlsCertificateKeyFile = value;
			case "tlscertificatekeyfilepassword":
				out.tlsCertificateKeyFilePassword = value;
			case "tlsallowinvalidcertificates" | "tlsinsecure":
				out.tlsAllowInvalidCertificates = __bool(name, value);
			case "tlsallowinvalidhostnames":
				if (__bool(name, value)) {
					// The TLS stacks under CrossByte check a certificate's
					// chain and its name together; skipping only the name
					// cannot be expressed, and quietly skipping both would be
					// worse than refusing.
					throw new ArgumentError("tlsAllowInvalidHostnames cannot be honoured alone here; use tlsAllowInvalidCertificates, which accepts any certificate.");
				}
			case "connecttimeoutms":
				out.connectTimeout = __millis(name, value) / 1000.0;
			case "sockettimeoutms":
				out.socketTimeout = __millis(name, value) / 1000.0;
			case "appname":
				out.appName = value;
			case "w":
				if (out.writeConcern == null) {
					out.writeConcern = {};
				}

				var count:Int = crossbyte.utils.IntParse.decimal(value);
				out.writeConcern.w = count >= 0 ? (count : MongoW) : (value : MongoW);
			case "wtimeoutms":
				if (out.writeConcern == null) {
					out.writeConcern = {};
				}

				out.writeConcern.wtimeout = __millis(name, value);
			case "journal":
				if (out.writeConcern == null) {
					out.writeConcern = {};
				}

				out.writeConcern.journal = __bool(name, value);
			case "directconnection":
				out.directConnection = __bool(name, value);
			case "replicaset":
				out.replicaSet = value;
			case "readpreference":
				if (value.toLowerCase() != "primary") {
					throw new ArgumentError('readPreference "$value" is not supported: every command goes to the primary.');
				}
			case "loadbalanced":
				if (__bool(name, value)) {
					throw new ArgumentError("loadBalanced mode is not supported.");
				}
			default:
				// Pool sizes, compression, retries, server selection and
				// monitoring: options for machinery this client does not have,
				// a ConnectionPool is configured on its own, recorded for
				// a warning rather than refused, as the specification asks.
				out.ignored.push(name);
		}
	}

	@:noCompletion private static function __mechanism(value:String):String {
		var upper:String = value.toUpperCase();

		return switch (upper) {
			case "SCRAM-SHA-1" | "SCRAM-SHA-256" | "MONGODB-X509" | "PLAIN": upper;
			default: throw new ArgumentError('authMechanism "$value" is not supported; use SCRAM-SHA-256, SCRAM-SHA-1, MONGODB-X509 or PLAIN.');
		}
	}

	@:noCompletion private static function __bool(name:String, value:String):Bool {
		return switch (value.toLowerCase()) {
			case "true": true;
			case "false": false;
			default: throw new ArgumentError('Option $name is true or false, not "$value".');
		}
	}

	@:noCompletion private static function __millis(name:String, value:String):Int {
		var millis:Int = crossbyte.utils.IntParse.decimal(value);

		if (millis < 0) {
			throw new ArgumentError('Option $name is a count of milliseconds, not "$value".');
		}

		return millis;
	}

	/**
		Percent-decoding as RFC 3986 has it, and nothing more: not
		`StringTools.urlDecode`, which also reads `+` as a space the way a form
		does, and so would turn a password holding a plus into another
		password.
	**/
	@:noCompletion private static function __decode(text:String, what:String):String {
		if (text.indexOf("%") < 0) {
			return text;
		}

		var out:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		var start:Int = 0;
		var i:Int = 0;

		while (i < text.length) {
			if (StringTools.fastCodeAt(text, i) != "%".code) {
				i++;
				continue;
			}

			if (i > start) {
				out.add(haxe.io.Bytes.ofString(text.substring(start, i)));
			}

			var high:Int = i + 1 < text.length ? __hexDigit(StringTools.fastCodeAt(text, i + 1)) : -1;
			var low:Int = i + 2 < text.length ? __hexDigit(StringTools.fastCodeAt(text, i + 2)) : -1;

			if (high < 0 || low < 0) {
				throw new ArgumentError('The connection string\'s $what is not validly percent-encoded.');
			}

			out.addByte((high << 4) | low);
			i += 3;
			start = i;
		}

		if (start < text.length) {
			out.add(haxe.io.Bytes.ofString(text.substr(start)));
		}

		return out.getBytes().toString();
	}

	@:noCompletion private static function __hexDigit(c:Int):Int {
		if (c >= "0".code && c <= "9".code) {
			return c - "0".code;
		}

		if (c >= "a".code && c <= "f".code) {
			return c - "a".code + 10;
		}

		if (c >= "A".code && c <= "F".code) {
			return c - "A".code + 10;
		}

		return -1;
	}
}
