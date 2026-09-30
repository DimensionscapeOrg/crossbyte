package crossbyte.db.mongodb;

#if (sys && !js)
import crossbyte.db.mongodb._internal.BsonReader;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb._internal.ScramDigest;
import crossbyte.db.mongodb.bson.BsonBinary;
import crossbyte.db.mongodb.bson.BsonDateTime;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.BsonDouble;
import crossbyte.db.mongodb.bson.BsonInt64;
import crossbyte.db.mongodb.bson.ExtendedJson;
import crossbyte.db.mongodb.bson.ObjectId;
import haxe.Int64;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Mutex;
import sys.thread.Thread;

/** A command the fake server received, in the order its fields arrived. **/
typedef ReceivedCommand = {
	var name:String;
	var body:BsonDocument;
	/** The names of the document sequences (kind 1 sections) that came with it. **/
	var sequences:Array<String>;
	/** The OP_MSG flag bits it was sent with. **/
	var flags:Int;
}

/**
	A MongoDB server small enough to read, speaking OP_MSG on a thread per
	connection, so the driver's protocol, BSON, authentication and cursor
	logic run on every target without a real server.

	It keeps collections in memory and implements what the tests exercise:
	`hello` and `isMaster`, SCRAM-SHA-1 and SCRAM-SHA-256 (the server's side,
	which checks the client's proof and signs its own), `find` with filter,
	sort, projection, skip, limit and batches, `getMore`, `killCursors`,
	`insert`, `update`, `delete`, `aggregate`, `count`, `createIndexes`, `drop`,
	and transactions when it plays a replica set member. It records every
	command, and can be told to answer the next of one with an error, to close
	the connection instead, or to send bytes of the test's choosing.

	Bound to 127.0.0.1 port 0; `stop` wakes and ends its threads.
**/
class FakeMongoServer {
	public var port(default, null):Int = 0;

	/** Play a replica set member: transactions are allowed. `null` is a standalone. **/
	public var setName:Null<String> = null;

	/** The wire version the hello reports. **/
	public var maxWireVersion:Int = 21;

	/** Answer `hello` with CommandNotFound, as MongoDB before 4.4.2 did. **/
	public var legacyHello:Bool = false;

	/** Refuse commands on a connection that has not authenticated. **/
	public var requireAuth:Bool = false;

	/** Take the first step of authentication from the hello. **/
	public var speculativeAuth:Bool = true;

	/** Honour `skipEmptyExchange`; without it the client must send an empty last turn. **/
	public var skipEmptyExchange:Bool = true;

	/** PBKDF2 rounds for SCRAM; the least a client accepts, to keep slow targets quick. **/
	public var iterations:Int = 4096;

	/** The first batch of a cursor when the command sets none. **/
	public var defaultBatchSize:Int = 101;

	/** Add a CRC-32C checksum to every reply, as a server may. **/
	public var checksums:Bool = false;

	/** Reported as the hello's maxMessageSizeBytes. **/
	public var maxMessageSize:Int = 48000000;

	/** Reported as the hello's maxWriteBatchSize. **/
	public var maxWriteBatchSize:Int = 100000;

	/** Reported as the hello's maxBsonObjectSize. **/
	public var maxBsonObjectSize:Int = 16777216;

	/** Extra fields for every hello reply, over what it would say. **/
	public var helloExtra:Null<BsonDocument> = null;

	/** Serve TLS with this certificate and key, PEM files. **/
	public var tls:Null<{certificatePath:String, keyPath:String}> = null;

	@:noCompletion private var __listener:Socket;
	@:noCompletion private var __lock:Mutex = new Mutex();
	@:noCompletion private var __stopping:Bool = false;
	@:noCompletion private var __clients:Array<Socket> = [];
	@:noCompletion private var __received:Array<ReceivedCommand> = [];
	@:noCompletion private var __collections:Map<String, Array<BsonDocument>> = new Map();
	@:noCompletion private var __uniqueIndexes:Map<String, Array<String>> = new Map();
	// Kept for inserts; dropped for a namespace whenever its documents change
	// any other way, and made again from them when next needed.
	@:noCompletion private var __idKeys:Map<String, Map<String, Bool>> = new Map();
	@:noCompletion private var __indexes:Map<String, Array<BsonDocument>> = new Map();
	@:noCompletion private var __users:Map<String, {password:String, mechanisms:Array<String>}> = new Map();
	@:noCompletion private var __cursors:Map<String, {namespace:String, documents:Array<BsonDocument>, position:Int, batchSize:Int}> = new Map();
	@:noCompletion private var __cursorSeq:Int = 0;
	@:noCompletion private var __scripts:Map<String, Array<Dynamic>> = new Map();
	@:noCompletion private var __transactions:Map<String, {number:String, active:Bool, snapshot:Map<String, Array<BsonDocument>>}> = new Map();
	@:noCompletion private var __connectionSeq:Int = 0;
	@:noCompletion private var __threads:Int = 0;

	public function new() {}

	/** Adds a user in `admin` with the SCRAM mechanisms named. **/
	public function addUser(name:String, password:String, ?mechanisms:Array<String>, database:String = "admin"):Void {
		__users.set(database + "." + name, {password: password, mechanisms: mechanisms == null ? ["SCRAM-SHA-1", "SCRAM-SHA-256"] : mechanisms});
	}

