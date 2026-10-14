/*
 * A stand-in for libpq that needs no server, so the native Postgres bridge can
 * be tested in the ordinary native suite rather than only in the CI job that
 * has a database.
 *
 * It exports the libpq symbols the bridge resolves, with the same signatures,
 * and answers a handful of statements the tests use:
 *
 *   SELECT $1::text     echoes its first parameter as one row
 *   SELECT 1            one row holding "1"
 *   fake:conninfo       one row holding the connection string it was opened with
 *   fake:count <n>      n rows of one column, "n", holding 1 to n, for paging
 *   fake:affect <n>     a write that changed n rows, n as the server writes it
 *                       in the command tag, past 2^31 if asked
 *   fake:sleep <ms>     blocks for that long, or until PQcancel, the way a slow
 *                       query or a lock wait blocks inside PQexec
 *   fake:fail           fails, aborting any open transaction
 *   fake:fail-next-commit
 *                       makes the next COMMIT fail outright, as a serialization
 *                       failure or a deferred constraint does
 *   fake:live           how many connections are open in the process: made by
 *                       PQconnectdb and not yet given to PQfinish
 *   fake:transaction    this connection's transaction as the server holds it:
 *                       idle, open or aborted
 *   BEGIN / COMMIT / ROLLBACK
 *                       tracked the way the server tracks them: a COMMIT in an
 *                       aborted transaction succeeds with the tag ROLLBACK, and
 *                       PQtransactionStatus reports the state
 *
 * and the statements `PostgresKVStore` sends, against one table of records
 * the whole process shares, as a server's table is shared by its connections
 * (see "The key/value table" below; fake:kv-clear empties it). A ROLLBACK puts
 * the table back as it was at the BEGIN, which is enough for a test that does
 * not write from two connections inside one transaction.
 *
 * A host named "fail-<anything>" refuses the connection with a message naming
 * it, and one named "slow-connect" takes 1.5 seconds to connect.
 *
 * Built as its own shared library by FakeLibPQBuild.xml, beside the test
 * binary, and loaded through PostgresConfig.libraryPath exactly as a real
 * libpq would be.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#define FAKEPQ_EXPORT __declspec(dllexport)
static void fakeSleepMs(int ms) {
	Sleep((DWORD)ms);
}
/* Connections are made and finished on several threads at once. */
static volatile LONG fakeLive = 0;
static void fakeCountLive(int delta) {
	InterlockedExchangeAdd(&fakeLive, (LONG)delta);
}
static SRWLOCK fakeTableLock = SRWLOCK_INIT;
static void fakeLockTable(void) {
	AcquireSRWLockExclusive(&fakeTableLock);
}
static void fakeUnlockTable(void) {
	ReleaseSRWLockExclusive(&fakeTableLock);
}
#else
#include <pthread.h>
#include <time.h>
#define FAKEPQ_EXPORT __attribute__((visibility("default")))
static void fakeSleepMs(int ms) {
	struct timespec ts;
	ts.tv_sec = ms / 1000;
	ts.tv_nsec = (long)(ms % 1000) * 1000000L;
	nanosleep(&ts, NULL);
}
static volatile long fakeLive = 0;
static void fakeCountLive(int delta) {
	__sync_fetch_and_add(&fakeLive, (long)delta);
}
static pthread_mutex_t fakeTableLock = PTHREAD_MUTEX_INITIALIZER;
static void fakeLockTable(void) {
	pthread_mutex_lock(&fakeTableLock);
}
static void fakeUnlockTable(void) {
	pthread_mutex_unlock(&fakeTableLock);
}
#endif

typedef unsigned int Oid;

enum {
	CONNECTION_OK = 0,
	CONNECTION_BAD = 1
};

enum {
	PGRES_EMPTY_QUERY = 0,
	PGRES_COMMAND_OK = 1,
	PGRES_TUPLES_OK = 2,
	PGRES_FATAL_ERROR = 7
};

enum {
	TX_IDLE = 0,
	TX_OPEN = 1,
	TX_ABORTED = 2
};

enum {
	PQTRANS_IDLE = 0,
	PQTRANS_ACTIVE = 1,
	PQTRANS_INTRANS = 2,
	PQTRANS_INERROR = 3,
	PQTRANS_UNKNOWN = 4
};

/* One record of the key/value table. */
typedef struct FakeRecord {
	char* key;
	unsigned char* value;
	int valueLength;
	long long revision;
	char created[48];
	char updated[48];
	int deleted;
	char schema[16];
} FakeRecord;

