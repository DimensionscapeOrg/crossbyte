package crossbyte.db.sql.sqlite._internal;

#if cpp
import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
	One SQL statement prepared on a connection's `sqlite3`, kept to run again.

	hxcpp's glue prepares a statement from its text every time it is asked to
	run one, and has no way to bind a value. Here a statement is prepared
	once with `sqlite3_prepare_v2`, its `:name` parameters bound for each
	run, and reset between runs, so a repeated INSERT costs 0.36-0.63 µs
	where through the glue it costs 3.8-6.1 µs; the connection keeps the
	statements it has prepared by their text
	(`NativeSQLiteConnection.prepared`).

	Rows come back as the glue makes them (an Int, or an Int64 past 32 bits,
	a Float, a String, the blob's `BytesData`, a Bool for a column declared
	BOOL, null for NULL) in an anonymous object with fixed slots, ordered
	by the signed hash of the column names (see `AnonBuilder`), rather than
	in a hash map as the glue's are. Its errors read as the glue's do.

	Every call is a plain method, never `inline`: the C++ functions are
	declared by `@:cppFileCode` in this class's own file.
**/
@:noCompletion
@:buildXml('<include name="${HXCPP}/src/hx/libs/sqlite/Build.xml"/>')
@:cppFileCode('
#include <algorithm>

// The SQLite C API, declared rather than included: sqlite3.h is on the
// include path of the hxcpp sqlite files only.
extern "C" {
	struct sqlite3;
	struct sqlite3_stmt;
	int sqlite3_prepare_v2(struct sqlite3 *, const char *, int, struct sqlite3_stmt **, const char **);
	int sqlite3_step(struct sqlite3_stmt *);
	int sqlite3_reset(struct sqlite3_stmt *);
	int sqlite3_clear_bindings(struct sqlite3_stmt *);
	int sqlite3_finalize(struct sqlite3_stmt *);
	int sqlite3_column_count(struct sqlite3_stmt *);
	int sqlite3_column_type(struct sqlite3_stmt *, int);
	long long sqlite3_column_int64(struct sqlite3_stmt *, int);
	int sqlite3_column_int(struct sqlite3_stmt *, int);
	double sqlite3_column_double(struct sqlite3_stmt *, int);
	const unsigned char *sqlite3_column_text(struct sqlite3_stmt *, int);
	const void *sqlite3_column_blob(struct sqlite3_stmt *, int);
	int sqlite3_column_bytes(struct sqlite3_stmt *, int);
	const char *sqlite3_column_name(struct sqlite3_stmt *, int);
	const char *sqlite3_column_decltype(struct sqlite3_stmt *, int);
	int sqlite3_bind_parameter_count(struct sqlite3_stmt *);
	const char *sqlite3_bind_parameter_name(struct sqlite3_stmt *, int);
	int sqlite3_bind_null(struct sqlite3_stmt *, int);
	int sqlite3_bind_int(struct sqlite3_stmt *, int, int);
	int sqlite3_bind_int64(struct sqlite3_stmt *, int, long long);
	int sqlite3_bind_double(struct sqlite3_stmt *, int, double);
	int sqlite3_bind_text(struct sqlite3_stmt *, int, const char *, int, void (*)(void *));
	int sqlite3_bind_blob(struct sqlite3_stmt *, int, const void *, int, void (*)(void *));
	int sqlite3_changes(struct sqlite3 *);
	const char *sqlite3_errmsg(struct sqlite3 *);
	int sqlite3_stmt_status(struct sqlite3_stmt *, int, int);
	int sqlite3_close(struct sqlite3 *);
}

// SQLITE_STMTSTATUS_REPREPARE: how many times SQLite has prepared the
// statement again by itself, after the schema changed under it.
#define CROSSBYTE_SQLITE_REPREPARES 5

#define CROSSBYTE_SQLITE_ROW 100
#define CROSSBYTE_SQLITE_DONE 101
#define CROSSBYTE_SQLITE_BUSY 5
#define CROSSBYTE_SQLITE_LOCKED 6
#define CROSSBYTE_SQLITE_INTEGER 1
#define CROSSBYTE_SQLITE_FLOAT 2
#define CROSSBYTE_SQLITE_TEXT 3
#define CROSSBYTE_SQLITE_BLOB 4
#define CROSSBYTE_SQLITE_NULL 5
// SQLITE_TRANSIENT: SQLite copies a bound value before the call returns.
#define CROSSBYTE_SQLITE_TRANSIENT ((void (*)(void *))-1)

// A prepared statement and what reading its rows needs, made once.
struct crossbyte_sqlite_stmt {
	struct sqlite3 *db;
	// Null for text that holds no statement at all: whitespace, a comment.
	struct sqlite3_stmt *st;
	int ncols;
	// The column names, permanent: the rows hold them without marking them.
	String *names;
	// The fixed slot of each column, or null when the rows use the hash map
	// (a name that is not ASCII, which hxcpp cannot find in a slot).
	int *slots;
	// Whether each column is declared BOOL, read back as a Bool.
	char *bools;
	// SQLite\'s count of its own preparations of it when its columns were
	// last read, and whether the run under way has stepped yet: the first
	// step of a run is where SQLite prepares it again after a schema change,
	// and its columns may then be others: a SELECT * after ALTER TABLE.
	int reprepares;
	int started;
	// The connection\'s list of the statements prepared on it and not yet
	// freed (see crossbyte_sqlite_owner).
	struct crossbyte_sqlite_owner *owner;
	struct crossbyte_sqlite_stmt *prev;
	struct crossbyte_sqlite_stmt *next;
};

// One per connection: every statement prepared on it and not yet freed, so
// that a connection the collector takes unclosed can finalize them and then
// close (crossbyte_sqlite_owner_let_go). Used by the connection\'s thread only.
struct crossbyte_sqlite_owner {
	struct crossbyte_sqlite_stmt *head;
};

static void *crossbyte_sqlite_owner_new() {
	return calloc(1, sizeof(crossbyte_sqlite_owner));
}

static void crossbyte_sqlite_owner_free(void *p) {
	crossbyte_sqlite_owner *owner = (crossbyte_sqlite_owner *)p;

	for (crossbyte_sqlite_stmt *s = owner->head; s; s = s->next) s->owner = 0;

	free(owner);
}

static void crossbyte_sqlite_unlink(crossbyte_sqlite_stmt *s) {
	if (!s->owner) return;

	if (s->prev) s->prev->next = s->next;
	else s->owner->head = s->next;

	if (s->next) s->next->prev = s->prev;

	s->owner = 0;
	s->prev = 0;
	s->next = 0;
}

struct crossbyte_sqlite_by_hash {
	String *names;
	bool operator()(int a, int b) const {
		// Signed, as Anon_obj compares: hash() answers unsigned.
		int ha = (int)names[a].hash();
		int hb = (int)names[b].hash();
		return ha != hb ? ha < hb : a < b;
	}
};

// Finalizes it and lets go of what reading it needed: it then has no
// columns, and every read of it finds none. In a GC-free zone unless
// `collecting`, called from a finalizer inside a collection.
static void crossbyte_sqlite_stmt_release(crossbyte_sqlite_stmt *s, bool collecting = false) {
	if (s->st) {
		if (collecting) {
			sqlite3_finalize(s->st);
		} else {
			__hxcpp_enter_gc_free_zone();
			sqlite3_finalize(s->st);
			__hxcpp_exit_gc_free_zone();
		}

		s->st = 0;
	}

	if (s->names) free(s->names);
	if (s->slots) free(s->slots);
	if (s->bools) free(s->bools);
	s->names = 0;
	s->slots = 0;
	s->bools = 0;
	s->ncols = 0;
}

// A connection the collector has taken without its close(): every statement
// still prepared on it finalized, then the connection closed, which SQLite
// refuses while one is left. Called from the connection\'s finalizer, inside
// a collection: it touches nothing of the GC. A statement\'s record stays
// allocated, empty, for the object that holds it.
static void crossbyte_sqlite_owner_let_go(void *p, void *db) {
	crossbyte_sqlite_owner *owner = (crossbyte_sqlite_owner *)p;

	if (owner) {
		crossbyte_sqlite_stmt *s = owner->head;

		while (s) {
			crossbyte_sqlite_stmt *next = s->next;
			crossbyte_sqlite_stmt_release(s, true);
			s->owner = 0;
			s->prev = 0;
			s->next = 0;
			s = next;
		}

		free(owner);
	}

	if (db) sqlite3_close((struct sqlite3 *)db);
}

// Reads the statement\'s columns: their names, made permanent, whether each
// is declared BOOL, and the fixed slot of each, by the signed hash of its
// name. Answers false for a name given twice, which the glue refuses; read
// again after a schema change, such a result falls back to the hash map,
// the later column\'s value winning, rather than failing mid-run.
static bool crossbyte_sqlite_stmt_describe(crossbyte_sqlite_stmt *s) {
	struct sqlite3_stmt *st = s->st;

	if (s->names) free(s->names);
	if (s->slots) free(s->slots);
	if (s->bools) free(s->bools);
	s->names = 0;
	s->slots = 0;
	s->bools = 0;
	s->ncols = st ? sqlite3_column_count(st) : 0;
	s->reprepares = st ? sqlite3_stmt_status(st, CROSSBYTE_SQLITE_REPREPARES, 0) : 0;

	if (s->ncols <= 0) return true;

	int n = s->ncols;
	s->names = (String *)calloc(n, sizeof(String));
	s->bools = (char *)calloc(n, 1);
	bool ascii = true;
	bool distinct = true;

	for (int i = 0; i < n; i++) {
		s->names[i] = String::createPermanent(sqlite3_column_name(st, i), -1);

		for (int j = 0; j < i && distinct; j++) {
			if (s->names[j] == s->names[i]) distinct = false;
		}

		const char *type = sqlite3_column_decltype(st, i);
		s->bools[i] = type ? (strcmp(type, "BOOL") == 0) : 0;

		if (!s->names[i].isAsciiEncoded()) ascii = false;
	}

	if (ascii && distinct) {
		int *order = (int *)malloc(sizeof(int) * n);

		for (int i = 0; i < n; i++) order[i] = i;

		crossbyte_sqlite_by_hash by = {s->names};
		std::sort(order, order + n, by);
		s->slots = (int *)malloc(sizeof(int) * n);

		for (int k = 0; k < n; k++) s->slots[order[k]] = k;

		free(order);
	}

	return distinct;
}

static void *crossbyte_sqlite_stmt_prepare(void *db, void *owner, String sql) {
	int byteLength = 0;
	const char *sqlStr = sql.utf8_str(0, true, &byteLength);
	struct sqlite3_stmt *st = 0;
	const char *tail = 0;
	__hxcpp_enter_gc_free_zone();
	int err = sqlite3_prepare_v2((struct sqlite3 *)db, sqlStr, byteLength, &st, &tail);
	__hxcpp_exit_gc_free_zone();

	if (err != 0) {
		// As the glue words it: the statement, then SQLite\'s message.
		hx::Throw(HX_CSTRING("Sqlite error in ") + sql + HX_CSTRING(" : ") + String(sqlite3_errmsg((struct sqlite3 *)db)));
	}

	if (tail && *tail) {
		__hxcpp_enter_gc_free_zone();
		sqlite3_finalize(st);
		__hxcpp_exit_gc_free_zone();
		hx::Throw(HX_CSTRING("Cannot execute several SQL requests at the same time"));
	}

	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)calloc(1, sizeof(crossbyte_sqlite_stmt));
	s->db = (struct sqlite3 *)db;
	s->st = st;

	if (!crossbyte_sqlite_stmt_describe(s)) {
		crossbyte_sqlite_stmt_release(s);
		free(s);
		hx::Throw(HX_CSTRING("Error, same field is two times in the request ") + sql);
	}

	if (owner) {
		crossbyte_sqlite_owner *o = (crossbyte_sqlite_owner *)owner;
		s->owner = o;
		s->next = o->head;

		if (o->head) o->head->prev = s;

		o->head = s;
	}

	return s;
}

