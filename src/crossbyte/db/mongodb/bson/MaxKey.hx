package crossbyte.db.mongodb.bson;

/**
	BSON MaxKey, which sorts after every other value. There is one:
	`MaxKey.VALUE`.
**/
final class MaxKey {
	public static final VALUE:MaxKey = new MaxKey();

	private function new() {}

	public function toString():String {
		return "MaxKey";
	}
}