typedef struct FakeTable {
	FakeRecord* records;
	int count;
	int capacity;
} FakeTable;

typedef struct FakeConn {
	int status;
	int transaction;
	int failNextCommit;
	/* Written by PQcancel on another thread, read by the sleeping statement. */
	volatile int cancelled;
	char* conninfo;
	char error[512];
	/* The key/value table as it was at this connection's BEGIN. */
	FakeTable* snapshot;
} FakeConn;

typedef struct FakeCancel {
	FakeConn* conn;
} FakeCancel;

/* A result of `fields` columns and `rows` rows; a cell is NULL for SQL NULL. */
typedef struct FakeResult {
	int status;
	int fields;
	int rows;
	char** names;
	char** cells;
	int* lengths;
	char command[48];
	/* Room for any count PQcmdTuples can give: 2^64 - 1 is twenty digits. */
	char tuples[24];
} FakeResult;

static char* fakeDup(const char* text, size_t length) {
	char* out = (char*)malloc(length + 1);

	if (out != NULL) {
		if (length > 0) {
			memcpy(out, text, length);
		}
		out[length] = '\0';
	}

	return out;
}

static FakeResult* fakeResult(int status, const char* command) {
	FakeResult* result = (FakeResult*)calloc(1, sizeof(FakeResult));

	if (result == NULL) {
		return NULL;
	}

	result->status = status;
	snprintf(result->command, sizeof(result->command), "%s", command == NULL ? "" : command);
	return result;
}

/* Rows of the columns `names`, `count` of them, every cell NULL until set. */
static FakeResult* fakeTuples(const char* const* names, int count, int rows) {
	FakeResult* result = fakeResult(PGRES_TUPLES_OK, "SELECT");
	int i;

	if (result == NULL) {
		return NULL;
	}

	result->fields = count;
	result->rows = rows;
	result->names = (char**)calloc((size_t)(count > 0 ? count : 1), sizeof(char*));
	result->cells = (char**)calloc((size_t)(count * rows > 0 ? count * rows : 1), sizeof(char*));
	result->lengths = (int*)calloc((size_t)(count * rows > 0 ? count * rows : 1), sizeof(int));

	for (i = 0; i < count; i++) {
		result->names[i] = fakeDup(names[i], strlen(names[i]));
	}

	snprintf(result->command, sizeof(result->command), "SELECT %d", rows);
	snprintf(result->tuples, sizeof(result->tuples), "%d", rows);
	return result;
}

static void fakeCell(FakeResult* result, int row, int field, const char* value, size_t length) {
	int at = row * result->fields + field;
	free(result->cells[at]);
	result->cells[at] = value == NULL ? NULL : fakeDup(value, length);
	result->lengths[at] = value == NULL ? 0 : (int)length;
}

static void fakeText(FakeResult* result, int row, int field, const char* value) {
	fakeCell(result, row, field, value, value == NULL ? 0 : strlen(value));
}

/* One row, one column. */
static FakeResult* fakeRow(const char* name, const char* value, size_t length) {
	const char* names[1];
	FakeResult* result;
	names[0] = name;
	result = fakeTuples(names, 1, 1);

	if (result != NULL) {
		fakeCell(result, 0, 0, value, length);
	}

	return result;
}

/* n rows of one column, holding 1 to n. */
static FakeResult* fakeCount(int n) {
	const char* names[1] = {"n"};
	FakeResult* result = fakeTuples(names, 1, n);
	int i;

	if (result == NULL) {
		return NULL;
	}

	for (i = 0; i < n; i++) {
		char text[16];
		snprintf(text, sizeof(text), "%d", i + 1);
		fakeText(result, i, 0, text);
	}

	return result;
}

static FakeResult* fakeError(FakeConn* conn, const char* message) {
	snprintf(conn->error, sizeof(conn->error), "ERROR:  %s\n", message);

	if (conn->transaction == TX_OPEN) {
		conn->transaction = TX_ABORTED;
	}

	return fakeResult(PGRES_FATAL_ERROR, "");
}

static int startsWith(const char* text, const char* prefix) {
	return strncmp(text, prefix, strlen(prefix)) == 0;
}

