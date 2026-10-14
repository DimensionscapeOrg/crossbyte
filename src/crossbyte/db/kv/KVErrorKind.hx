package crossbyte.db.kv;

/**
	Why a `KVError` was thrown, to switch on rather than its message.
**/
enum abstract KVErrorKind(Int) to Int {
	/**
		A record was written in another format than the one reading it: its
		`KVRecord.schema` is not the reader's.
	**/
	var SchemaMismatch = 1;

	/** A record's value is not one its reader reads: its bytes are not a whole value of its type. **/
	var Undecodable = 2;

	/**
		A stored value is past the store's `KVOptions.maxValueBytes`, so it is
		refused without being read. This store never writes one: something
		else wrote it, or the limit was lowered since.
	**/
	var TooLarge = 3;
}
