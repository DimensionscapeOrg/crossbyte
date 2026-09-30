package crossbyte.db.mongodb.bson;

/**
	BSON MinKey, which sorts before every other value. There is one:
	`MinKey.VALUE`.
**/
final class MinKey {
	public static final VALUE:MinKey = new MinKey();

	private function new() {}

	public function toString():String {
		return "MinKey";
	}
}