/* The value of `keyword='...'` in a connection string, unescaped. */
static int conninfoValue(const char* conninfo, const char* keyword, char* out, size_t size) {
	char needle[64];
	const char* at;
	size_t n = 0;

	snprintf(needle, sizeof(needle), "%s='", keyword);
	at = strstr(conninfo, needle);

	if (at == NULL || size == 0) {
		return 0;
	}

	at += strlen(needle);

	while (*at != '\0' && *at != '\'' && n + 1 < size) {
		if (*at == '\\' && at[1] != '\0') {
			at++;
		}
		out[n++] = *at++;
	}

	out[n] = '\0';
	return 1;
}

/* ------------------------------------------------------------------------
 * The key/value table
 *
 * The statements PostgresKVStore sends, told apart by how they begin and a
 * phrase in each, with their parameters where the store puts them:
 *
 *   INSERT ... ON CONFLICT (record_key) ...
 *                                      put: $1 key, $2 value (binary), $3 now,
 *                                      $4 schema; "WHERE r.deleted" makes it
 *                                      a create, only over none or a tombstone
 *   UPDATE ... deleted = TRUE ...      delete: $1 key, $2 now, and $3 the
 *                                      revision when "AND revision = $3"
 *   UPDATE ... SET record_value = $2   update at a revision: $1 key, $2 value,
 *                                      $3 now, $4 schema, $5 revision
 *   SELECT revision, ...               get: $1 key, $2 most bytes to return
 *   SELECT p.record_key, ...           a page: $1 low, $2 high, $3 rows to
 *                                      read, $4 limit, $5 most bytes of a
 *                                      value, $6 most bytes of a page; live
 *                                      records only with "AND NOT deleted"
 *   DELETE FROM ... WHERE deleted ...  purge: $1 updated before
 *
 * Keys are compared with strcmp, which is their UTF-8 bytes' order, as the
 * "C" collation compares them. A value comes back as the server sends a
 * bytea as text: \x and its hex.
 * ------------------------------------------------------------------------ */

static FakeTable fakeTable = {NULL, 0, 0};

static void fakeFreeRecord(FakeRecord* record) {
	free(record->key);
	free(record->value);
}

static void fakeCopyRecord(FakeRecord* to, const FakeRecord* from) {
	*to = *from;
	to->key = fakeDup(from->key, strlen(from->key));
	to->value = (unsigned char*)malloc((size_t)(from->valueLength > 0 ? from->valueLength : 1));
	if (from->valueLength > 0) {
		memcpy(to->value, from->value, (size_t)from->valueLength);
	}
}

static void fakeClearTable(FakeTable* table) {
	int i;
	for (i = 0; i < table->count; i++) {
		fakeFreeRecord(&table->records[i]);
	}
	free(table->records);
	table->records = NULL;
	table->count = 0;
	table->capacity = 0;
}

static FakeTable* fakeCopyTable(const FakeTable* from) {
	FakeTable* copy = (FakeTable*)calloc(1, sizeof(FakeTable));
	int i;
	copy->capacity = from->count > 0 ? from->count : 1;
	copy->records = (FakeRecord*)calloc((size_t)copy->capacity, sizeof(FakeRecord));
	for (i = 0; i < from->count; i++) {
		fakeCopyRecord(&copy->records[i], &from->records[i]);
	}
	copy->count = from->count;
	return copy;
}

/* Where `key` is, or where it would go: *found says which. */
static int fakeFind(const char* key, int* found) {
	int lo = 0;
	int hi = fakeTable.count;

	while (lo < hi) {
		int mid = (lo + hi) / 2;
		int order = strcmp(fakeTable.records[mid].key, key);

		if (order < 0) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}

	*found = lo < fakeTable.count && strcmp(fakeTable.records[lo].key, key) == 0;
	return lo;
}

static FakeRecord* fakeInsert(int at, const char* key) {
	if (fakeTable.count == fakeTable.capacity) {
		fakeTable.capacity = fakeTable.capacity == 0 ? 16 : fakeTable.capacity * 2;
		fakeTable.records = (FakeRecord*)realloc(fakeTable.records, (size_t)fakeTable.capacity * sizeof(FakeRecord));
	}

	memmove(&fakeTable.records[at + 1], &fakeTable.records[at], (size_t)(fakeTable.count - at) * sizeof(FakeRecord));
	memset(&fakeTable.records[at], 0, sizeof(FakeRecord));
	fakeTable.records[at].key = fakeDup(key, strlen(key));
	fakeTable.records[at].value = (unsigned char*)malloc(1);
	fakeTable.count++;
	return &fakeTable.records[at];
}

