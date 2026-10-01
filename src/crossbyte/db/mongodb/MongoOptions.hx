package crossbyte.db.mongodb;

import crossbyte.db.mongodb.MongoConfig.MongoWriteConcern;

/**
	Options for `MongoConnection.find`.

	Where the order of fields matters, `sort`, and `hint` given as keys,
	pass a `BsonDocument`, or an object of one field: an anonymous object's
	fields are not kept in order on most targets, and one with several is
	refused rather than sorted by chance.
**/
typedef MongoFindOptions = {
	@:optional var sort:Dynamic;

	/** Which fields to return: `{name: 1, email: 1}` or `{password: 0}`. **/
	@:optional var projection:Dynamic;

	@:optional var skip:Int;

	/** At most this many documents; 0, the default, for no limit. **/
	@:optional var limit:Int;

	/**
		Documents per batch, the first included: it is sent with the `find`,
		which sizes the first batch, and with each `getMore` after. The
		server decides when left out.
	**/
	@:optional var batchSize:Int;

	/** An index to use, by name or by its keys. **/
	@:optional var hint:Dynamic;

	/** Milliseconds the server may spend before failing with `MaxTimeMSExpired`. **/
	@:optional var maxTimeMS:Int;

	@:optional var collation:Dynamic;
	@:optional var comment:Dynamic;
}

typedef MongoInsertOptions = {
	/**
		Stop at the first document that fails, the default; with `false` the
		server tries every document and reports each failure.
	**/
	@:optional var ordered:Bool;

	@:optional var writeConcern:MongoWriteConcern;
	@:optional var bypassDocumentValidation:Bool;
}

typedef MongoUpdateOptions = {
	/** Insert a document when the filter matches none. **/
	@:optional var upsert:Bool;

	/** Update every matching document, rather than only the first. **/
	@:optional var multi:Bool;

	@:optional var arrayFilters:Array<Dynamic>;
	@:optional var hint:Dynamic;
	@:optional var collation:Dynamic;
	@:optional var writeConcern:MongoWriteConcern;
}

typedef MongoDeleteOptions = {
	/** Delete only the first matching document, rather than every one. **/
	@:optional var justOne:Bool;

	@:optional var hint:Dynamic;
	@:optional var collation:Dynamic;
	@:optional var writeConcern:MongoWriteConcern;
}

typedef MongoAggregateOptions = {
	/** Documents per batch, the first included, as `MongoFindOptions.batchSize`. **/
	@:optional var batchSize:Int;
	@:optional var maxTimeMS:Int;
	@:optional var allowDiskUse:Bool;
	@:optional var hint:Dynamic;
	@:optional var collation:Dynamic;
	@:optional var comment:Dynamic;

	/** For a pipeline ending in `$out` or `$merge`, which writes. **/
	@:optional var writeConcern:MongoWriteConcern;
}

typedef MongoCountOptions = {
	@:optional var skip:Int;
	@:optional var limit:Int;
	@:optional var hint:Dynamic;
	@:optional var maxTimeMS:Int;
}

/**
	An index for `MongoConnection.createIndexes`. `key` names the fields in
	order, so it is a `BsonDocument` or an object of one field.
**/
typedef MongoIndex = {
	var key:Dynamic;

	/** Made from the keys, as `name_1_age_-1`, when left out. **/
	@:optional var name:String;

	@:optional var unique:Bool;
	@:optional var sparse:Bool;

	/**
		Seconds after the date in the indexed field at which the server
		deletes the document, a TTL index. The field must hold a BSON date:
		a `Date` or `BsonDateTime`, not text.
	**/
	@:optional var expireAfterSeconds:Int;

	@:optional var partialFilterExpression:Dynamic;
	@:optional var collation:Dynamic;
}