	public function start():FakeMongoServer {
		if (tls != null) {
			// Through the same secure socket the client uses, configured before
			// bind(), which is where the server's TLS setup is built.
			var secure = new crossbyte._internal.socket.FlexSocket(true);
			// A listener's verifyCert is about the client's certificate:
			// left at the default, mbedTLS demands one, and the client has none.
			secure.verifyCert = false;
			#if (java || jvm)
			secure.setCertificate(crossbyte._internal.socket._jvm.JvmSsl.JvmSslCertificate.loadFile(tls.certificatePath),
				crossbyte._internal.socket._jvm.JvmSsl.JvmSslKey.loadFile(tls.keyPath));
			#else
			secure.setCertificate(sys.ssl.Certificate.loadFile(tls.certificatePath), sys.ssl.Key.loadFile(tls.keyPath));
			#end
			__listener = secure;
		} else {
			__listener = new Socket();
		}

		__listener.bind(new Host("127.0.0.1"), 0);
		// Listening before the port is read: on the jvm a socket bound but not
		// listening reports port -1.
		__listener.listen(16);
		port = __listener.host().port;
		var listener:Socket = __listener;

		// The listener belongs to this thread, which closes it; stop() only asks.
		// Closed from another thread instead, it could be closed between two
		// accepts, and hxcpp's accept on a closed socket reads a null handle.
		Thread.create(function():Void {
			while (true) {
				var client:Socket;

				try {
					client = listener.accept();
				} catch (_:Dynamic) {
					break;
				}

				__lock.acquire();
				var stopping:Bool = __stopping;

				if (!stopping) {
					__clients.push(client);
					__connectionSeq++;
				}

				var id:Int = __connectionSeq;
				__lock.release();

				if (stopping) {
					try client.close() catch (_:Dynamic) {}
					break;
				}

				Thread.create(() -> __serve(client, id));
			}

			try listener.close() catch (_:Dynamic) {}
		});

		return this;
	}

	/**
		Stops accepting, and wakes the threads still serving connections a test
		left open. Nothing is closed from here: each thread closes what it owns.
	**/
	public function stop():Void {
		__lock.acquire();

		if (__stopping || __listener == null) {
			__stopping = true;
			__lock.release();
			return;
		}

		__stopping = true;

		// Shut down, not closed, and under the lock: a serve thread removes its
		// connection under the same lock before closing it, so none can close a
		// socket, and let its handle be reused by another, while this uses
		// it. Not on eval, which raises a read shut down under it as a native
		// error no catch sees; the tests there close what they open.
		#if !eval
		for (client in __clients) {
			try client.shutdown(true, true) catch (_:Dynamic) {}
		}
		#end

		__lock.release();

		// A connection of its own wakes the accept, which finds the flag.
		try {
			var wake:Socket = new Socket();
			wake.connect(new Host("127.0.0.1"), port);
			wake.close();
		} catch (_:Dynamic) {}
	}

	/** Every command received, in order. **/
	public function received():Array<ReceivedCommand> {
		__lock.acquire();
		var out:Array<ReceivedCommand> = __received.copy();
		__lock.release();
		return out;
	}

	/** The commands received with this name, in order. **/
	public function commands(name:String):Array<ReceivedCommand> {
		return [for (c in received()) if (c.name == name) c];
	}

	/** Connections accepted so far. **/
	public function connections():Int {
		__lock.acquire();
		var count:Int = __connectionSeq;
		__lock.release();
		return count;
	}

	/** Answers the next `command` with `reply`, whatever it asked. **/
	public function replyNext(command:String, reply:BsonDocument):Void {
		__script(command, reply);
	}

	/** Answers the next `command` as usual: queued ahead of a script meant for the one after. **/
	public function passNext(command:String):Void {
		__script(command, "pass");
	}

	/** Closes the connection instead of answering the next `command`. **/
	public function closeNext(command:String):Void {
		__script(command, "close");
	}

	/** Sends `bytes` instead of an answer to the next `command`. **/
	public function rawNext(command:String, bytes:Bytes):Void {
		__script(command, bytes);
	}

	/** The documents stored in `namespace`, `database.collection`. **/
	public function documents(namespace:String):Array<BsonDocument> {
		__lock.acquire();
		var stored:Array<BsonDocument> = __collections.get(namespace);
		var out:Array<BsonDocument> = stored == null ? [] : stored.copy();
		__lock.release();
		return out;
	}

	/** Puts documents in `namespace` directly, as if inserted. **/
	public function seed(namespace:String, documents:Array<BsonDocument>):Void {
		__lock.acquire();
		var stored:Array<BsonDocument> = __collection(namespace);

		for (document in documents) {
			stored.push(document);
		}

		__idKeys.remove(namespace);

		__lock.release();
	}

	/** Cursors still open on the server. **/
	public function openCursors():Int {
		__lock.acquire();
		var count:Int = Lambda.count(__cursors);
		__lock.release();
		return count;
	}

	/** Transactions the server holds open. **/
	public function openTransactions():Int {
		__lock.acquire();
		var count:Int = 0;

		for (t in __transactions) {
			if (t.active) {
				count++;
			}
		}

		__lock.release();
		return count;
	}

	/** Index specifications created on `namespace`. **/
	public function indexes(namespace:String):Array<BsonDocument> {
		__lock.acquire();
		var list:Array<BsonDocument> = __indexes.get(namespace);
		var out:Array<BsonDocument> = list == null ? [] : list.copy();
		__lock.release();
		return out;
	}

	// ------------------------------------------------------------ connection