static void crossbyte_sqlite_stmt_free(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;
	crossbyte_sqlite_unlink(s);
	crossbyte_sqlite_stmt_release(s);
	free(s);
}

static int crossbyte_sqlite_stmt_columns(void *p) {
	return ((crossbyte_sqlite_stmt *)p)->ncols;
}

static int crossbyte_sqlite_stmt_params(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;
	return s->st ? sqlite3_bind_parameter_count(s->st) : 0;
}

// The name of parameter i, counted from 1, as written with its prefix: a
// colon, an at sign, a dollar sign or a question mark and its number; null
// for a bare question mark.
static String crossbyte_sqlite_stmt_param_name(void *p, int i) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;
	const char *name = s->st ? sqlite3_bind_parameter_name(s->st, i) : 0;
	return name ? String(name) : String();
}

// Ready for another run: the last one ended, every value unbound.
static void crossbyte_sqlite_stmt_clear(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;

	if (s->st) {
		__hxcpp_enter_gc_free_zone();
		sqlite3_reset(s->st);
		__hxcpp_exit_gc_free_zone();
		sqlite3_clear_bindings(s->st);
	}

	s->started = 0;
}

static void crossbyte_sqlite_stmt_reset(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;

	if (s->st) {
		__hxcpp_enter_gc_free_zone();
		sqlite3_reset(s->st);
		__hxcpp_exit_gc_free_zone();
	}

	s->started = 0;
}

