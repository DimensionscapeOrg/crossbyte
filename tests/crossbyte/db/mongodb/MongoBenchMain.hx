package crossbyte.db.mongodb;

import crossbyte.db.mongodb._internal.BsonReader;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb._internal.ScramDigest;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.ObjectId;
import haxe.io.Bytes;

/**
	What the MongoDB driver costs per document and per round trip
	(`ci/mongo-bench.hxml`, then `export/mongo-bench/MongoBenchMain.exe`).

	Encoding writes into one buffer a connection keeps, UTF-8 straight from
	the character codes; decoding reads straight out of the receive buffer
	with field names interned, so the documents of a batch share their
	names. Natively the run also prints the heap one decoded document holds,
	beside `haxe.Json.parse` of the same document. hxcpp's counters move
	only at a collection, so what a call allocates and drops again cannot
	be counted this way, only what it keeps. The round trips run against
	`FakeMongoServer` on loopback, so they include that server's own Haxe
	decoding and encoding -- a ceiling on the driver's share, not a measure
	of MongoDB.
**/
@:access(crossbyte.core.CrossByte)
class MongoBenchMain {
	static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		Sys.println("CrossByte MongoDB driver -- best of 5 samples, calibrated reps");
		Bench.header();

		var document:Dynamic = __document(7);
		var writer:BsonWriter = new BsonWriter(4096);
		writer.document(document);
		var encoded:Bytes = writer.toBytes();
		Sys.println('  (a typical document: ${encoded.length} bytes, 12 fields, one nested, one array)');

		Bench.section("bson");
		Bench.run("encode a document", () -> {
			writer.reset();
			writer.document(document);
		}, encoded.length);

		var reader:BsonReader = new BsonReader();
		Bench.run("decode a document", () -> reader.readDocument(encoded, 0, encoded.length), encoded.length);

		var ordered:BsonReader = new BsonReader();
		ordered.ordered = true;
		Bench.run("decode a document, ordered", () -> ordered.readDocument(encoded, 0, encoded.length), encoded.length);

		// A find reply's first batch: 101 documents sharing their names, which
		// is where the interned names pay.
		var batch:Array<Dynamic> = [for (i in 0...101) __document(i)];
		writer.reset();
		writer.document({cursor: {firstBatch: batch, id: haxe.Int64.make(1, 2), ns: "app.events"}, ok: 1});
		var reply:Bytes = writer.toBytes();
		Bench.run("decode a 101-document reply", () -> reader.readDocument(reply, 0, reply.length), reply.length);

		Bench.run("encode 100 documents for insert", () -> {
			writer.reset();

			for (i in 0...100) {
				writer.documentWithId(batch[i]);
			}
		});

		Bench.section("baseline");
		var json:String = haxe.Json.stringify(document);
		Bench.run("haxe.Json.stringify, same document", () -> haxe.Json.stringify(document), json.length);
		Bench.run("haxe.Json.parse, same document", () -> haxe.Json.parse(json), json.length);

		#if cpp
		__held("a decoded document", () -> reader.readDocument(encoded, 0, encoded.length));
		__held("a decoded document, ordered", () -> ordered.readDocument(encoded, 0, encoded.length));
		__held("haxe.Json.parse, same document", () -> haxe.Json.parse(json));
		#end

		Bench.section("scram");
		var sha256 = new ScramDigest(true);
		var sha1 = new ScramDigest(false);
		var password:Bytes = Bytes.ofString("correct horse battery staple");
		var salt:Bytes = Bytes.ofString("0123456789abcdef");
		// MongoDB's defaults: what opening one authenticated connection costs,
		// before the salted password is cached for the next.
		Bench.run("PBKDF2 SHA-256, 15000 rounds", () -> sha256.pbkdf2(password, salt, 15000));
		Bench.run("PBKDF2 SHA-1, 10000 rounds", () -> sha1.pbkdf2(password, salt, 10000));

		Bench.section("round trip");
		var server = new FakeMongoServer().start();
		var connection = new MongoConnection();
		connection.open({host: "127.0.0.1", port: server.port, database: "app"});
		server.seed("app.events", [for (i in 0...101) BsonDocument.fromObject(__document(i))]);
		Bench.run("ping", () -> connection.ping());
		Bench.run("findOne by _id", () -> connection.findOne("events", {_id: 5}));
		Bench.run("find 101 documents", () -> connection.find("events").toArray());
		Bench.run("insert one document", () -> connection.insertOne("sink", {n: 1, name: "event"}));
		connection.close();
		server.stop();

		Sys.println("");
		Sys.println("done. Numbers compare shapes of code on this machine today;");
		Sys.println("they are not comparable across machines or days.");
	}

	/**
		The heap one result of `fn` holds: many of them kept, with a full
		collection before and after, into a list sized beforehand so that its
		own slots are not counted. The counter is in 128-byte lines, which a
		run of results shares, so the figure is an average, not an exact size.
	**/
	#if cpp
	static function __held(name:String, fn:Void->Dynamic):Void {
		var count:Int = 2000;
		var kept:Array<Dynamic> = [];
		kept.resize(count);
		cpp.vm.Gc.run(true);
		var before:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);

		for (i in 0...count) {
			kept[i] = fn();
		}

		cpp.vm.Gc.run(true);
		var after:Float = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE);
		Sys.println("  " + StringTools.rpad("held  " + name, " ", 46) + Math.round((after - before) / count) + " bytes (of " + kept.length + " kept)");
	}
	#end

	static function __document(i:Int):Dynamic {
		return {
			_id: i,
			user: new ObjectId(),
			name: "user " + i,
			email: "user" + i + "@example.com",
			active: i % 2 == 0,
			score: 12.5 + i,
			visits: 1000 + i,
			created: Date.fromTime(1790769600000.0 + i),
			address: {street: "1 Main St", city: "Oslo", zip: "0150"},
			tags: ["alpha", "beta", "gamma"],
			bio: "A short biography of some length, as a profile would carry.",
			plan: "pro"
		};
	}
}
