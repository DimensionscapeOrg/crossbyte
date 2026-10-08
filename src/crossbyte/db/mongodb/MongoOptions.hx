package crossbyte.db.mongodb;

import crossbyte.db.mongodb.MongoConfig.MongoWriteConcern;
import crossbyte.db.mongodb._internal.BsonWriter;
import crossbyte.db.mongodb.bson.BsonDocument;
import crossbyte.errors.ArgumentError;

/**
	Options for `MongoConnection.find`.

	Every field is optional, so an object literal of the ones wanted is
	enough: `connection.find("events", filter, {batchSize: 500, limit: 10})`.
	It is a class, not an anonymous structure, so each field is read
	directly; an object made at run time (parsed from JSON, say) has to
	be copied into one.

	Where the order of fields matters (`sort`, and `hint` given as keys),
	pass a `BsonDocument`, or an object of one field: an anonymous object's
	fields are not kept in order on most targets, and one with several is
	refused rather than sorted by chance.
**/
@:structInit
final class MongoFindOptions {
	public var sort:Dynamic = null;

	/** Which fields to return: `{name: 1, email: 1}` or `{password: 0}`. **/
	public var projection:Dynamic = null;

	public var skip:Null<Int> = null;

	/** At most this many documents; 0, the default, for no limit. **/
	public var limit:Null<Int> = null;

	/**
		Documents per batch, the first included: it is sent with the `find`,
		which sizes the first batch, and with each `getMore` after. The
		server decides when left out.
	**/
	public var batchSize:Null<Int> = null;

	/** An index to use, by name or by its keys. **/
	public var hint:MongoHint = null;

	/** Milliseconds the server may spend before failing with `MaxTimeMSExpired`. **/
	public var maxTimeMS:Null<Int> = null;

	public var collation:MongoCollation = null;
	public var comment:Dynamic = null;
}

/** Options for `MongoConnection.insert`; every field is optional, as `MongoFindOptions`'. **/
@:structInit
final class MongoInsertOptions {
	/**
		Stop at the first document that fails, the default; with `false` the
		server tries every document and reports each failure.
	**/
	public var ordered:Null<Bool> = null;

	public var writeConcern:MongoWriteConcern = null;
	public var bypassDocumentValidation:Null<Bool> = null;
}

/** Options for `MongoConnection.update`; every field is optional, as `MongoFindOptions`'. **/
@:structInit
final class MongoUpdateOptions {
	/** Insert a document when the filter matches none. **/
	public var upsert:Null<Bool> = null;

	/** Update every matching document, rather than only the first. **/
	public var multi:Null<Bool> = null;

	public var arrayFilters:Array<Dynamic> = null;
	public var hint:MongoHint = null;
	public var collation:MongoCollation = null;
	public var writeConcern:MongoWriteConcern = null;
}

/** Options for `MongoConnection.delete`; every field is optional, as `MongoFindOptions`'. **/
@:structInit
final class MongoDeleteOptions {
	/** Delete only the first matching document, rather than every one. **/
	public var justOne:Null<Bool> = null;

	public var hint:MongoHint = null;
	public var collation:MongoCollation = null;
	public var writeConcern:MongoWriteConcern = null;
}

/** Options for `MongoConnection.aggregate`; every field is optional, as `MongoFindOptions`'. **/
@:structInit
final class MongoAggregateOptions {
	/** Documents per batch, the first included, as `MongoFindOptions.batchSize`. **/
	public var batchSize:Null<Int> = null;

	public var maxTimeMS:Null<Int> = null;
	public var allowDiskUse:Null<Bool> = null;
	public var hint:MongoHint = null;
	public var collation:MongoCollation = null;
	public var comment:Dynamic = null;

	/** For a pipeline ending in `$out` or `$merge`, which writes. **/
	public var writeConcern:MongoWriteConcern = null;
}

/** Options for `MongoConnection.count`; every field is optional, as `MongoFindOptions`'. **/
@:structInit
final class MongoCountOptions {
	public var skip:Null<Int> = null;
	public var limit:Null<Int> = null;
	public var hint:MongoHint = null;
	public var maxTimeMS:Null<Int> = null;
}

/**
	An index for `MongoConnection.createIndexes`. `key` names the fields in
	order, so it is a `BsonDocument` or an object of one field; every other
	field is optional.
**/
@:structInit
final class MongoIndex {
	public var key:Dynamic;

	/** Made from the keys, as `name_1_age_-1`, when left out. **/
	public var name:String = null;

	public var unique:Null<Bool> = null;
	public var sparse:Null<Bool> = null;

	/**
		Seconds after the date in the indexed field at which the server
		deletes the document: a TTL index. The field must hold a BSON date:
		a `Date` or `BsonDateTime`, not text.
	**/
	public var expireAfterSeconds:Null<Int> = null;

	public var partialFilterExpression:Dynamic = null;
	public var collation:MongoCollation = null;
}

/**
	The index a query is to use: its name, or its keys (a `BsonDocument`,
	or an object of one field, since an anonymous object's fields are not
	kept in order on most targets).

	```haxe
	// Given connection:MongoConnection.
	connection.find("people", {last: "Hopper"}, {hint: "last_1"});
	connection.find("people", {last: "Hopper"}, {hint: {last: 1}});
	```
**/
abstract MongoHint(Dynamic) from String from BsonDocument to Dynamic {
	/**
		Keys as an anonymous object (or a `StringMap`); anything else that
		reaches here is refused.

		@throws ArgumentError When `keys` is some other object.
	**/
	@:from public static function fromKeys(keys:{}):MongoHint {
		if (keys != null && !BsonWriter.isPlainObject(keys) && !Std.isOfType(keys, haxe.ds.StringMap)) {
			throw new ArgumentError("A hint is an index's name, or its keys as a BsonDocument or an object of one field.");
		}

		return cast keys;
	}
}

/**
	How strings compare: MongoDB's collation document. `locale` is the one
	field it needs; the others default on the server.

	```haxe
	// Given connection:MongoConnection.
	connection.find("people", {last: "muller"}, {collation: {locale: "de", strength: 1}});
	```
**/
@:structInit
final class MongoCollation {
	/** An ICU locale, such as `fr` or `en_US`, or `simple` for comparing code points. **/
	public var locale:String;

	/** 1 compares base letters only, 2 accents too, 3 (the default) case too, 4 and 5 more. **/
	public var strength:Null<Int> = null;

	/** Compare case at strength 1 or 2. **/
	public var caseLevel:Null<Bool> = null;

	/** `upper`, `lower` or `off`: which case sorts first at strength 3. **/
	public var caseFirst:String = null;

	/** Compare digits as numbers, so "10" sorts after "9". **/
	public var numericOrdering:Null<Bool> = null;

	/** `non-ignorable` or `shifted`: whether spaces and punctuation count. **/
	public var alternate:String = null;

	/** With `alternate: "shifted"`, `punct` or `space`: what is ignored. **/
	public var maxVariable:String = null;

	/** Compare accents from the end of the string, as French dictionaries do. **/
	public var backwards:Null<Bool> = null;

	/** Normalize the text before comparing it. **/
	public var normalization:Null<Bool> = null;
}