static void fakeSetValue(FakeRecord* record, const char* value, int length) {
	free(record->value);
	record->value = (unsigned char*)malloc((size_t)(length > 0 ? length : 1));
	if (length > 0) {
		memcpy(record->value, value, (size_t)length);
	}
	record->valueLength = length;
}

static const char* fakeParam(int nParams, const char* const* values, int n) {
	return (n <= nParams && values != NULL && values[n - 1] != NULL) ? values[n - 1] : "";
}

/* A bytea as the server sends it as text. */
static char* fakeByteaText(const unsigned char* value, int length) {
	static const char digits[] = "0123456789abcdef";
	char* out = (char*)malloc((size_t)length * 2 + 3);
	int i;
	out[0] = '\\';
	out[1] = 'x';
	for (i = 0; i < length; i++) {
		out[2 + i * 2] = digits[value[i] >> 4];
		out[3 + i * 2] = digits[value[i] & 15];
	}
	out[2 + length * 2] = '\0';
	return out;
}

static FakeResult* fakeWritten(const FakeRecord* record) {
	const char* names[3] = {"revision", "created_at", "updated_at"};
	FakeResult* result = fakeTuples(names, 3, 1);
	char revision[32];
	snprintf(revision, sizeof(revision), "%lld", record->revision);
	fakeText(result, 0, 0, revision);
	fakeText(result, 0, 1, record->created);
	fakeText(result, 0, 2, record->updated);
	return result;
}

static FakeResult* fakeNothingWritten(const char* tag) {
	const char* names[3] = {"revision", "created_at", "updated_at"};
	FakeResult* result = fakeTuples(names, 3, 0);
	snprintf(result->command, sizeof(result->command), "%s", tag);
	return result;
}

static FakeResult* fakeChanged(const char* verb, int count) {
	FakeResult* result = fakeResult(PGRES_COMMAND_OK, "");
	snprintf(result->command, sizeof(result->command), "%s %d", verb, count);
	snprintf(result->tuples, sizeof(result->tuples), "%d", count);
	return result;
}

static FakeResult* fakeKvPut(int create, int nParams, const char* const* values, const int* lengths) {
	const char* key = fakeParam(nParams, values, 1);
	const char* now = fakeParam(nParams, values, 3);
	int found;
	int at = fakeFind(key, &found);
	FakeRecord* record;

	if (found && create && !fakeTable.records[at].deleted) {
		return fakeNothingWritten("INSERT 0 0");
	}

	if (!found) {
		record = fakeInsert(at, key);
		record->revision = 1;
		snprintf(record->created, sizeof(record->created), "%s", now);
	} else {
		record = &fakeTable.records[at];
		record->revision++;
		if (record->deleted) {
			snprintf(record->created, sizeof(record->created), "%s", now);
		}
	}

	fakeSetValue(record, fakeParam(nParams, values, 2), lengths != NULL && nParams >= 2 ? lengths[1] : 0);
	snprintf(record->updated, sizeof(record->updated), "%s", now);
	snprintf(record->schema, sizeof(record->schema), "%s", fakeParam(nParams, values, 4));
	record->deleted = 0;
	return fakeWritten(record);
}

static FakeResult* fakeKvUpdate(int nParams, const char* const* values, const int* lengths) {
	int found;
	int at = fakeFind(fakeParam(nParams, values, 1), &found);
	FakeRecord* record;

	if (!found || fakeTable.records[at].deleted || fakeTable.records[at].revision != atoll(fakeParam(nParams, values, 5))) {
		return fakeNothingWritten("UPDATE 0");
	}

	record = &fakeTable.records[at];
	record->revision++;
	fakeSetValue(record, fakeParam(nParams, values, 2), lengths != NULL && nParams >= 2 ? lengths[1] : 0);
	snprintf(record->updated, sizeof(record->updated), "%s", fakeParam(nParams, values, 3));
	snprintf(record->schema, sizeof(record->schema), "%s", fakeParam(nParams, values, 4));
	return fakeWritten(record);
}

static FakeResult* fakeKvDelete(int atRevision, int nParams, const char* const* values) {
	int found;
	int at = fakeFind(fakeParam(nParams, values, 1), &found);
	FakeRecord* record;

	if (!found || fakeTable.records[at].deleted || (atRevision && fakeTable.records[at].revision != atoll(fakeParam(nParams, values, 3)))) {
		return fakeChanged("UPDATE", 0);
	}

	record = &fakeTable.records[at];
	record->revision++;
	fakeSetValue(record, "", 0);
	snprintf(record->updated, sizeof(record->updated), "%s", fakeParam(nParams, values, 2));
	snprintf(record->schema, sizeof(record->schema), "0");
	record->deleted = 1;
	return fakeChanged("UPDATE", 1);
}

