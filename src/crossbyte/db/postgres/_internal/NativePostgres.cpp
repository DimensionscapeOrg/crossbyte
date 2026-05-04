#include <hxcpp.h>

#include "NativePostgres.h"

#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <Windows.h>
#else
#include <dlfcn.h>
#endif

struct pg_conn;
struct pg_result;
typedef unsigned int Oid;
typedef pg_conn PGconn;
typedef pg_result PGresult;

enum ConnStatusType {
	CONNECTION_OK = 0,
	CONNECTION_BAD = 1
};

enum ExecStatusType {
	PGRES_EMPTY_QUERY = 0,
	PGRES_COMMAND_OK = 1,
	PGRES_TUPLES_OK = 2,
	PGRES_COPY_OUT = 3,
	PGRES_COPY_IN = 4,
	PGRES_BAD_RESPONSE = 5,
	PGRES_NONFATAL_ERROR = 6,
	PGRES_FATAL_ERROR = 7,
	PGRES_COPY_BOTH = 8,
	PGRES_SINGLE_TUPLE = 9,
	PGRES_PIPELINE_SYNC = 10,
	PGRES_PIPELINE_ABORTED = 11
};

namespace {
	struct LibPQApi {
#if defined(_WIN32)
		HMODULE module = nullptr;
#else
		void* module = nullptr;
#endif
		PGconn* (*PQconnectdb)(const char* conninfo) = nullptr;
		ConnStatusType (*PQstatus)(const PGconn* conn) = nullptr;
		char* (*PQerrorMessage)(const PGconn* conn) = nullptr;
		void (*PQfinish)(PGconn* conn) = nullptr;
		PGresult* (*PQexec)(PGconn* conn, const char* query) = nullptr;
		ExecStatusType (*PQresultStatus)(const PGresult* res) = nullptr;
		int (*PQntuples)(const PGresult* res) = nullptr;
		int (*PQnfields)(const PGresult* res) = nullptr;
		char* (*PQfname)(const PGresult* res, int fieldNum) = nullptr;
		char* (*PQgetvalue)(const PGresult* res, int rowNum, int fieldNum) = nullptr;
		int (*PQgetisnull)(const PGresult* res, int rowNum, int fieldNum) = nullptr;
		char* (*PQcmdTuples)(PGresult* res) = nullptr;
		Oid (*PQoidValue)(const PGresult* res) = nullptr;
		void (*PQclear)(PGresult* res) = nullptr;
		size_t (*PQescapeStringConn)(PGconn* conn, char* to, const char* from, size_t length, int* error) = nullptr;
		int (*PQserverVersion)(const PGconn* conn) = nullptr;
		bool loaded = false;
		std::string loadedPath;
		std::string lastError;
		std::string scratch;
	};

	LibPQApi g_api;

	std::string trim(const std::string& value) {
		size_t start = 0;
		while (start < value.size() && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r' || value[start] == '\n')) {
			start++;
		}

		size_t end = value.size();
		while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t' || value[end - 1] == '\r' || value[end - 1] == '\n')) {
			end--;
		}

		return value.substr(start, end - start);
	}

	std::string jsonEscape(const std::string& value) {
		std::string out;
		out.reserve(value.size() + 8);
		for (size_t i = 0; i < value.size(); ++i) {
			unsigned char c = static_cast<unsigned char>(value[i]);
			switch (c) {
				case '\\': out += "\\\\"; break;
				case '"': out += "\\\""; break;
				case '\b': out += "\\b"; break;
				case '\f': out += "\\f"; break;
				case '\n': out += "\\n"; break;
				case '\r': out += "\\r"; break;
				case '\t': out += "\\t"; break;
				default:
					if (c < 0x20) {
						char buffer[7];
						std::snprintf(buffer, sizeof(buffer), "\\u%04x", static_cast<unsigned int>(c));
						out += buffer;
					} else {
						out.push_back(static_cast<char>(c));
					}
			}
		}
		return out;
	}

	std::string makeErrorJson(const std::string& message) {
		return std::string("{\"error\":\"") + jsonEscape(message) + "\"}";
	}

	std::string conninfoEscape(const std::string& value) {
		std::string out;
		out.reserve(value.size() + 4);
		for (size_t i = 0; i < value.size(); ++i) {
			char c = value[i];
			if (c == '\\' || c == '\'') {
				out.push_back('\\');
			}
			out.push_back(c);
		}
		return out;
	}

	void setLastError(const std::string& message) {
		g_api.lastError = message;
	}