	@:noCompletion private function __serve(client:Socket, connectionId:Int):Void {
		var reader:BsonReader = new BsonReader();
		reader.ordered = true;
		// int64s kept wrapped, so their type is checked as the server checks it,
		// on hxcpp too, which boxes a small Int64 as an Int.
		reader.wrapInt64 = true;
		// And dates kept exact: on hl and neko a Date holds whole seconds, and
		// the server would store something other than it was sent.
		reader.exactDates = true;
		var writer:BsonWriter = new BsonWriter(1024);
		var state:{authenticated:Bool, conversation:Dynamic} = {authenticated: false, conversation: null};
		var header:Bytes = Bytes.alloc(16);

		try {
			// Accepted sockets are not blocking on every target; this thread
			// reads as if they were.
			client.setBlocking(true);

			if (tls != null) {
				// Driven here rather than left to the first read, which on the
				// jvm does not advance a server's handshake by itself.
				var secure:crossbyte._internal.socket.FlexSocket = cast client;
				var attempts:Int = 0;

				while (true) {
					try {
						secure.handshake();
						break;
					} catch (e:haxe.io.Error) {
						if (++attempts > 5000) {
							throw e;
						}

						crossbyte.sys.System.sleep(0.002);
					}
				}
			}

			while (true) {
				client.input.readFullBytes(header, 0, 16);
				var length:Int = header.getInt32(0);
				var requestId:Int = header.getInt32(4);
				var message:Bytes = Bytes.alloc(length);
				message.blit(0, header, 0, 16);
				client.input.readFullBytes(message, 16, length - 16);

				var flags:Int = message.getInt32(16);
				var end:Int = length - ((flags & 1) != 0 ? 4 : 0);
				var position:Int = 20;
				var body:BsonDocument = null;
				var sequences:Array<String> = [];

				while (position < end) {
					var kind:Int = message.get(position++);

					if (kind == 0) {
						body = reader.readDocument(message, position, end);
						position = reader.end;
					} else {
						var size:Int = message.getInt32(position);
						var sequenceEnd:Int = position + size;
						var nameEnd:Int = position + 4;

						while (message.get(nameEnd) != 0) {
							nameEnd++;
						}

						var name:String = message.getString(position + 4, nameEnd - position - 4);
						var items:Array<Dynamic> = [];
						position = nameEnd + 1;

						while (position < sequenceEnd) {
							items.push(reader.readDocument(message, position, sequenceEnd));
							position = reader.end;
						}

						sequences.push(name);
						body.set(name, items);
					}
				}

				var command:String = body.keyAt(0);
				__lock.acquire();
				__received.push({name: command, body: body, sequences: sequences, flags: flags});
				__lock.release();

				var script:Dynamic = __takeScript(command);

				if (Std.isOfType(script, String) && script == "close") {
					break;
				}

				if (Std.isOfType(script, Bytes)) {
					client.output.writeFullBytes(script, 0, (script : Bytes).length);
					continue;
				}

				var reply:BsonDocument = Std.isOfType(script, BsonDocument) ? script : __handle(command, body, state, connectionId);

				// moreToCome: the client is not waiting for an answer.
				if ((flags & 2) != 0) {
					continue;
				}

				writer.reset();
				writer.int32(0);
				writer.int32(requestId + 1000000);
				writer.int32(requestId);
				writer.int32(2013);
				writer.int32(checksums ? 1 : 0);
				writer.byte(0);
				writer.document(reply);

				if (checksums) {
					writer.int32(0x12345678);
				}

				writer.patchInt32(0, writer.length);
				client.output.writeFullBytes(writer.buffer, 0, writer.length);
			}
		} catch (_:Dynamic) {
			// The client closed, or the server is stopping.
		}

		// Out of stop()'s reach first, under its lock, then closed: see stop().
		__lock.acquire();
		__clients.remove(client);
		__lock.release();

		try client.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------ commands

	@:noCompletion private function __handle(command:String, body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic},
			connectionId:Int):BsonDocument {
		var database:String = Std.string(body.get("$db"));

		if (database == "null") {
			return __error(40414, "Location40414", "BSON field '$db' is missing but a required field");
		}

		switch (command) {
			case "hello" | "isMaster":
				if (command == "hello" && legacyHello) {
					return __error(59, "CommandNotFound", "no such command: 'hello'");
				}

				return __hello(body, state, connectionId);
			case "saslStart" if (body.get("mechanism") == "PLAIN"):
				return __plain(body, state, database);
			case "saslStart":
				return __saslStart(body, state, database);
			case "authenticate":
				return __x509(body, state);
			case "saslContinue":
				return __saslContinue(body, state);
			case "ping":
				return __ok();
			case "endSessions":
				return __ok();
			default:
		}

		if (requireAuth && !state.authenticated) {
			return __error(13, "Unauthorized", 'command $command requires authentication');
		}

		var txnError:BsonDocument = __checkTransaction(command, body);

		if (txnError != null) {
			return txnError;
		}

		var reply:BsonDocument = switch (command) {
			case "buildInfo": __ok().add("version", "7.0.99-fake");
			case "find": __find(body, database);
			case "getMore": __getMore(body, database);
			case "killCursors": __killCursors(body);
			case "insert": __insert(body, database);
			case "update": __update(body, database);
			case "delete": __delete(body, database);
			case "aggregate": __aggregate(body, database);
			case "count": __count(body, database);
			case "createIndexes": __createIndexes(body, database);
			case "drop": __drop(body, database);
			case "commitTransaction": __endTransaction(body, true);
			case "abortTransaction": __endTransaction(body, false);
			default: __error(59, "CommandNotFound", 'no such command: \'$command\'');
		}

		// A statement that fails inside a transaction aborts it, as MongoDB
		// does, a write error included, though the reply says ok.
		if (body.exists("txnNumber") && command != "commitTransaction" && command != "abortTransaction"
			&& (reply.get("ok") != 1 || reply.exists("writeErrors"))) {
			__abortFor(body);
		}

		return reply;
	}