static FakeResult* fakeKvGet(int nParams, const char* const* values) {
	const char* names[6] = {"revision", "created_at", "updated_at", "value_schema", "size", "value"};
	int found;
	int at = fakeFind(fakeParam(nParams, values, 1), &found);
	const FakeRecord* record;
	FakeResult* result;
	char text[32];

	if (!found || fakeTable.records[at].deleted) {
		return fakeTuples(names, 6, 0);
	}

	record = &fakeTable.records[at];
	result = fakeTuples(names, 6, 1);
	snprintf(text, sizeof(text), "%lld", record->revision);
	fakeText(result, 0, 0, text);
	fakeText(result, 0, 1, record->created);
	fakeText(result, 0, 2, record->updated);
	fakeText(result, 0, 3, record->schema);
	snprintf(text, sizeof(text), "%d", record->valueLength);
	fakeText(result, 0, 4, text);

	if (record->valueLength <= atoi(fakeParam(nParams, values, 2))) {
		char* hex = fakeByteaText(record->value, record->valueLength);
		fakeText(result, 0, 5, hex);
		free(hex);
	}

	return result;
}

static FakeResult* fakeKvScan(int live, int nParams, const char* const* values) {
	const char* names[10] = {"record_key", "revision", "created_at", "updated_at", "deleted", "value_schema", "size", "n", "running", "value"};
	const char* low = fakeParam(nParams, values, 1);
	const char* high = fakeParam(nParams, values, 2);
	int fetch = atoi(fakeParam(nParams, values, 3));
	int limit = atoi(fakeParam(nParams, values, 4));
	long long maxValue = atoll(fakeParam(nParams, values, 5));
	long long pageBytes = atoll(fakeParam(nParams, values, 6));
	int found;
	int at = fakeFind(low, &found);
	int rows = 0;
	int i;
	long long running = 0;
	FakeResult* result;

	for (i = at; i < fakeTable.count && rows < fetch && strcmp(fakeTable.records[i].key, high) < 0; i++) {
		if (!live || !fakeTable.records[i].deleted) {
			rows++;
		}
	}

	result = fakeTuples(names, 10, rows);
	rows = 0;

	for (i = at; i < fakeTable.count && rows < fetch && strcmp(fakeTable.records[i].key, high) < 0; i++) {
		const FakeRecord* record = &fakeTable.records[i];
		char text[32];
		int n;

		if (live && record->deleted) {
			continue;
		}

		n = ++rows;
		running += record->valueLength;
		fakeText(result, n - 1, 0, record->key);
		snprintf(text, sizeof(text), "%lld", record->revision);
		fakeText(result, n - 1, 1, text);
		fakeText(result, n - 1, 2, record->created);
		fakeText(result, n - 1, 3, record->updated);
		fakeText(result, n - 1, 4, record->deleted ? "t" : "f");
		fakeText(result, n - 1, 5, record->schema);
		snprintf(text, sizeof(text), "%d", record->valueLength);
		fakeText(result, n - 1, 6, text);
		snprintf(text, sizeof(text), "%d", n);
		fakeText(result, n - 1, 7, text);
		snprintf(text, sizeof(text), "%lld", running);
		fakeText(result, n - 1, 8, text);

		if (n <= limit && record->valueLength <= maxValue && (n == 1 || running <= pageBytes)) {
			char* hex = fakeByteaText(record->value, record->valueLength);
			fakeText(result, n - 1, 9, hex);
			free(hex);
		}
	}

	return result;
}

static FakeResult* fakeKvPurge(int nParams, const char* const* values) {
	double before = atof(fakeParam(nParams, values, 1));
	int kept = 0;
	int purged = 0;
	int i;

	for (i = 0; i < fakeTable.count; i++) {
		if (fakeTable.records[i].deleted && atof(fakeTable.records[i].updated) < before) {
			fakeFreeRecord(&fakeTable.records[i]);
			purged++;
		} else {
			fakeTable.records[kept++] = fakeTable.records[i];
		}
	}

	fakeTable.count = kept;
	return fakeChanged("DELETE", purged);
}