#if defined(_WIN32)
	std::string moduleDir(const std::string& path) {
		size_t slash = path.find_last_of("\\/");
		return slash == std::string::npos ? std::string() : path.substr(0, slash);
	}

	bool tryLoadLibrary(const std::string& path) {
		std::string actual = path;
		if (actual.empty()) {
			return false;
		}
		SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
		HMODULE module = LoadLibraryA(actual.c_str());
		if (module == nullptr) {
			return false;
		}
		g_api.module = module;
		g_api.loadedPath = actual;
		return true;
	}

	void unloadLibrary() {
		if (g_api.module != nullptr) {
			FreeLibrary(g_api.module);
			g_api.module = nullptr;
		}
	}

	void* resolveSymbol(const char* name) {
		return g_api.module == nullptr ? nullptr : reinterpret_cast<void*>(GetProcAddress(g_api.module, name));
	}
#else
	bool tryLoadLibrary(const std::string& path) {
		void* module = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
		if (module == nullptr) {
			return false;
		}
		g_api.module = module;
		g_api.loadedPath = path;
		return true;
	}

	void unloadLibrary() {
		if (g_api.module != nullptr) {
			dlclose(g_api.module);
			g_api.module = nullptr;
		}
	}

	void* resolveSymbol(const char* name) {
		return g_api.module == nullptr ? nullptr : dlsym(g_api.module, name);
	}
#endif

	template<typename T>
	bool loadSymbol(T& target, const char* name) {
		target = reinterpret_cast<T>(resolveSymbol(name));
		return target != nullptr;
	}

	std::vector<std::string> defaultCandidates() {
		std::vector<std::string> out;
#if defined(_WIN32)
		out.push_back("libpq.dll");
		out.push_back(".\\php\\libpq.dll");
		out.push_back("..\\php\\libpq.dll");
		out.push_back("..\\..\\php\\libpq.dll");
#else
		out.push_back("libpq.so.5");
		out.push_back("libpq.so");
#endif
		return out;
	}

	bool ensureLibLoaded(Array<String> libraryPaths) {
		if (g_api.loaded) {
			return true;
		}

		std::vector<std::string> candidates;
		if (libraryPaths.mPtr != nullptr) {
			for (int i = 0; i < libraryPaths->length; ++i) {
				std::string entry = trim(libraryPaths[i].utf8_str());
				if (!entry.empty()) {
					candidates.push_back(entry);
				}
			}
		}

		std::vector<std::string> defaults = defaultCandidates();
		candidates.insert(candidates.end(), defaults.begin(), defaults.end());

		for (size_t i = 0; i < candidates.size(); ++i) {
			unloadLibrary();
			if (!tryLoadLibrary(candidates[i])) {
				continue;
			}

			bool ok =
				loadSymbol(g_api.PQconnectdb, "PQconnectdb") &&
				loadSymbol(g_api.PQstatus, "PQstatus") &&
				loadSymbol(g_api.PQerrorMessage, "PQerrorMessage") &&
				loadSymbol(g_api.PQfinish, "PQfinish") &&
				loadSymbol(g_api.PQexec, "PQexec") &&
				loadSymbol(g_api.PQresultStatus, "PQresultStatus") &&
				loadSymbol(g_api.PQntuples, "PQntuples") &&
				loadSymbol(g_api.PQnfields, "PQnfields") &&
				loadSymbol(g_api.PQfname, "PQfname") &&
				loadSymbol(g_api.PQgetvalue, "PQgetvalue") &&
				loadSymbol(g_api.PQgetisnull, "PQgetisnull") &&
				loadSymbol(g_api.PQcmdTuples, "PQcmdTuples") &&
				loadSymbol(g_api.PQoidValue, "PQoidValue") &&
				loadSymbol(g_api.PQclear, "PQclear") &&
				loadSymbol(g_api.PQescapeStringConn, "PQescapeStringConn") &&
				loadSymbol(g_api.PQserverVersion, "PQserverVersion");

			if (ok) {
				g_api.loaded = true;
				setLastError("");
				return true;
			}
			unloadLibrary();
		}

		setLastError("Could not load libpq or required symbols.");
		return false;
	}

	std::string buildConninfo(const char* host, int port, const char* user, const char* password, const char* database, const char* sslMode, int connectTimeout) {
		std::ostringstream conninfo;
		if (host != nullptr && host[0] != '\0') {
			conninfo << "host='" << conninfoEscape(host) << "' ";
		}
		if (port > 0) {
			conninfo << "port='" << port << "' ";
		}
		if (user != nullptr && user[0] != '\0') {
			conninfo << "user='" << conninfoEscape(user) << "' ";
		}
		if (password != nullptr && password[0] != '\0') {
			conninfo << "password='" << conninfoEscape(password) << "' ";
		}
		if (database != nullptr && database[0] != '\0') {
			conninfo << "dbname='" << conninfoEscape(database) << "' ";
		}
		if (sslMode != nullptr && sslMode[0] != '\0') {
			conninfo << "sslmode='" << conninfoEscape(sslMode) << "' ";
		}
		if (connectTimeout > 0) {
			conninfo << "connect_timeout='" << connectTimeout << "' ";
		}
		return conninfo.str();
	}

	int parseAffectedRows(PGresult* result) {
		if (result == nullptr || g_api.PQcmdTuples == nullptr) {
			return 0;
		}
		const char* raw = g_api.PQcmdTuples(result);
		if (raw == nullptr || raw[0] == '\0') {
			return 0;
		}
		return std::atoi(raw);
	}
}