// Binds one of the values a literal would have written: null, a Bool as 1 or
// 0, an Int, a Float (whole and within 2^53 as an integer), an Int64, or a
// String, as text, or as a blob of its UTF-8 when it holds a NUL, which a
// quoted literal cannot carry. Answers false for anything else, which the
// caller binds itself.
static bool crossbyte_sqlite_stmt_bind(void *p, int i, Dynamic v) {
	struct sqlite3_stmt *st = ((crossbyte_sqlite_stmt *)p)->st;

	if (!st) return true;

	if (v.mPtr == 0) {
		sqlite3_bind_null(st, i);
		return true;
	}

	switch (v->__GetType()) {
		case vtBool:
			sqlite3_bind_int(st, i, v->__ToInt() ? 1 : 0);
			return true;
		case vtInt:
			sqlite3_bind_int64(st, i, (long long)v->__ToInt());
			return true;
		case vtInt64:
			sqlite3_bind_int64(st, i, (long long)v->__ToInt64());
			return true;
		case vtFloat: {
			double d = v->__ToDouble();

			if (d == d && d >= -9007199254740992.0 && d <= 9007199254740992.0 && (double)(long long)d == d)
				sqlite3_bind_int64(st, i, (long long)d);
			else
				sqlite3_bind_double(st, i, d);
			return true;
		}
		case vtString: {
			String text = v->toString();
			int length = 0;
			const char *utf8 = text.utf8_str(0, true, &length);

			if (memchr(utf8, 0, length))
				sqlite3_bind_blob(st, i, utf8, length, CROSSBYTE_SQLITE_TRANSIENT);
			else
				sqlite3_bind_text(st, i, utf8, length, CROSSBYTE_SQLITE_TRANSIENT);
			return true;
		}
		default:
			return false;
	}
}