/* One of the key/value table's statements, or NULL when `sql` is none of them. */
static FakeResult* fakeKv(FakeConn* conn, const char* sql, int nParams, const char* const* values, const int* lengths) {
	FakeResult* result = NULL;
	(void)conn;
	fakeLockTable();

	if (strcmp(sql, "fake:kv-clear") == 0) {
		fakeClearTable(&fakeTable);
		result = fakeResult(PGRES_COMMAND_OK, "OK");
	} else if (startsWith(sql, "INSERT INTO ") && strstr(sql, " ON CONFLICT (record_key) ") != NULL) {
		result = fakeKvPut(strstr(sql, "WHERE r.deleted") != NULL, nParams, values, lengths);
	} else if (startsWith(sql, "UPDATE ") && strstr(sql, "deleted = TRUE") != NULL) {
		result = fakeKvDelete(strstr(sql, "AND revision = $3") != NULL, nParams, values);
	} else if (startsWith(sql, "UPDATE ") && strstr(sql, "SET record_value = $2") != NULL) {
		result = fakeKvUpdate(nParams, values, lengths);
	} else if (startsWith(sql, "SELECT revision, created_at")) {
		result = fakeKvGet(nParams, values);
	} else if (startsWith(sql, "SELECT p.record_key")) {
		result = fakeKvScan(strstr(sql, "AND NOT deleted") != NULL, nParams, values);
	} else if (startsWith(sql, "DELETE FROM ") && strstr(sql, "WHERE deleted AND updated_at") != NULL) {
		result = fakeKvPurge(nParams, values);
	}

	fakeUnlockTable();
	return result;
}

static void fakeBeginKv(FakeConn* conn) {
	fakeLockTable();
	if (conn->snapshot != NULL) {
		fakeClearTable(conn->snapshot);
		free(conn->snapshot);
	}
	conn->snapshot = fakeCopyTable(&fakeTable);
	fakeUnlockTable();
}

/* Ends the transaction's hold on the table: putting it back as it was at the BEGIN when `undo`. */
static void fakeEndKv(FakeConn* conn, int undo) {
	if (conn->snapshot == NULL) {
		return;
	}

	fakeLockTable();
	if (undo) {
		fakeClearTable(&fakeTable);
		fakeTable = *conn->snapshot;
	} else {
		fakeClearTable(conn->snapshot);
	}
	free(conn->snapshot);
	conn->snapshot = NULL;
	fakeUnlockTable();
}