	@:noCompletion private function __hello(body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic}, connectionId:Int):BsonDocument {
		var reply:BsonDocument = new BsonDocument()
			.add("isWritablePrimary", true)
			.add("ismaster", true)
			.add("maxBsonObjectSize", maxBsonObjectSize)
			.add("maxMessageSizeBytes", maxMessageSize)
			.add("maxWriteBatchSize", maxWriteBatchSize)
			.add("localTime", Date.now())
			.add("logicalSessionTimeoutMinutes", 30)
			.add("connectionId", connectionId)
			.add("minWireVersion", 0)
			.add("maxWireVersion", maxWireVersion)
			.add("readOnly", false);

		if (setName != null) {
			reply.add("setName", setName).add("hosts", ['127.0.0.1:$port']).add("primary", '127.0.0.1:$port');
		}

		var mechs:Dynamic = body.get("saslSupportedMechs");

		if (Std.isOfType(mechs, String)) {
			__lock.acquire();
			var user = __users.get(mechs);
			__lock.release();

			if (user != null) {
				reply.add("saslSupportedMechs", user.mechanisms.copy());
			}
		}

		var speculative:Dynamic = body.get("speculativeAuthenticate");

		if (speculativeAuth && Std.isOfType(speculative, BsonDocument)) {
			var start:BsonDocument = speculative;

			if (start.exists("authenticate")) {
				var answer:BsonDocument = __x509(start, state);

				if (answer.get("ok") == 1) {
					answer.remove("ok");
					reply.add("speculativeAuthenticate", answer);
				}
			} else if (start.exists("saslStart")) {
				var answer:BsonDocument = __saslStart(start, state, Std.string(start.get("db")));

				if (answer.get("ok") == 1) {
					// Sent without its ok, as the server sends it.
					answer.remove("ok");
					reply.add("speculativeAuthenticate", answer);
				}
			}
		}

		if (helloExtra != null) {
			for (i in 0...helloExtra.length) {
				reply.set(helloExtra.keyAt(i), helloExtra.valueAt(i));
			}
		}

		return reply.add("ok", 1);
	}

	@:noCompletion private function __saslStart(body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic}, database:String):BsonDocument {
		var mechanism:String = Std.string(body.get("mechanism"));
		var payload:Bytes = body.get("payload");
		var clientFirst:String = payload.toString();

		if (!StringTools.startsWith(clientFirst, "n,,")) {
			return __error(17, "ProtocolError", "bad GS2 header");
		}

		var bare:String = clientFirst.substr(3);
		var fields = crossbyte.db.mongodb._internal.Scram.parseFields(bare);
		var name:String = StringTools.replace(StringTools.replace(fields.get("n"), "=2C", ","), "=3D", "=");
		__lock.acquire();
		var user = __users.get(database + "." + name);
		__lock.release();

		if (user == null || user.mechanisms.indexOf(mechanism) < 0) {
			return __error(18, "AuthenticationFailed", "Authentication failed.");
		}

		var salt:Bytes = Bytes.ofString("salt-for-" + name + "-" + mechanism);
		var serverNonce:String = fields.get("r") + Base64.encode(Bytes.ofString("fake-server-nonce-" + Std.random(1000000)));
		var serverFirst:String = "r=" + serverNonce + ",s=" + Base64.encode(salt) + ",i=" + iterations;
		state.conversation = {
			mechanism: mechanism,
			password: user.password,
			name: name,
			salt: salt,
			bare: bare,
			serverFirst: serverFirst,
			nonce: serverNonce,
			done: false
		};

		return new BsonDocument().add("conversationId", 1).add("done", false).add("payload", Bytes.ofString(serverFirst)).add("ok", 1);
	}

	/** SASL PLAIN, as LDAP users sign in: the password itself, in one step. **/
	@:noCompletion private function __plain(body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic}, database:String):BsonDocument {
		var payload:Bytes = body.get("payload");
		var parts:Array<String> = [];
		var start:Int = 0;

		for (i in 0...payload.length + 1) {
			if (i == payload.length || payload.get(i) == 0) {
				parts.push(payload.getString(start, i - start));
				start = i + 1;
			}
		}

		__lock.acquire();
		var user = parts.length == 3 ? __users.get(database + "." + parts[1]) : null;
		__lock.release();

		if (database != "$external" || user == null || user.password != parts[2] || user.mechanisms.indexOf("PLAIN") < 0) {
			return __error(18, "AuthenticationFailed", "Authentication failed.");
		}

		state.authenticated = true;
		return new BsonDocument().add("conversationId", 1).add("done", true).add("payload", Bytes.alloc(0)).add("ok", 1);
	}

	/**
		MONGODB-X509, which takes the name from the client's certificate. This
		server does not check certificates, so any connection that asks is
		signed in: what is tested is that the client asks, over TLS.
	**/
	@:noCompletion private function __x509(body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic}):BsonDocument {
		var database:Dynamic = body.exists("db") ? body.get("db") : body.get("$db");

		if (body.get("mechanism") != "MONGODB-X509" || database != "$external" || tls == null) {
			return __error(18, "AuthenticationFailed", "Authentication failed.");
		}

		state.authenticated = true;
		return new BsonDocument().add("dbname", "$external").add("user", "CN=localhost").add("ok", 1);
	}

	@:noCompletion private function __saslContinue(body:BsonDocument, state:{authenticated:Bool, conversation:Dynamic}):BsonDocument {
		var conversation:Dynamic = state.conversation;

		if (conversation == null) {
			return __error(17, "ProtocolError", "no SASL conversation");
		}

		var payload:Bytes = body.get("payload");

		if (conversation.done) {
			// The empty last turn of a client that does not skip it.
			state.conversation = null;
			state.authenticated = true;
			return new BsonDocument().add("conversationId", 1).add("done", true).add("payload", Bytes.alloc(0)).add("ok", 1);
		}

		var clientFinal:String = payload.toString();
		var fields = crossbyte.db.mongodb._internal.Scram.parseFields(clientFinal);

		if (fields.get("r") != conversation.nonce || fields.get("c") != "biws") {
			return __error(18, "AuthenticationFailed", "Authentication failed.");
		}

		var withoutProof:String = clientFinal.substr(0, clientFinal.lastIndexOf(",p="));
		var sha256:Bool = conversation.mechanism == "SCRAM-SHA-256";
		var digest:ScramDigest = new ScramDigest(sha256);
		var password:Bytes = sha256 ? Bytes.ofString(conversation.password) : Bytes.ofString(haxe.crypto.Md5.encode(conversation.name + ":mongo:"
			+ conversation.password));
		var salted:Bytes = digest.pbkdf2(password, conversation.salt, iterations);
		var clientKey:Bytes = digest.hmac(salted, Bytes.ofString("Client Key"));
		var storedKey:Bytes = digest.hash(clientKey);
		var authMessage:Bytes = Bytes.ofString(conversation.bare + "," + conversation.serverFirst + "," + withoutProof);
		var signature:Bytes = digest.hmac(storedKey, authMessage);
		var proof:Bytes = Base64.decode(fields.get("p"));
		var recovered:Bytes = Bytes.alloc(proof.length);

		for (i in 0...proof.length) {
			recovered.set(i, proof.get(i) ^ signature.get(i));
		}

		if (digest.hash(recovered).compare(storedKey) != 0) {
			state.conversation = null;
			return __error(18, "AuthenticationFailed", "Authentication failed.");
		}

		var serverKey:Bytes = digest.hmac(salted, Bytes.ofString("Server Key"));
		var serverSignature:String = Base64.encode(digest.hmac(serverKey, authMessage));
		var options:Dynamic = body.get("options");
		var skip:Bool = skipEmptyExchange;

		if (skip) {
			state.conversation = null;
			state.authenticated = true;
		} else {
			conversation.done = true;
		}

		return new BsonDocument()
			.add("conversationId", 1)
			.add("done", skip)
			.add("payload", Bytes.ofString("v=" + serverSignature))
			.add("ok", 1);
	}

	@:noCompletion private function __find(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("find"));
		__lock.acquire();
		var matched:Array<BsonDocument> = [for (d in __collection(namespace)) if (__matches(d, body.get("filter"))) d];
		__lock.release();

		if (body.exists("sort")) {
			__sort(matched, body.get("sort"));
		}

		var skip:Int = body.exists("skip") ? __int(body.get("skip")) : 0;
		var limit:Int = body.exists("limit") ? __int(body.get("limit")) : 0;
		matched = matched.slice(skip);

		if (limit > 0) {
			matched = matched.slice(0, limit);
		}

		if (body.exists("projection")) {
			matched = [for (d in matched) __project(d, body.get("projection"))];
		}

		return __cursorReply(namespace, matched, body.exists("batchSize") ? __int(body.get("batchSize")) : defaultBatchSize);
	}

	@:noCompletion private function __cursorReply(namespace:String, documents:Array<BsonDocument>, firstBatch:Int):BsonDocument {
		var first:Array<Dynamic> = cast documents.slice(0, firstBatch);
		var id:Int64 = Int64.ofInt(0);

		if (documents.length > firstBatch) {
			__lock.acquire();
			__cursorSeq++;
			// High bits set, so an id that lost precision anywhere on the way
			// back would name some other cursor.
			id = Int64.make(0x7ABCDEF0, __cursorSeq);
			__cursors.set(Int64.toStr(id), {
				namespace: namespace,
				documents: documents,
				position: firstBatch,
				batchSize: defaultBatchSize
			});
			__lock.release();
		}

		return __ok().add("cursor", new BsonDocument().add("firstBatch", first).add("id", new BsonInt64(id)).add("ns", namespace));
	}

	@:noCompletion private function __getMore(body:BsonDocument, database:String):BsonDocument {
		var raw:Dynamic = body.get("getMore");

		if (!Std.isOfType(raw, BsonInt64)) {
			return __error(14, "TypeMismatch", "getMore's cursor id must be an int64");
		}

		var key:String = Int64.toStr((raw : BsonInt64).value);
		__lock.acquire();
		var cursor = __cursors.get(key);
		__lock.release();

		if (cursor == null) {
			return __error(43, "CursorNotFound", 'cursor id $key not found');
		}

		var size:Int = body.exists("batchSize") ? __int(body.get("batchSize")) : cursor.batchSize;
		var batch:Array<Dynamic> = cast cursor.documents.slice(cursor.position, cursor.position + size);
		cursor.position += batch.length;
		var id:Int64 = (raw : BsonInt64).value;

		if (cursor.position >= cursor.documents.length) {
			__lock.acquire();
			__cursors.remove(key);
			__lock.release();
			id = Int64.ofInt(0);
		}

		return __ok().add("cursor", new BsonDocument().add("nextBatch", batch).add("id", new BsonInt64(id)).add("ns", cursor.namespace));
	}

	@:noCompletion private function __killCursors(body:BsonDocument):BsonDocument {
		var killed:Array<Dynamic> = [];
		var missing:Array<Dynamic> = [];

		for (id in (body.get("cursors") : Array<Dynamic>)) {
			if (!Std.isOfType(id, BsonInt64)) {
				return __error(14, "TypeMismatch", "cursor ids must be int64");
			}

			var key:String = Int64.toStr((id : BsonInt64).value);
			__lock.acquire();
			var removed:Bool = __cursors.remove(key);
			__lock.release();
			(removed ? killed : missing).push(id);
		}

		return __ok().add("cursorsKilled", killed).add("cursorsNotFound", missing).add("cursorsAlive", []).add("cursorsUnknown", []);
	}

	@:noCompletion private function __insert(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("insert"));
		var documents:Array<Dynamic> = body.get("documents");
		var ordered:Bool = body.get("ordered") != false;
		var errors:Array<Dynamic> = [];
		var n:Int = 0;
		__lock.acquire();
		var stored:Array<BsonDocument> = __collection(namespace);
		var unique:Array<String> = __uniqueIndexes.exists(namespace) ? __uniqueIndexes.get(namespace) : [];

		var ids:Map<String, Bool> = __idSet(namespace);

		for (i in 0...documents.length) {
			var document:BsonDocument = documents[i];
			var clash:String = null;
			// No key for a document without one: nothing it could clash with.
			var key:String = document.exists("_id") ? __idKey(document.get("_id")) : null;

			// _id through the index, so an insert costs the same into a
			// collection of a thousand as into an empty one; the unique
			// indexes a test makes are small, and scanned.
			if (key != null && ids.exists(key)) {
				clash = "_id";
			}

			for (field in unique) {
				for (existing in stored) {
					if (existing.exists(field) && __same(existing.get(field), document.get(field))) {
						clash = field;
					}
				}
			}

			if (clash != null) {
				errors.push(new BsonDocument()
					.add("index", i)
					.add("code", 11000)
					.add("codeName", "DuplicateKey")
					.add("errmsg", 'E11000 duplicate key error collection: $namespace index: ${clash}_1 dup key'));

				if (ordered) {
					break;
				}

				continue;
			}

			stored.push(document);

			if (key != null) {
				ids.set(key, true);
			}

			n++;
		}

		__lock.release();
		var reply:BsonDocument = new BsonDocument().add("n", n);

		if (errors.length > 0) {
			reply.add("writeErrors", errors);
		}

		return reply.add("ok", 1);
	}

	@:noCompletion private function __update(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("update"));
		var n:Int = 0;
		var modified:Int = 0;
		var upserted:Array<Dynamic> = [];
		__lock.acquire();
		var stored:Array<BsonDocument> = __collection(namespace);
		var statements:Array<Dynamic> = body.get("updates");

		for (s in 0...statements.length) {
			var statement:BsonDocument = statements[s];
			var multi:Bool = statement.get("multi") == true;
			var hits:Int = 0;

			for (document in stored) {
				if (!__matches(document, statement.get("q"))) {
					continue;
				}

				hits++;

				if (__apply(document, statement.get("u"))) {
					modified++;
				}

				if (!multi) {
					break;
				}
			}

			n += hits;

			if (hits == 0 && statement.get("upsert") == true) {
				var made:BsonDocument = new BsonDocument();
				var filter:Dynamic = statement.get("q");

				if (Std.isOfType(filter, BsonDocument)) {
					for (i in 0...(filter : BsonDocument).length) {
						var value:Dynamic = (filter : BsonDocument).valueAt(i);

						if (!Std.isOfType(value, BsonDocument)) {
							made.set((filter : BsonDocument).keyAt(i), value);
						}
					}
				}

				if (!made.exists("_id")) {
					var withId:BsonDocument = new BsonDocument().add("_id", new ObjectId());

					for (i in 0...made.length) {
						withId.add(made.keyAt(i), made.valueAt(i));
					}

					made = withId;
				}

				__apply(made, statement.get("u"));
				stored.push(made);
				__idKeys.remove(namespace);
				n++;
				upserted.push(new BsonDocument().add("index", s).add("_id", made.get("_id")));
			}
		}

		__lock.release();
		var reply:BsonDocument = new BsonDocument().add("n", n).add("nModified", modified);

		if (upserted.length > 0) {
			reply.add("upserted", upserted);
		}

		return reply.add("ok", 1);
	}

	@:noCompletion private function __delete(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("delete"));
		var n:Int = 0;
		__lock.acquire();
		var stored:Array<BsonDocument> = __collection(namespace);

		for (raw in (body.get("deletes") : Array<Dynamic>)) {
			var statement:BsonDocument = raw;
			var one:Bool = __int(statement.get("limit")) == 1;
			var i:Int = 0;

			while (i < stored.length) {
				if (__matches(stored[i], statement.get("q"))) {
					stored.splice(i, 1);
					__idKeys.remove(namespace);
					n++;

					if (one) {
						break;
					}
				} else {
					i++;
				}
			}
		}

		__lock.release();
		return new BsonDocument().add("n", n).add("ok", 1);
	}

	@:noCompletion private function __aggregate(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("aggregate"));

		if (!body.exists("cursor")) {
			return __error(9, "FailedToParse", "The 'cursor' option is required");
		}

		__lock.acquire();
		var documents:Array<BsonDocument> = __collection(namespace).copy();
		__lock.release();

		for (raw in (body.get("pipeline") : Array<Dynamic>)) {
			var stage:BsonDocument = raw;
			var name:String = stage.keyAt(0);
			var argument:Dynamic = stage.valueAt(0);

			switch (name) {
				case "$match":
					documents = [for (d in documents) if (__matches(d, argument)) d];
				case "$sort":
					__sort(documents, argument);
				case "$skip":
					documents = documents.slice(__int(argument));
				case "$limit":
					documents = documents.slice(0, __int(argument));
				case "$count":
					documents = [new BsonDocument().add(Std.string(argument), documents.length)];
				default:
					return __error(40324, "Location40324", 'Unrecognized pipeline stage name: \'$name\'');
			}
		}

		var cursor:BsonDocument = body.get("cursor");
		return __cursorReply(namespace, documents, cursor.exists("batchSize") ? __int(cursor.get("batchSize")) : defaultBatchSize);
	}

	@:noCompletion private function __count(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("count"));
		__lock.acquire();
		var n:Int = 0;

		for (d in __collection(namespace)) {
			if (__matches(d, body.get("query"))) {
				n++;
			}
		}

		__lock.release();
		return new BsonDocument().add("n", n).add("ok", 1);
	}

	@:noCompletion private function __createIndexes(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("createIndexes"));
		__lock.acquire();
		var list:Array<BsonDocument> = __indexes.exists(namespace) ? __indexes.get(namespace) : [];
		__indexes.set(namespace, list);

		for (raw in (body.get("indexes") : Array<Dynamic>)) {
			var spec:BsonDocument = raw;
			list.push(spec);

			if (spec.get("unique") == true) {
				var key:BsonDocument = spec.get("key");
				var unique:Array<String> = __uniqueIndexes.exists(namespace) ? __uniqueIndexes.get(namespace) : [];
				unique.push(key.keyAt(0));
				__uniqueIndexes.set(namespace, unique);
			}
		}

		__collection(namespace);
		__lock.release();
		return new BsonDocument().add("numIndexesBefore", 1).add("numIndexesAfter", list.length + 1).add("ok", 1);
	}

	@:noCompletion private function __drop(body:BsonDocument, database:String):BsonDocument {
		var namespace:String = database + "." + Std.string(body.get("drop"));
		__lock.acquire();
		var existed:Bool = __collections.remove(namespace);
		__idKeys.remove(namespace);
		__indexes.remove(namespace);
		__uniqueIndexes.remove(namespace);
		__lock.release();
		return existed ? __ok().add("ns", namespace) : __error(26, "NamespaceNotFound", "ns not found");
	}

	// ------------------------------------------------------------ transactions

	/** Checks a command's transaction fields the way the server does, starting one where asked. **/
	@:noCompletion private function __checkTransaction(command:String, body:BsonDocument):Null<BsonDocument> {
		if (!body.exists("txnNumber")) {
			if (body.exists("startTransaction") || body.exists("autocommit")) {
				return __error(50768, "Location50768", "txnNumber missing");
			}

			return null;
		}

		if (setName == null) {
			return __error(20, "IllegalOperation", "Transaction numbers are only allowed on a replica set member or mongos");
		}

		if (!body.exists("lsid") || body.get("autocommit") != false) {
			return __error(50768, "Location50768", "a transaction needs lsid and autocommit: false");
		}

		if (!Std.isOfType(body.get("txnNumber"), BsonInt64)) {
			return __error(14, "TypeMismatch", "txnNumber must be an int64");
		}

		if (body.exists("writeConcern") && command != "commitTransaction" && command != "abortTransaction") {
			return __error(72, "InvalidOptions", "Cannot set write concern after starting a transaction.");
		}

		var session:String = __sessionKey(body);
		var number:String = __txnNumber(body);
		__lock.acquire();
		var current = __transactions.get(session);

		if (body.get("startTransaction") == true) {
			if (current != null && current.number == number) {
				__lock.release();
				return __error(251, "NoSuchTransaction", "transaction already started", ["TransientTransactionError"]);
			}

			var snapshot:Map<String, Array<BsonDocument>> = new Map();

			for (key in __collections.keys()) {
				snapshot.set(key, [for (d in __collections.get(key)) __copy(d)]);
			}

			__transactions.set(session, {number: number, active: true, snapshot: snapshot});
			__lock.release();
			return null;
		}

		__lock.release();

		if (current == null || current.number != number || !current.active) {
			return __error(251, "NoSuchTransaction", 'Transaction $number has been aborted.', ["TransientTransactionError"]);
		}

		return null;
	}

	@:noCompletion private function __endTransaction(body:BsonDocument, commit:Bool):BsonDocument {
		var session:String = __sessionKey(body);
		var number:String = __txnNumber(body);
		__lock.acquire();
		var current = __transactions.get(session);

		if (current == null || current.number != number || !current.active) {
			__lock.release();
			return __error(251, "NoSuchTransaction", 'Transaction $number has been aborted.', ["TransientTransactionError"]);
		}

		current.active = false;

		if (!commit) {
			__collections = current.snapshot;
			__idKeys = new Map();
		}

		__lock.release();
		return __ok();
	}

	@:noCompletion private function __abortFor(body:BsonDocument):Void {
		var session:String = __sessionKey(body);
		__lock.acquire();
		var current = __transactions.get(session);

		if (current != null && current.active) {
			current.active = false;
			__collections = current.snapshot;
			__idKeys = new Map();
		}

		__lock.release();
	}

	@:noCompletion private static function __txnNumber(body:BsonDocument):String {
		var number:Dynamic = body.get("txnNumber");
		return Std.isOfType(number, BsonInt64) ? Int64.toStr((number : BsonInt64).value) : "not an int64";
	}

	@:noCompletion private static function __sessionKey(body:BsonDocument):String {
		var lsid:BsonDocument = body.get("lsid");
		var id:BsonBinary = lsid.get("id");
		return id.data.toHex();
	}

	// ------------------------------------------------------------ matching

	/** The `_id`s stored in `namespace`, made from the documents when not held. **/
	@:noCompletion private function __idSet(namespace:String):Map<String, Bool> {
		var ids:Map<String, Bool> = __idKeys.get(namespace);

		if (ids == null) {
			ids = new Map();

			for (document in __collection(namespace)) {
				if (document.exists("_id")) {
					ids.set(__idKey(document.get("_id")), true);
				}
			}

			__idKeys.set(namespace, ids);
		}

		return ids;
	}

	/** An `_id` as a key, numbers by value, as MongoDB compares them. **/
	@:noCompletion private static function __idKey(id:Dynamic):String {
		return __isNumber(id) ? "n:" + Std.string(__asFloat(id)) : ExtendedJson.stringify(id, false);
	}

	@:noCompletion private function __collection(namespace:String):Array<BsonDocument> {
		var stored:Array<BsonDocument> = __collections.get(namespace);

		if (stored == null) {
			stored = [];
			__collections.set(namespace, stored);
		}

		return stored;
	}

	@:noCompletion private static function __matches(document:BsonDocument, filter:Dynamic):Bool {
		if (filter == null || !Std.isOfType(filter, BsonDocument)) {
			return true;
		}

		var f:BsonDocument = filter;

		for (i in 0...f.length) {
			var field:String = f.keyAt(i);
			var condition:Dynamic = f.valueAt(i);
			var value:Dynamic = document.get(field);

			if (Std.isOfType(condition, BsonDocument) && (condition : BsonDocument).length > 0
				&& StringTools.startsWith((condition : BsonDocument).keyAt(0), "$")) {
				var ops:BsonDocument = condition;

				for (k in 0...ops.length) {
					var operand:Dynamic = ops.valueAt(k);
					var ok:Bool = switch (ops.keyAt(k)) {
						case "$gt": document.exists(field) && __compare(value, operand) > 0;
						case "$gte": document.exists(field) && __compare(value, operand) >= 0;
						case "$lt": document.exists(field) && __compare(value, operand) < 0;
						case "$lte": document.exists(field) && __compare(value, operand) <= 0;
						case "$ne": !__same(value, operand);
						case "$in": Lambda.exists((operand : Array<Dynamic>), candidate -> __same(value, candidate));
						case "$exists": document.exists(field) == (Std.isOfType(operand, Bool) ? (operand : Bool) : __int(operand) != 0);
						default: false;
					}

					if (!ok) {
						return false;
					}
				}
			} else if (!__same(value, condition)) {
				return false;
			}
		}

		return true;
	}

	/** Equality by canonical Extended JSON: the value and its BSON type both. **/
	@:noCompletion private static function __same(a:Dynamic, b:Dynamic):Bool {
		if (__isNumber(a) && __isNumber(b)) {
			return __asFloat(a) == __asFloat(b);
		}

		return ExtendedJson.stringify(a, false) == ExtendedJson.stringify(b, false);
	}

	@:noCompletion private static function __compare(a:Dynamic, b:Dynamic):Int {
		if (__isNumber(a) && __isNumber(b)) {
			var x:Float = __asFloat(a);
			var y:Float = __asFloat(b);
			return x < y ? -1 : (x > y ? 1 : 0);
		}

		if (__isDate(a) && __isDate(b)) {
			var x:Float = __dateMillis(a);
			var y:Float = __dateMillis(b);
			return x < y ? -1 : (x > y ? 1 : 0);
		}

		var x:String = Std.isOfType(a, String) ? a : ExtendedJson.stringify(a, false);
		var y:String = Std.isOfType(b, String) ? b : ExtendedJson.stringify(b, false);
		return x < y ? -1 : (x > y ? 1 : 0);
	}

	@:noCompletion private static function __sort(documents:Array<BsonDocument>, spec:Dynamic):Void {
		var keys:BsonDocument = Std.isOfType(spec, BsonDocument) ? spec : BsonDocument.fromObject(spec);
		documents.sort(function(a:BsonDocument, b:BsonDocument):Int {
			for (i in 0...keys.length) {
				var field:String = keys.keyAt(i);
				var order:Int = __int(keys.valueAt(i)) < 0 ? -1 : 1;
				var c:Int = __compare(a.get(field), b.get(field));

				if (c != 0) {
					return c * order;
				}
			}

			return 0;
		});
	}

	@:noCompletion private static function __project(document:BsonDocument, spec:Dynamic):BsonDocument {
		var keys:BsonDocument = Std.isOfType(spec, BsonDocument) ? spec : BsonDocument.fromObject(spec);
		var inclusive:Bool = false;

		for (i in 0...keys.length) {
			if (keys.keyAt(i) != "_id" && __int(keys.valueAt(i)) != 0) {
				inclusive = true;
			}
		}

		var out:BsonDocument = new BsonDocument();

		for (i in 0...document.length) {
			var name:String = document.keyAt(i);
			var wanted:Dynamic = keys.get(name);
			var keep:Bool = inclusive ? (name == "_id" ? wanted == null || __int(wanted) != 0 : wanted != null
				&& __int(wanted) != 0) : (wanted == null || __int(wanted) != 0);

			if (keep) {
				out.add(name, document.valueAt(i));
			}
		}

		return out;
	}

	/** Applies an update document; answers whether anything changed. **/
	@:noCompletion private static function __apply(document:BsonDocument, update:Dynamic):Bool {
		var u:BsonDocument = Std.isOfType(update, BsonDocument) ? update : BsonDocument.fromObject(update);
		var before:String = ExtendedJson.stringify(document, false);

		if (u.length > 0 && StringTools.startsWith(u.keyAt(0), "$")) {
			for (i in 0...u.length) {
				var fields:BsonDocument = u.valueAt(i);

				for (k in 0...fields.length) {
					var name:String = fields.keyAt(k);

					switch (u.keyAt(i)) {
						case "$set":
							document.set(name, fields.valueAt(k));
						case "$unset":
							document.remove(name);
						case "$inc":
							var current:Dynamic = document.get(name);
							var sum:Float = (current == null ? 0 : __asFloat(current)) + __asFloat(fields.valueAt(k));
							document.set(name, Math.ffloor(sum) == sum && Math.abs(sum) < 2147483647 ? (Std.int(sum) : Dynamic) : (sum : Dynamic));
						default:
					}
				}
			}
		} else {
			var id:Dynamic = document.get("_id");

			for (key in document.keys()) {
				document.remove(key);
			}

			document.add("_id", id);

			for (i in 0...u.length) {
				if (u.keyAt(i) != "_id") {
					document.add(u.keyAt(i), u.valueAt(i));
				}
			}
		}

		return ExtendedJson.stringify(document, false) != before;
	}

	@:noCompletion private static function __copy(document:BsonDocument):BsonDocument {
		var out:BsonDocument = new BsonDocument();

		for (i in 0...document.length) {
			out.add(document.keyAt(i), document.valueAt(i));
		}

		return out;
	}

	// ------------------------------------------------------------ helpers

	@:noCompletion private function __script(command:String, action:Dynamic):Void {
		__lock.acquire();

		if (!__scripts.exists(command)) {
			__scripts.set(command, []);
		}

		__scripts.get(command).push(action);
		__lock.release();
	}

	@:noCompletion private function __takeScript(command:String):Dynamic {
		__lock.acquire();
		var queue:Array<Dynamic> = __scripts.get(command);
		var action:Dynamic = queue != null && queue.length > 0 ? queue.shift() : null;
		__lock.release();
		return action;
	}

	@:noCompletion private static function __ok():BsonDocument {
		return new BsonDocument().add("ok", 1);
	}

	public static function __error(code:Int, codeName:String, message:String, ?labels:Array<String>):BsonDocument {
		var reply:BsonDocument = new BsonDocument().add("ok", 0).add("errmsg", message).add("code", code).add("codeName", codeName);

		if (labels != null) {
			reply.add("errorLabels", cast labels);
		}

		return reply;
	}

	@:noCompletion private static function __isNumber(v:Dynamic):Bool {
		return v != null && !Std.isOfType(v, Bool)
			&& (Int64.isInt64(v) || Std.isOfType(v, Float) || Std.isOfType(v, Int) || Std.isOfType(v, BsonDouble) || Std.isOfType(v, BsonInt64));
	}

	@:noCompletion private static function __asFloat(v:Dynamic):Float {
		if (Std.isOfType(v, BsonInt64)) {
			return crossbyte.db.mongodb._internal.Int64Float.toFloat((v : BsonInt64).value);
		}

		if (Int64.isInt64(v)) {
			return crossbyte.db.mongodb._internal.Int64Float.toFloat(v);
		}

		if (Std.isOfType(v, BsonDouble)) {
			return (v : BsonDouble).value;
		}

		return v;
	}

	@:noCompletion private static function __isDate(v:Dynamic):Bool {
		return Std.isOfType(v, Date) || Std.isOfType(v, BsonDateTime);
	}

	@:noCompletion private static function __dateMillis(v:Dynamic):Float {
		return Std.isOfType(v, Date) ? (v : Date).getTime() : (v : BsonDateTime).getTime();
	}

	@:noCompletion private static function __int(v:Dynamic):Int {
		return v == null ? 0 : Std.int(__asFloat(v));
	}
}
#end