extern "C" void* crossbyte_postgres_open(const char* host, int port, const char* user, const char* password, const char* database, const char* sslMode, int connectTimeout, Array<String> libraryPaths) {
	if (!ensureLibLoaded(libraryPaths)) {
		return nullptr;
	}

	std::string conninfo = buildConninfo(host, port, user, password, database, sslMode, connectTimeout);
	PGconn* connection = g_api.PQconnectdb(conninfo.c_str());
	if (connection == nullptr) {
		setLastError("PQconnectdb returned null.");
		return nullptr;
	}
	if (g_api.PQstatus(connection) != CONNECTION_OK) {
		setLastError(g_api.PQerrorMessage(connection) == nullptr ? "Connection failed." : g_api.PQerrorMessage(connection));
		g_api.PQfinish(connection);
		return nullptr;
	}

	setLastError("");
	return connection;
}

extern "C" void crossbyte_postgres_close(void* handle) {
	if (handle != nullptr && g_api.PQfinish != nullptr) {
		g_api.PQfinish(static_cast<PGconn*>(handle));
	}
}

extern "C" bool crossbyte_postgres_is_open(void* handle) {
	if (handle == nullptr || !g_api.loaded || g_api.PQstatus == nullptr) {
		return false;
	}
	return g_api.PQstatus(static_cast<PGconn*>(handle)) == CONNECTION_OK;
}

extern "C" const char* crossbyte_postgres_request_json(void* handle, const char* sql) {
	if (handle == nullptr) {
		g_api.scratch = makeErrorJson("Postgres connection is not open.");
		return g_api.scratch.c_str();
	}
	if (!g_api.loaded || g_api.PQexec == nullptr) {
		g_api.scratch = makeErrorJson("libpq is not loaded.");
		return g_api.scratch.c_str();
	}

	PGconn* connection = static_cast<PGconn*>(handle);
	PGresult* result = g_api.PQexec(connection, sql == nullptr ? "" : sql);
	if (result == nullptr) {
		std::string message = g_api.PQerrorMessage(connection) == nullptr ? "PQexec returned null." : g_api.PQerrorMessage(connection);
		g_api.scratch = makeErrorJson(message);
		return g_api.scratch.c_str();
	}

	ExecStatusType status = g_api.PQresultStatus(result);
	if (!(status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE || status == PGRES_EMPTY_QUERY)) {
		std::string message = g_api.PQerrorMessage(connection) == nullptr ? "Postgres query failed." : g_api.PQerrorMessage(connection);
		g_api.PQclear(result);
		g_api.scratch = makeErrorJson(message);
		return g_api.scratch.c_str();
	}

	std::ostringstream out;
	out << "{\"rows\":[";

	int rows = g_api.PQntuples(result);
	int fields = g_api.PQnfields(result);
	for (int row = 0; row < rows; ++row) {
		if (row > 0) {
			out << ",";
		}
		out << "{";
		for (int field = 0; field < fields; ++field) {
			if (field > 0) {
				out << ",";
			}
			const char* name = g_api.PQfname(result, field);
			out << "\"" << jsonEscape(name == nullptr ? "" : name) << "\":";
			if (g_api.PQgetisnull(result, row, field) == 1) {
				out << "null";
			} else {
				const char* value = g_api.PQgetvalue(result, row, field);
				out << "\"" << jsonEscape(value == nullptr ? "" : value) << "\"";
			}
		}
		out << "}";
	}
	out << "],\"affectedRows\":" << parseAffectedRows(result);
	out << ",\"lastInsertRowID\":" << static_cast<unsigned int>(g_api.PQoidValue(result));
	out << "}";

	g_api.PQclear(result);
	g_api.scratch = out.str();
	return g_api.scratch.c_str();
}

extern "C" const char* crossbyte_postgres_escape(void* handle, const char* value) {
	if (!g_api.loaded || g_api.PQescapeStringConn == nullptr) {
		g_api.scratch = value == nullptr ? "" : value;
		return g_api.scratch.c_str();
	}

	const char* raw = value == nullptr ? "" : value;
	size_t length = std::strlen(raw);
	std::string out;
	out.resize(length * 2 + 1);
	int error = 0;
	size_t written = g_api.PQescapeStringConn(static_cast<PGconn*>(handle), &out[0], raw, length, &error);
	out.resize(written);
	if (error != 0) {
		g_api.scratch = value == nullptr ? "" : value;
		return g_api.scratch.c_str();
	}

	g_api.scratch = out;
	return g_api.scratch.c_str();
}

extern "C" const char* crossbyte_postgres_last_error() {
	return g_api.lastError.c_str();
}