static FakeResult* fakeRun(FakeConn* conn, const char* sql, int nParams, const char* const* values, const int* lengths) {
	FakeResult* kv;

	if (conn == NULL) {
		return NULL;
	}

	conn->error[0] = '\0';

	if (sql == NULL) {
		sql = "";
	}

	if (strcmp(sql, "COMMIT") == 0 || strcmp(sql, "COMMIT;") == 0) {
		/* What the server does: a COMMIT of an aborted transaction is not an
		   error, it is a successful ROLLBACK, and only the tag says so. */
		int aborted = conn->transaction == TX_ABORTED;
		conn->transaction = TX_IDLE;

		if (conn->failNextCommit) {
			/* A COMMIT that fails ends the transaction all the same. */
			conn->failNextCommit = 0;
			fakeEndKv(conn, 1);
			return fakeError(conn, "could not serialize access due to read/write dependencies among transactions");
		}

		fakeEndKv(conn, aborted);
		return fakeResult(PGRES_COMMAND_OK, aborted ? "ROLLBACK" : "COMMIT");
	}

	if (strcmp(sql, "ROLLBACK") == 0 || strcmp(sql, "ROLLBACK;") == 0) {
		conn->transaction = TX_IDLE;
		fakeEndKv(conn, 1);
		return fakeResult(PGRES_COMMAND_OK, "ROLLBACK");
	}

	if (conn->transaction == TX_ABORTED) {
		return fakeError(conn, "current transaction is aborted, commands ignored until end of transaction block");
	}

	if (strcmp(sql, "BEGIN") == 0 || strcmp(sql, "BEGIN;") == 0) {
		conn->transaction = TX_OPEN;
		fakeBeginKv(conn);
		return fakeResult(PGRES_COMMAND_OK, "BEGIN");
	}

	kv = fakeKv(conn, sql, nParams, values, lengths);

	if (kv != NULL) {
		return kv;
	}

	if (strcmp(sql, "SELECT $1::text") == 0) {
		const char* value = (nParams > 0 && values != NULL && values[0] != NULL) ? values[0] : "";
		return fakeRow("text", value, strlen(value));
	}

	if (strcmp(sql, "SELECT 1") == 0 || strcmp(sql, "SELECT 1;") == 0) {
		return fakeRow("?column?", "1", 1);
	}

	if (strcmp(sql, "fake:conninfo") == 0) {
		return fakeRow("conninfo", conn->conninfo, strlen(conn->conninfo));
	}

	if (strcmp(sql, "fake:live") == 0) {
		char text[16];
		snprintf(text, sizeof(text), "%ld", (long)fakeLive);
		return fakeRow("live", text, strlen(text));
	}

	if (strcmp(sql, "fake:transaction") == 0) {
		const char* state = conn->transaction == TX_OPEN ? "open" : (conn->transaction == TX_ABORTED ? "aborted" : "idle");
		return fakeRow("transaction", state, strlen(state));
	}

	if (startsWith(sql, "fake:count ")) {
		int n = atoi(sql + 11);
		return fakeCount(n < 0 ? 0 : (n > 10000 ? 10000 : n));
	}

	if (startsWith(sql, "fake:affect ")) {
		const char* digits = sql + 12;
		FakeResult* result = fakeResult(PGRES_COMMAND_OK, "");

		if (result != NULL) {
			snprintf(result->command, sizeof(result->command), "UPDATE %.20s", digits);
			snprintf(result->tuples, sizeof(result->tuples), "%.20s", digits);
		}

		return result;
	}

	if (strcmp(sql, "fake:fail") == 0) {
		return fakeError(conn, "fake failure");
	}

	if (strcmp(sql, "fake:fail-next-commit") == 0) {
		conn->failNextCommit = 1;
		return fakeResult(PGRES_COMMAND_OK, "OK");
	}

	if (startsWith(sql, "fake:sleep ")) {
		int total = atoi(sql + 11);
		int waited = 0;

		conn->cancelled = 0;

		while (waited < total) {
			if (conn->cancelled) {
				conn->cancelled = 0;
				return fakeError(conn, "canceling statement due to user request");
			}

			fakeSleepMs(1);
			waited++;
		}

		return fakeResult(PGRES_COMMAND_OK, "SELECT 0");
	}

	return fakeResult(PGRES_COMMAND_OK, "OK");
}

FAKEPQ_EXPORT void* PQconnectdb(const char* conninfo) {
	FakeConn* conn = (FakeConn*)calloc(1, sizeof(FakeConn));
	char host[128];

	if (conn == NULL) {
		return NULL;
	}

	conn->status = CONNECTION_OK;
	conn->conninfo = fakeDup(conninfo == NULL ? "" : conninfo, conninfo == NULL ? 0 : strlen(conninfo));
	fakeCountLive(1);

	if (conninfoValue(conn->conninfo, "host", host, sizeof(host))) {
		if (startsWith(host, "fail-")) {
			conn->status = CONNECTION_BAD;
			snprintf(conn->error, sizeof(conn->error), "could not connect to server \"%s\"\n", host);
		} else if (strcmp(host, "slow-connect") == 0) {
			fakeSleepMs(1500);
		}
	}

	return conn;
}

FAKEPQ_EXPORT int PQstatus(const void* conn) {
	return conn == NULL ? CONNECTION_BAD : ((const FakeConn*)conn)->status;
}

FAKEPQ_EXPORT char* PQerrorMessage(const void* conn) {
	return conn == NULL ? (char*)"no connection" : ((FakeConn*)conn)->error;
}

FAKEPQ_EXPORT void PQfinish(void* conn) {
	if (conn != NULL) {
		/* A server rolls back what a closed connection left open. */
		fakeEndKv((FakeConn*)conn, 1);
		free(((FakeConn*)conn)->conninfo);
		free(conn);
		fakeCountLive(-1);
	}
}

FAKEPQ_EXPORT void* PQexec(void* conn, const char* query) {
	return fakeRun((FakeConn*)conn, query, 0, NULL, NULL);
}

FAKEPQ_EXPORT void* PQexecParams(void* conn, const char* command, int nParams, const Oid* paramTypes,
	const char* const* paramValues, const int* paramLengths, const int* paramFormats, int resultFormat) {
	(void)paramTypes;
	(void)paramFormats;
	(void)resultFormat;
	return fakeRun((FakeConn*)conn, command, nParams, paramValues, paramLengths);
}

