package crossbyte.db.kv;

/**
	A record as a `KVRepo` reads it: its value decoded, its key within the
	repository (the repository's prefix taken off), and its revision and
	stamps as `KVRecord` has them.
**/
final class KVItem<T> {
	/** The key within the repository. **/
	public final key:String;

	/** The value, decoded by the repository's codec. **/
	public final value:T;

	/** As `KVRecord.revision`: what `KVRepo.compareAndSet` takes. **/
	public final revision:Float;

	/** As `KVRecord.createdAt`. **/
	public final createdAt:Float;

	/** As `KVRecord.updatedAt`. **/
	public final updatedAt:Float;

	public function new(key:String, value:T, revision:Float, createdAt:Float, updatedAt:Float) {
		this.key = key;
		this.value = value;
		this.revision = revision;
		this.createdAt = createdAt;
		this.updatedAt = updatedAt;
	}
}
