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
 *   fake:sleep <ms>     blocks for that long, or until PQcancel, the way a slow
 *                       query or a lock wait blocks inside PQexec
 *   fake:fail           fails, aborting any open transaction
 *   fake:fail-next-commit
 *                       makes the next COMMIT fail outright, as a serialization
 *                       failure or a deferred constraint does
 *   BEGIN / COMMIT / ROLLBACK
 *                       tracked the way the server tracks them: a COMMIT in an
 *                       aborted transaction succeeds with the tag ROLLBACK
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
#else
#include <time.h>
#define FAKEPQ_EXPORT __attribute__((visibility("default")))
static void fakeSleepMs(int ms) {
	struct timespec ts;
	ts.tv_sec = ms / 1000;
	ts.tv_nsec = (long)(ms % 1000) * 1000000L;
	nanosleep(&ts, NULL);
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

typedef struct FakeConn {
	int status;
	int transaction;
	int failNextCommit;
	/* Written by PQcancel on another thread, read by the sleeping statement. */
	volatile int cancelled;
	char* conninfo;
	char error[512];
} FakeConn;

typedef struct FakeCancel {
	FakeConn* conn;
} FakeCancel;

typedef struct FakeResult {
	int status;
	int fields;
	int rows;
	char* name;
	char* value;
	int length;
	char command[32];
	char tuples[16];
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

/* One row, one column. */
static FakeResult* fakeRow(const char* name, const char* value, size_t length) {
	FakeResult* result = fakeResult(PGRES_TUPLES_OK, "SELECT 1");

	if (result == NULL) {
		return NULL;
	}

	result->fields = 1;
	result->rows = 1;
	result->name = fakeDup(name, strlen(name));
	result->value = fakeDup(value, length);
	result->length = (int)length;
	snprintf(result->tuples, sizeof(result->tuples), "1");
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

static FakeResult* fakeRun(FakeConn* conn, const char* sql, int nParams, const char* const* values) {
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
			return fakeError(conn, "could not serialize access due to read/write dependencies among transactions");
		}

		return fakeResult(PGRES_COMMAND_OK, aborted ? "ROLLBACK" : "COMMIT");
	}

	if (strcmp(sql, "ROLLBACK") == 0 || strcmp(sql, "ROLLBACK;") == 0) {
		conn->transaction = TX_IDLE;
		return fakeResult(PGRES_COMMAND_OK, "ROLLBACK");
	}

	if (conn->transaction == TX_ABORTED) {
		return fakeError(conn, "current transaction is aborted, commands ignored until end of transaction block");
	}

	if (strcmp(sql, "BEGIN") == 0 || strcmp(sql, "BEGIN;") == 0) {
		conn->transaction = TX_OPEN;
		return fakeResult(PGRES_COMMAND_OK, "BEGIN");
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
		free(((FakeConn*)conn)->conninfo);
		free(conn);
	}
}

FAKEPQ_EXPORT void* PQexec(void* conn, const char* query) {
	return fakeRun((FakeConn*)conn, query, 0, NULL);
}

FAKEPQ_EXPORT void* PQexecParams(void* conn, const char* command, int nParams, const Oid* paramTypes,
	const char* const* paramValues, const int* paramLengths, const int* paramFormats, int resultFormat) {
	(void)paramTypes;
	(void)paramLengths;
	(void)paramFormats;
	(void)resultFormat;
	return fakeRun((FakeConn*)conn, command, nParams, paramValues);
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
	return (result == NULL || field != 0 || result->fields == 0) ? NULL : result->name;
}

FAKEPQ_EXPORT char* PQgetvalue(const void* res, int row, int field) {
	const FakeResult* result = (const FakeResult*)res;
	return (result == NULL || row != 0 || field != 0 || result->rows == 0) ? (char*)"" : result->value;
}

FAKEPQ_EXPORT int PQgetlength(const void* res, int row, int field) {
	const FakeResult* result = (const FakeResult*)res;
	return (result == NULL || row != 0 || field != 0 || result->rows == 0) ? 0 : result->length;
}

FAKEPQ_EXPORT int PQgetisnull(const void* res, int row, int field) {
	(void)res;
	(void)row;
	(void)field;
	return 0;
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
		free(result->name);
		free(result->value);
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
