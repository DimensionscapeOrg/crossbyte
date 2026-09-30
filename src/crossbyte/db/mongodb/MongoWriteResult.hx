package crossbyte.db.mongodb;

/**
	What an insert, update or delete did, as the server counted it.
**/
class MongoWriteResult {
	/** False for a write sent with write concern `w: 0`, whose outcome the server does not report. **/
	public var acknowledged(default, null):Bool;

	/** Documents inserted. **/
	public var inserted(default, null):Int = 0;

	/** Documents an update's filter matched, not counting upserts. **/
	public var matched(default, null):Int = 0;

	/** Documents an update changed; a match already holding the new values is not counted. **/
	public var modified(default, null):Int = 0;

	/** Documents deleted. **/
	public var deleted(default, null):Int = 0;

	/** The `_id` of each document an update inserted, with the position of the update that did it. **/
	public var upserted(default, null):Array<{index:Int, id:Dynamic}>;

	/**
		The `_id` of each document an insert sent, in order -- the ones it
		had, and the `ObjectId`s made for those without. After a failed ordered
		insert, the first `inserted` of them were stored.
	**/
	public var insertedIds(default, null):Array<Dynamic>;

	@:noCompletion public function new(acknowledged:Bool) {
		this.acknowledged = acknowledged;
		upserted = [];
		insertedIds = [];
	}

	@:noCompletion public function __add(inserted:Int, matched:Int, modified:Int, deleted:Int):Void {
		this.inserted += inserted;
		this.matched += matched;
		this.modified += modified;
		this.deleted += deleted;
	}
}