FAKEPQ_EXPORT int PQresultStatus(const void* res) {
	return res == NULL ? PGRES_FATAL_ERROR : ((const FakeResult*)res)->status;
}

FAKEPQ_EXPORT int PQntuples(const void* res) {
	return res == NULL ? 0 : ((const FakeResult*)res)->rows;
}

FAKEPQ_EXPORT int PQnfields(const void* res) {
	return res == NULL ? 0 : ((const FakeResult*)res)->fields;
}

FAKEPQ_EXPORT char* PQfname(const void* res, int field) {
	const FakeResult* result = (const FakeResult*)res;
	return (result == NULL || field < 0 || field >= result->fields) ? NULL : result->names[field];
}

static int fakeInside(const FakeResult* result, int row, int field) {
	return result != NULL && row >= 0 && row < result->rows && field >= 0 && field < result->fields;
}

FAKEPQ_EXPORT char* PQgetvalue(const void* res, int row, int field) {
	const FakeResult* result = (const FakeResult*)res;

	if (!fakeInside(result, row, field) || result->cells[row * result->fields + field] == NULL) {
		/* libpq's answer for a NULL. */
		return (char*)"";
	}

	return result->cells[row * result->fields + field];
}

FAKEPQ_EXPORT int PQgetlength(const void* res, int row, int field) {
	const FakeResult* result = (const FakeResult*)res;
	return fakeInside(result, row, field) ? result->lengths[row * result->fields + field] : 0;
}

FAKEPQ_EXPORT int PQgetisnull(const void* res, int row, int field) {
	const FakeResult* result = (const FakeResult*)res;
	return fakeInside(result, row, field) && result->cells[row * result->fields + field] == NULL;
}

FAKEPQ_EXPORT char* PQcmdTuples(void* res) {
	return res == NULL ? (char*)"" : ((FakeResult*)res)->tuples;
}

FAKEPQ_EXPORT char* PQcmdStatus(void* res) {
	return res == NULL ? NULL : ((FakeResult*)res)->command;
}

FAKEPQ_EXPORT Oid PQoidValue(const void* res) {
	(void)res;
	return 0;
}

FAKEPQ_EXPORT void PQclear(void* res) {
	FakeResult* result = (FakeResult*)res;

	if (result != NULL) {
		int i;

		for (i = 0; i < result->fields; i++) {
			free(result->names[i]);
		}

		for (i = 0; i < result->fields * result->rows; i++) {
			free(result->cells[i]);
		}

		free(result->names);
		free(result->cells);
		free(result->lengths);
		free(result);
	}
}

FAKEPQ_EXPORT size_t PQescapeStringConn(void* conn, char* to, const char* from, size_t length, int* error) {
	size_t written = 0;
	size_t i;

	(void)conn;

	for (i = 0; i < length && from[i] != '\0'; ++i) {
		if (from[i] == '\'') {
			to[written++] = '\'';
		}
		to[written++] = from[i];
	}

	to[written] = '\0';

	if (error != NULL) {
		*error = 0;
	}

	return written;
}

FAKEPQ_EXPORT int PQserverVersion(const void* conn) {
	(void)conn;
	return 160000;
}

FAKEPQ_EXPORT void* PQgetCancel(void* conn) {
	FakeCancel* cancel;

	if (conn == NULL) {
		return NULL;
	}

	cancel = (FakeCancel*)calloc(1, sizeof(FakeCancel));

	if (cancel != NULL) {
		cancel->conn = (FakeConn*)conn;
	}

	return cancel;
}

FAKEPQ_EXPORT int PQcancel(void* cancel, char* errbuf, int errbufsize) {
	if (cancel == NULL) {
		if (errbuf != NULL && errbufsize > 0) {
			snprintf(errbuf, (size_t)errbufsize, "no cancel object");
		}
		return 0;
	}

	((FakeCancel*)cancel)->conn->cancelled = 1;
	return 1;
}

FAKEPQ_EXPORT void PQfreeCancel(void* cancel) {
	free(cancel);
}

FAKEPQ_EXPORT int PQtransactionStatus(const void* conn) {
	const FakeConn* c = (const FakeConn*)conn;

	if (c == NULL || c->status != CONNECTION_OK) {
		return PQTRANS_UNKNOWN;
	}

	switch (c->transaction) {
		case TX_OPEN:
			return PQTRANS_INTRANS;
		case TX_ABORTED:
			return PQTRANS_INERROR;
		default:
			return PQTRANS_IDLE;
	}
}