static void crossbyte_sqlite_stmt_bind_text(void *p, int i, String text) {
	struct sqlite3_stmt *st = ((crossbyte_sqlite_stmt *)p)->st;

	if (!st) return;

	int length = 0;
	const char *utf8 = text.utf8_str(0, true, &length);
	sqlite3_bind_text(st, i, utf8, length, CROSSBYTE_SQLITE_TRANSIENT);
}

static void crossbyte_sqlite_stmt_bind_blob(void *p, int i, Array<unsigned char> data, int length) {
	struct sqlite3_stmt *st = ((crossbyte_sqlite_stmt *)p)->st;

	if (!st) return;

	// A zero-length blob, not NULL: SQLite reads a null pointer as NULL.
	static const char empty = 0;
	sqlite3_bind_blob(st, i, length > 0 ? (const void *)data->GetBase() : (const void *)&empty, length, CROSSBYTE_SQLITE_TRANSIENT);
}

// 1 for a row, 0 once there are none; throws as the glue does.
static int crossbyte_sqlite_stmt_step(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;

	if (!s->st) return 0;

	__hxcpp_enter_gc_free_zone();
	int rc = sqlite3_step(s->st);
	__hxcpp_exit_gc_free_zone();

	if (!s->started && (rc == CROSSBYTE_SQLITE_ROW || rc == CROSSBYTE_SQLITE_DONE)) {
		s->started = 1;

		// Prepared again by SQLite as it stepped, the schema having changed:
		// its columns may be others now.
		if (sqlite3_stmt_status(s->st, CROSSBYTE_SQLITE_REPREPARES, 0) != s->reprepares) crossbyte_sqlite_stmt_describe(s);
	}

	if (rc == CROSSBYTE_SQLITE_ROW) return 1;
	if (rc == CROSSBYTE_SQLITE_DONE) return 0;

	// prepare_v2 has the step\'s own error in errmsg already, which the glue
	// had to finalize to get. Read before the reset that leaves the statement
	// ready for its next run.
	String message = String(sqlite3_errmsg(s->db));
	__hxcpp_enter_gc_free_zone();
	sqlite3_reset(s->st);
	__hxcpp_exit_gc_free_zone();

	if (rc == CROSSBYTE_SQLITE_BUSY || rc == CROSSBYTE_SQLITE_LOCKED)
		hx::Throw(HX_CSTRING("Database is busy : ") + message);

	hx::Throw(HX_CSTRING("Sqlite error : ") + message);
	return 0;
}

