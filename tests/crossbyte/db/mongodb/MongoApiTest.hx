package crossbyte.db.mongodb;

import crossbyte.db.mongodb.MongoConfig;
import crossbyte.db.mongodb.MongoError;
import crossbyte.db.mongodb.MongoOptions;
import crossbyte.db.mongodb.MongoWriteResult;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.db.mongodb.bson.ObjectId;
import crossbyte.ds.TypeCheck;
import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	The shapes of the driver's public types: options that are classes
	taking object literals, a hint, a collation and a write concern's `w`
	typed for what they hold, write errors and upserts as classes, and the
	parser and the cursor's constructor kept inside, rather than anonymous
	structures or `Dynamic` read by name on every operation and taking
	anything. What does and does not compile is decided when this is
	compiled, so it runs on every target.
**/
class MongoApiTest extends utest.Test {
	public function testOptionsAreClassesThatTakeLiterals():Void {
		Assert.isNull(TypeCheck.errorOf(({limit: 1, batchSize: 2, sort: {n: 1}, projection: {name: 1}, comment: "x"} : MongoFindOptions)));
		Assert.isNull(TypeCheck.errorOf(({} : MongoFindOptions)), "every field is optional");
		Assert.isNull(TypeCheck.errorOf(({ordered: false, bypassDocumentValidation: true, writeConcern: {w: 1}} : MongoInsertOptions)));
		Assert.isNull(TypeCheck.errorOf(({upsert: true, multi: true, arrayFilters: [{x: 1}]} : MongoUpdateOptions)));
		Assert.isNull(TypeCheck.errorOf(({justOne: true} : MongoDeleteOptions)));
		Assert.isNull(TypeCheck.errorOf(({batchSize: 10, allowDiskUse: true, maxTimeMS: 5} : MongoAggregateOptions)));
		Assert.isNull(TypeCheck.errorOf(({skip: 1, limit: 2} : MongoCountOptions)));
		Assert.isNull(TypeCheck.errorOf(({key: {at: 1}, expireAfterSeconds: 0, unique: true} : MongoIndex)));
		Assert.notNull(TypeCheck.errorOf(({unique: true} : MongoIndex)), "an index needs its key");

		// Classes, read directly: one made elsewhere as an anonymous object is
		// not options, nor are one call's options another's.
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, MongoFindOptions)), "options are a class");
		Assert.notNull(TypeCheck.errorOf({
			var shared = {limit: 1};
			(shared : MongoCountOptions);
		}), "an anonymous object passed as options");
		Assert.notNull(TypeCheck.errorOf({
			var find:MongoFindOptions = {limit: 1};
			(find : MongoCountOptions);
		}), "find's options passed as count's");

		var options:MongoFindOptions = {limit: 3};
		Assert.equals(3, options.limit);
		Assert.isNull(options.skip);
		Assert.isNull(options.hint);
	}

	public function testAHintIsAnIndexNameOrItsKeys():Void {
		Assert.isNull(TypeCheck.errorOf(({hint: "last_1"} : MongoFindOptions)), "a name");
		Assert.isNull(TypeCheck.errorOf(({hint: new BsonDocument().add("last", 1).add("first", 1)} : MongoFindOptions)), "a BsonDocument");
		Assert.isNull(TypeCheck.errorOf(({hint: {last: 1}} : MongoCountOptions)), "an object of keys");
		Assert.notNull(TypeCheck.errorOf(({hint: 5} : MongoFindOptions)), "a number");
		Assert.notNull(TypeCheck.errorOf(({hint: true} : MongoDeleteOptions)), "a bool");

		// Any other object reaches the conversion, which refuses it.
		Assert.raises(() -> {
			var refused:MongoFindOptions = {hint: ObjectId.fromHex("0123456789abcdef01234567")};
		}, ArgumentError);
	}

	public function testACollationIsTyped():Void {
		Assert.isNull(TypeCheck.errorOf(({collation: {locale: "fr", strength: 1, numericOrdering: true}} : MongoFindOptions)));
		Assert.isNull(TypeCheck.errorOf(({key: {name: 1}, collation: {locale: "de", caseFirst: "upper"}} : MongoIndex)));
		Assert.notNull(TypeCheck.errorOf(({collation: {locale: "fr", strenght: 1}} : MongoFindOptions)), "a misspelt field");
		Assert.notNull(TypeCheck.errorOf(({collation: {strength: 1}} : MongoUpdateOptions)), "a collation needs its locale");
		Assert.notNull(TypeCheck.errorOf(({collation: "fr"} : MongoAggregateOptions)), "text");
	}

	public function testAWriteConcernsWIsACountOrATag():Void {
		Assert.isNull(TypeCheck.errorOf(({w: "majority"} : MongoWriteConcern)));
		Assert.isNull(TypeCheck.errorOf(({w: 2, journal: true, wtimeout: 100} : MongoWriteConcern)));
		Assert.notNull(TypeCheck.errorOf(({w: true} : MongoWriteConcern)), "a bool");
		Assert.notNull(TypeCheck.errorOf(({w: 1.5} : MongoWriteConcern)), "a fraction");

		// A config loaded from JSON still carries whatever it held.
		var loaded:MongoConfig = haxe.Json.parse('{"writeConcern": {"w": "majority"}}');
		Assert.equals("majority", (loaded.writeConcern.w : Dynamic));
	}

	public function testWriteErrorsAndUpsertsAreClasses():Void {
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, MongoWriteError)), "a write error is a class");
		Assert.isNull(TypeCheck.errorOf(Std.isOfType(null, MongoUpserted)), "an upsert is a class");
		Assert.isNull(TypeCheck.errorOf(({index: 0, code: 11000, codeName: "DuplicateKey", message: "duplicate"} : MongoWriteError)));
		Assert.isNull(TypeCheck.errorOf(({index: 0, id: 5} : MongoUpserted)));
	}

	public function testTheParserAndTheCursorsConstructorAreInternal():Void {
		Assert.notNull(TypeCheck.errorOf(new crossbyte.db.mongodb.bson.ExtendedJson.ExtendedJsonParser("{}", null)), "the parser");
		#if !js
		Assert.notNull(TypeCheck.errorOf(new MongoCursor(null, haxe.Int64.ofInt(0), "", [], -1, -1)), "a cursor made without a connection");
		#else
		Assert.pass();
		#end
	}
}
