package crossbyte.db.sqlite;

enum abstract TempStoreMode(Int) from Int to Int {
	var DEFAULT = 0;
	var FILE = 1;
	var MEMORY = 2;

	public static function fromInt(v:Int):TempStoreMode {
		return switch (v) {
			case 1: FILE;
			case 2: MEMORY;
			default: DEFAULT;
		}
	}
}