static Dynamic crossbyte_sqlite_stmt_value(crossbyte_sqlite_stmt *s, int i) {
	struct sqlite3_stmt *st = s->st;

	switch (sqlite3_column_type(st, i)) {
		case CROSSBYTE_SQLITE_INTEGER: {
			if (s->bools[i]) return Dynamic(bool(sqlite3_column_int(st, i)));
			long long v = sqlite3_column_int64(st, i);
			if (v >= -2147483647LL - 1 && v <= 2147483647LL) return Dynamic((int)v);
			return Dynamic((cpp::Int64)v);
		}
		case CROSSBYTE_SQLITE_FLOAT:
			return Dynamic(Float(sqlite3_column_double(st, i)));
		case CROSSBYTE_SQLITE_TEXT:
			return Dynamic(String((const char *)sqlite3_column_text(st, i)));
		case CROSSBYTE_SQLITE_BLOB: {
			int size = sqlite3_column_bytes(st, i);
			return Array_obj<unsigned char>::fromData((const unsigned char *)sqlite3_column_blob(st, i), size);
		}
		default:
			return null();
	}
}

static ::cpp::Variant crossbyte_sqlite_stmt_variant(crossbyte_sqlite_stmt *s, int i) {
	struct sqlite3_stmt *st = s->st;

	switch (sqlite3_column_type(st, i)) {
		case CROSSBYTE_SQLITE_INTEGER: {
			if (s->bools[i]) return ::cpp::Variant((bool)(sqlite3_column_int(st, i) != 0));
			long long v = sqlite3_column_int64(st, i);
			if (v >= -2147483647LL - 1 && v <= 2147483647LL) return ::cpp::Variant((int)v);
			return ::cpp::Variant(Dynamic((cpp::Int64)v));
		}
		case CROSSBYTE_SQLITE_FLOAT:
			return ::cpp::Variant(sqlite3_column_double(st, i));
		case CROSSBYTE_SQLITE_TEXT:
			return ::cpp::Variant(String((const char *)sqlite3_column_text(st, i)));
		case CROSSBYTE_SQLITE_BLOB: {
			int size = sqlite3_column_bytes(st, i);
			return ::cpp::Variant(Dynamic(Array_obj<unsigned char>::fromData((const unsigned char *)sqlite3_column_blob(st, i), size)));
		}
		default:
			return ::cpp::Variant();
	}
}

// The row the last step stood on, as an object.
static Dynamic crossbyte_sqlite_stmt_row(void *p) {
	crossbyte_sqlite_stmt *s = (crossbyte_sqlite_stmt *)p;
	int n = s->ncols;

	if (s->slots) {
		hx::Anon row = hx::Anon_obj::Create(n);

		for (int i = 0; i < n; i++) row->setFixed(s->slots[i], s->names[i], crossbyte_sqlite_stmt_variant(s, i));

		return row;
	}

	hx::Anon row = hx::Anon_obj::Create();

	for (int i = 0; i < n; i++) row->__SetField(s->names[i], crossbyte_sqlite_stmt_value(s, i), hx::paccDynamic);

	return row;
}

static int crossbyte_sqlite_stmt_changes(void *p) {
	return sqlite3_changes(((crossbyte_sqlite_stmt *)p)->db);
}

static String crossbyte_sqlite_stmt_column_name(void *p, int i) {
	return ((crossbyte_sqlite_stmt *)p)->names[i];
}

// What a typed cursor reads: the type SQLite holds, and each conversion.
static int crossbyte_sqlite_stmt_type(void *p, int i) {
	return sqlite3_column_type(((crossbyte_sqlite_stmt *)p)->st, i);
}

static int crossbyte_sqlite_stmt_int(void *p, int i) {
	return sqlite3_column_int(((crossbyte_sqlite_stmt *)p)->st, i);
}

static double crossbyte_sqlite_stmt_double(void *p, int i) {
	return sqlite3_column_double(((crossbyte_sqlite_stmt *)p)->st, i);
}

static String crossbyte_sqlite_stmt_text(void *p, int i) {
	struct sqlite3_stmt *st = ((crossbyte_sqlite_stmt *)p)->st;
	const unsigned char *text = sqlite3_column_text(st, i);

	if (!text) return String();

	return String::create((const char *)text, sqlite3_column_bytes(st, i));
}

static Array<unsigned char> crossbyte_sqlite_stmt_blob(void *p, int i) {
	struct sqlite3_stmt *st = ((crossbyte_sqlite_stmt *)p)->st;
	const void *blob = sqlite3_column_blob(st, i);
	int size = sqlite3_column_bytes(st, i);

	if (!blob && size == 0 && sqlite3_column_type(st, i) == CROSSBYTE_SQLITE_NULL) return null();

	return Array_obj<unsigned char>::fromData((const unsigned char *)blob, size);
}

static Dynamic crossbyte_sqlite_stmt_column(void *p, int i) {
	return crossbyte_sqlite_stmt_value((crossbyte_sqlite_stmt *)p, i);
}
')
class NativeSQLiteStatement {
	/** The type SQLite holds a column's value as: `sqlite3_column_type`. **/
	public static inline var INTEGER:Int = 1;

	public static inline var FLOAT:Int = 2;
	public static inline var TEXT:Int = 3;
	public static inline var BLOB:Int = 4;
	public static inline var NULL:Int = 5;

	/** The text it was prepared from. **/
	public var text(default, null):String;

	/**
		How many columns its rows have; 0 for a statement that returns none.
		Read again after the first step of a run: SQLite prepares a statement
		again there when the schema has changed, and a `SELECT *` then has
		other columns.
	**/
	public var columns(get, never):Int;

	/** Whether a run of it is under way: taken by the connection and not yet given back. **/
	public var busy:Bool = false;

	/** Whether the connection keeps it for its text; one not kept is freed when given back. **/
	public var kept:Bool = true;

	@:noCompletion private var __record:cpp.Pointer<cpp.Void>;

	// Each parameter's name without its colon, by its index from 0, or null
	// for one that is not a `:name` (a `?`, `$name` or `@name`), which is
	// never bound, and reads as NULL.
	@:noCompletion private var __params:Array<String>;

	/**
		Prepares `text` on the connection `db` (`sqlite3*`), listed with
		`owner`, the connection's record from `newOwner()`.

		@throws String As the glue throws for text SQLite refuses, holds
		more than one statement, or names a column twice.
	**/
	public static function prepare(db:cpp.Pointer<cpp.Void>, owner:cpp.Pointer<cpp.Void>, text:String):NativeSQLiteStatement {
		var record:cpp.Pointer<cpp.Void> = __prepare(db, owner, text);
		return new NativeSQLiteStatement(record, text);
	}

	/**
		A connection's record of the statements prepared on it and not yet
		freed. Freed with `freeOwner` once the connection has freed them
		itself and closed, or by `letGo`.
	**/
	public static function newOwner():cpp.Pointer<cpp.Void> {
		return __ownerNew();
	}

	public static function freeOwner(owner:cpp.Pointer<cpp.Void>):Void {
		__ownerFree(owner);
	}

	/**
		For a connection the collector has taken without its `close()`, from
		its finalizer: finalizes every statement `owner` lists, frees `owner`,
		and closes `db`. Allocates nothing.
	**/
	public static function letGo(owner:cpp.Pointer<cpp.Void>, db:cpp.Pointer<cpp.Void>):Void {
		__ownerLetGo(owner, db);
	}

	@:noCompletion private function new(record:cpp.Pointer<cpp.Void>, text:String) {
		__record = record;
		this.text = text;
		var count:Int = __paramCount(record);
		__params = [];

		for (i in 0...count) {
			var name:String = __paramName(record, i + 1);
			__params.push(name != null && name.length > 1 && StringTools.fastCodeAt(name, 0) == ":".code ? name.substr(1) : null);
		}
	}

	private function get_columns():Int {
		var record:cpp.Pointer<cpp.Void> = __record;
		return record == null ? 0 : __columns(record);
	}

	/** Whether it has parameters to bind. **/
	public function hasParameters():Bool {
		return __params.length > 0;
	}

	/**
		Ends the run before, unbinds every value, and binds `parameters` to
		the `:name`s the statement has; one with no value reads as NULL.
	**/
	public function bind(parameters:Null<StringMap<Dynamic>>):Void {
		__clear(__record);

		if (parameters == null) {
			return;
		}

		for (i in 0...__params.length) {
			var name:String = __params[i];

			if (name == null || !parameters.exists(name)) {
				continue;
			}

			var value:Dynamic = parameters.get(name);

			if (__bind(__record, i + 1, value)) {
				continue;
			}

			if (Std.isOfType(value, Bytes)) {
				var bytes:Bytes = value;
				__bindBlob(__record, i + 1, bytes.getData(), bytes.length);
			} else {
				// A Date, as Std.string writes it, or anything else as its
				// text.
				__bindText(__record, i + 1, Std.string(value));
			}
		}
	}

	/** Ends the run before, keeping what is bound. **/
	public function reset():Void {
		__reset(__record);
	}

	/**
		Steps to the next row: true when there is one.

		@throws String As the glue throws: "Sqlite error : ...", or "Database
		is busy : ..." for SQLITE_BUSY and SQLITE_LOCKED.
	**/
	public function step():Bool {
		return __step(__record) != 0;
	}

	/** The row the last `step()` stood on, as an object. **/
	public function row():Dynamic {
		return __row(__record);
	}

	/** The rows the connection's last write changed. **/
	public function changes():Int {
		return __changes(__record);
	}

	public function columnName(index:Int):String {
		return __columnName(__record, index);
	}

	public function columnType(index:Int):Int {
		return __type(__record, index);
	}

	public function columnInt(index:Int):Int {
		return __int(__record, index);
	}

	public function columnFloat(index:Int):Float {
		return __double(__record, index);
	}

	public function columnText(index:Int):String {
		return __text(__record, index);
	}

	public function columnBlob(index:Int):Null<haxe.io.BytesData> {
		return __blob(__record, index);
	}

	public function columnValue(index:Int):Dynamic {
		return __column(__record, index);
	}

	/** Finalizes it. Nothing may use it after. **/
	public function free():Void {
		var record:cpp.Pointer<cpp.Void> = __record;

		if (record != null) {
			__record = null;
			__free(record);
		}
	}

	@:native("crossbyte_sqlite_stmt_prepare")
	extern private static function __prepare(db:cpp.Pointer<cpp.Void>, owner:cpp.Pointer<cpp.Void>, sql:String):cpp.Pointer<cpp.Void>;

	@:native("crossbyte_sqlite_owner_new")
	extern private static function __ownerNew():cpp.Pointer<cpp.Void>;

	@:native("crossbyte_sqlite_owner_free")
	extern private static function __ownerFree(owner:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_owner_let_go")
	extern private static function __ownerLetGo(owner:cpp.Pointer<cpp.Void>, db:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_stmt_free")
	extern private static function __free(record:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_stmt_columns")
	extern private static function __columns(record:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_stmt_params")
	extern private static function __paramCount(record:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_stmt_param_name")
	extern private static function __paramName(record:cpp.Pointer<cpp.Void>, index:Int):String;

	@:native("crossbyte_sqlite_stmt_clear")
	extern private static function __clear(record:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_stmt_reset")
	extern private static function __reset(record:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_stmt_bind")
	extern private static function __bind(record:cpp.Pointer<cpp.Void>, index:Int, value:Dynamic):Bool;

	@:native("crossbyte_sqlite_stmt_bind_text")
	extern private static function __bindText(record:cpp.Pointer<cpp.Void>, index:Int, text:String):Void;

	@:native("crossbyte_sqlite_stmt_bind_blob")
	extern private static function __bindBlob(record:cpp.Pointer<cpp.Void>, index:Int, data:haxe.io.BytesData, length:Int):Void;

	@:native("crossbyte_sqlite_stmt_step")
	extern private static function __step(record:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_stmt_row")
	extern private static function __row(record:cpp.Pointer<cpp.Void>):Dynamic;

	@:native("crossbyte_sqlite_stmt_changes")
	extern private static function __changes(record:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_stmt_column_name")
	extern private static function __columnName(record:cpp.Pointer<cpp.Void>, index:Int):String;

	@:native("crossbyte_sqlite_stmt_type")
	extern private static function __type(record:cpp.Pointer<cpp.Void>, index:Int):Int;

	@:native("crossbyte_sqlite_stmt_int")
	extern private static function __int(record:cpp.Pointer<cpp.Void>, index:Int):Int;

	@:native("crossbyte_sqlite_stmt_double")
	extern private static function __double(record:cpp.Pointer<cpp.Void>, index:Int):Float;

	@:native("crossbyte_sqlite_stmt_text")
	extern private static function __text(record:cpp.Pointer<cpp.Void>, index:Int):String;

	@:native("crossbyte_sqlite_stmt_blob")
	extern private static function __blob(record:cpp.Pointer<cpp.Void>, index:Int):haxe.io.BytesData;

	@:native("crossbyte_sqlite_stmt_column")
	extern private static function __column(record:cpp.Pointer<cpp.Void>, index:Int):Dynamic;
}
#end
