#include <hxcpp.h>

#include "NativePostgres.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
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
struct pg_cancel;
typedef unsigned int Oid;
typedef pg_conn PGconn;
typedef pg_result PGresult;
typedef pg_cancel PGcancel;

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

enum PGTransactionStatusType {
	PQTRANS_IDLE = 0,
	PQTRANS_ACTIVE = 1,
	PQTRANS_INTRANS = 2,
	PQTRANS_INERROR = 3,
	PQTRANS_UNKNOWN = 4
};

// Threading. Nothing in this file is shared between connections except the
// table of loaded libraries, which is written under a lock and never changes
// once an entry is in it. Everything a call produces is returned to the caller
// as a new Haxe object, so there is no buffer for a second thread to
// overwrite: the bridge used to return every result through one process-wide
// buffer, and with a worker per pooled connection a query could read another
// query's rows, or the freed memory of a buffer another thread had grown.
//
// Collection. Every call that can block, connect, execute, cancel, finish,
// runs in a GC-free zone, so a query waiting on the server does not hold up
// a collection on any other thread. Inside a zone nothing may touch the GC
// heap, which is why each entry point copies its Haxe inputs into native
// memory first and builds its Haxe result only after the zone is closed.
namespace {
	struct LibPQApi {
		std::string path;
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
		char* (*PQcmdStatus)(PGresult* res) = nullptr;
		Oid (*PQoidValue)(const PGresult* res) = nullptr;
		void (*PQclear)(PGresult* res) = nullptr;
		size_t (*PQescapeStringConn)(PGconn* conn, char* to, const char* from, size_t length, int* error) = nullptr;
		PGresult* (*PQexecParams)(PGconn* conn, const char* command, int nParams, const Oid* paramTypes,
			const char* const* paramValues, const int* paramLengths, const int* paramFormats, int resultFormat) = nullptr;
		int (*PQgetlength)(const PGresult* res, int rowNum, int fieldNum) = nullptr;
		PGcancel* (*PQgetCancel)(PGconn* conn) = nullptr;
		int (*PQcancel)(PGcancel* cancel, char* errbuf, int errbufsize) = nullptr;
		void (*PQfreeCancel)(PGcancel* cancel) = nullptr;
		// Optional, and the only one that is: every libpq since 7.4 has it,
		// but a library without it should still connect, losing only the
		// server's view of whether a transaction is open.
		PGTransactionStatusType (*PQtransactionStatus)(const PGconn* conn) = nullptr;
	};

	// Keyed by the path each was loaded from, so a connection configured with
	// its own library gets that library even after another was loaded. Never
	// unloaded: a connection opened through one may outlive any later open.
	std::mutex g_loadLock;
	std::vector<LibPQApi*> g_libraries;

	// One per connection, and the only state a connection has.
	struct Handle {
		const LibPQApi* api = nullptr;
		PGconn* conn = nullptr;
		// Made once at connect, so cancel() never touches the connection
		// itself: libpq allows PQcancel on another thread for exactly that
		// reason.
		PGcancel* cancel = nullptr;
		// Why the open failed; empty once it has succeeded.
		std::string error;
	};

	struct ResultGuard {
		const LibPQApi* api;
		PGresult* result;

		~ResultGuard() {
			if (result != nullptr) {
				api->PQclear(result);
			}
		}
	};

	std::string toNative(const ::String& value) {
		if (value.raw_ptr() == nullptr) {
			return std::string();
		}

		int length = 0;
		const char* utf8 = value.utf8_str(nullptr, true, &length);
		return utf8 == nullptr ? std::string() : std::string(utf8, static_cast<size_t>(length));
	}

	::String toHaxe(const std::string& value) {
		return ::String::create(value.data(), static_cast<int>(value.size()));
	}

	// libpq ends its messages with a newline, which reads as a blank line in
	// every log that prints one.
	std::string trimMessage(const char* message, const char* fallback) {
		std::string out = message == nullptr || message[0] == '\0' ? std::string(fallback) : std::string(message);

		while (!out.empty() && (out[out.size() - 1] == '\n' || out[out.size() - 1] == '\r' || out[out.size() - 1] == ' ')) {
			out.erase(out.size() - 1);
		}

		return out.empty() ? std::string(fallback) : out;
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

#if defined(_WIN32)
	void* resolveSymbol(HMODULE module, const char* name) {
		return reinterpret_cast<void*>(GetProcAddress(module, name));
	}
#else
	void* resolveSymbol(void* module, const char* name) {
		return dlsym(module, name);
	}
#endif

	template<typename T>
	bool loadSymbol(const LibPQApi& api, T& target, const char* name) {
		target = reinterpret_cast<T>(resolveSymbol(api.module, name));
		return target != nullptr;
	}

	LibPQApi* tryLoad(const std::string& path) {
		LibPQApi* api = new LibPQApi();
		api->path = path;

#if defined(_WIN32)
		SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
		api->module = LoadLibraryA(path.c_str());
#else
		api->module = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
#endif

		if (api->module == nullptr) {
			delete api;
			return nullptr;
		}

		bool ok =
			loadSymbol(*api, api->PQconnectdb, "PQconnectdb") &&
			loadSymbol(*api, api->PQstatus, "PQstatus") &&
			loadSymbol(*api, api->PQerrorMessage, "PQerrorMessage") &&
			loadSymbol(*api, api->PQfinish, "PQfinish") &&
			loadSymbol(*api, api->PQexec, "PQexec") &&
			loadSymbol(*api, api->PQresultStatus, "PQresultStatus") &&
			loadSymbol(*api, api->PQntuples, "PQntuples") &&
			loadSymbol(*api, api->PQnfields, "PQnfields") &&
			loadSymbol(*api, api->PQfname, "PQfname") &&
			loadSymbol(*api, api->PQgetvalue, "PQgetvalue") &&
			loadSymbol(*api, api->PQgetisnull, "PQgetisnull") &&
			loadSymbol(*api, api->PQcmdTuples, "PQcmdTuples") &&
			loadSymbol(*api, api->PQcmdStatus, "PQcmdStatus") &&
			loadSymbol(*api, api->PQoidValue, "PQoidValue") &&
			loadSymbol(*api, api->PQclear, "PQclear") &&
			loadSymbol(*api, api->PQescapeStringConn, "PQescapeStringConn") &&
			loadSymbol(*api, api->PQexecParams, "PQexecParams") &&
			loadSymbol(*api, api->PQgetlength, "PQgetlength") &&
			loadSymbol(*api, api->PQgetCancel, "PQgetCancel") &&
			loadSymbol(*api, api->PQcancel, "PQcancel") &&
			loadSymbol(*api, api->PQfreeCancel, "PQfreeCancel");

		if (!ok) {
#if defined(_WIN32)
			FreeLibrary(api->module);
#else
			dlclose(api->module);
#endif
			delete api;
			return nullptr;
		}

		loadSymbol(*api, api->PQtransactionStatus, "PQtransactionStatus");
		return api;
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

	// Called inside a GC-free zone. The lock is a native one and is held only
	// for loading, which is why waiting on it there is safe: nobody holding it
	// can be waiting on the collector.
	const LibPQApi* loadLibrary(const std::vector<std::string>& candidates, std::string& error) {
		std::lock_guard<std::mutex> guard(g_loadLock);

		for (size_t i = 0; i < candidates.size(); ++i) {
			for (size_t j = 0; j < g_libraries.size(); ++j) {
				if (g_libraries[j]->path == candidates[i]) {
					return g_libraries[j];
				}
			}

			LibPQApi* api = tryLoad(candidates[i]);

			if (api != nullptr) {
				g_libraries.push_back(api);
				return api;
			}
		}

		std::string tried;
		for (size_t i = 0; i < candidates.size(); ++i) {
			tried += (i == 0 ? "" : ", ") + candidates[i];
		}
		error = "Could not load libpq or its required symbols (tried " + tried + ").";
		return nullptr;
	}

	int parseAffectedRows(const LibPQApi* api, PGresult* result) {
		const char* raw = api->PQcmdTuples(result);
		if (raw == nullptr || raw[0] == '\0') {
			return 0;
		}
		return std::atoi(raw);
	}

	bool succeeded(ExecStatusType status) {
		return status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK || status == PGRES_SINGLE_TUPLE || status == PGRES_EMPTY_QUERY;
	}

	// Runs inside the GC-free zone, and takes ownership of `result`.
	std::string renderJson(const Handle& handle, PGresult* result) {
		const LibPQApi* api = handle.api;

		if (result == nullptr) {
			return makeErrorJson(trimMessage(api->PQerrorMessage(handle.conn), "PQexec returned null."));
		}

		ResultGuard guard = {api, result};

		if (!succeeded(api->PQresultStatus(result))) {
			return makeErrorJson(trimMessage(api->PQerrorMessage(handle.conn), "Postgres query failed."));
		}

		std::ostringstream out;
		out << "{\"rows\":[";

		int rows = api->PQntuples(result);
		int fields = api->PQnfields(result);
		for (int row = 0; row < rows; ++row) {
			if (row > 0) {
				out << ",";
			}
			out << "{";
			for (int field = 0; field < fields; ++field) {
				if (field > 0) {
					out << ",";
				}
				const char* name = api->PQfname(result, field);
				out << "\"" << jsonEscape(name == nullptr ? "" : name) << "\":";
				if (api->PQgetisnull(result, row, field) == 1) {
					out << "null";
				} else {
					const char* value = api->PQgetvalue(result, row, field);
					out << "\"" << jsonEscape(value == nullptr ? "" : value) << "\"";
				}
			}
			out << "}";
		}

		// The command tag, because it is the only thing that tells a COMMIT
		// that committed from one the server turned into a ROLLBACK: both
		// arrive as success.
		const char* command = api->PQcmdStatus(result);

		out << "],\"affectedRows\":" << parseAffectedRows(api, result);
		out << ",\"lastInsertRowID\":" << static_cast<unsigned int>(api->PQoidValue(result));
		out << ",\"command\":\"" << jsonEscape(command == nullptr ? "" : command) << "\"";
		out << "}";
		return out.str();
	}

	// Little-endian, a byte at a time, so neither side depends on the host byte
	// order. Mirrored by PostgresWire on the Haxe side.
	inline unsigned char* putInt(unsigned char* out, int value) {
		out[0] = static_cast<unsigned char>(value & 0xFF);
		out[1] = static_cast<unsigned char>((value >> 8) & 0xFF);
		out[2] = static_cast<unsigned char>((value >> 16) & 0xFF);
		out[3] = static_cast<unsigned char>((value >> 24) & 0xFF);
		return out + 4;
	}

	inline unsigned char* putBytes(unsigned char* out, const char* data, int length) {
		if (length > 0 && data != nullptr) {
			std::memcpy(out, data, static_cast<size_t>(length));
		}
		return out + (length > 0 ? length : 0);
	}

	bool takeInt(const unsigned char* data, int length, int& cursor, int& value) {
		if (cursor < 0 || length - cursor < 4) {
			return false;
		}

		value = static_cast<int>(static_cast<unsigned int>(data[cursor])
			| (static_cast<unsigned int>(data[cursor + 1]) << 8)
			| (static_cast<unsigned int>(data[cursor + 2]) << 16)
			| (static_cast<unsigned int>(data[cursor + 3]) << 24));
		cursor += 4;
		return true;
	}

	Array<unsigned char> errorBlock(const std::string& message) {
		int size = 8 + static_cast<int>(message.size());
		Array<unsigned char> block = Array_obj<unsigned char>::__new(size, size);
		unsigned char* out = reinterpret_cast<unsigned char*>(block->GetBase());
		out = putInt(out, 1);
		out = putInt(out, static_cast<int>(message.size()));
		putBytes(out, message.data(), static_cast<int>(message.size()));
		return block;
	}

	// Bound values, copied out of the caller's block into one native arena,
	// each followed by a NUL: libpq reads a text-format value as a C string
	// and ignores its length, and a zero-length value still needs a pointer
	// that is not null.
	struct Parameters {
		std::vector<char> arena;
		std::vector<size_t> offsets;
		std::vector<int> lengths;
		std::vector<int> formats;
		std::vector<const char*> values;
	};

	bool parseParameters(const unsigned char* block, int length, Parameters& out, std::string& error) {
		int cursor = 0;
		int count = 0;

		if (block == nullptr || !takeInt(block, length, cursor, count) || count < 0) {
			error = "Malformed parameter block.";
			return false;
		}

		// Each parameter costs at least its eight header bytes, so a count the
		// block cannot hold is refused before anything is sized by it.
		if (count > (length - cursor) / 8) {
			error = "Truncated parameter block.";
			return false;
		}

		out.arena.reserve(static_cast<size_t>(length - cursor) + static_cast<size_t>(count));
		out.offsets.assign(static_cast<size_t>(count), 0);
		out.lengths.assign(static_cast<size_t>(count), 0);
		out.formats.assign(static_cast<size_t>(count), 0);
		out.values.assign(static_cast<size_t>(count), nullptr);

		std::vector<bool> isNull(static_cast<size_t>(count), false);

		for (int i = 0; i < count; ++i) {
			int format = 0;
			int valueLength = 0;

			if (!takeInt(block, length, cursor, format) || !takeInt(block, length, cursor, valueLength)) {
				error = "Truncated parameter block.";
				return false;
			}

			out.formats[static_cast<size_t>(i)] = format == 1 ? 1 : 0;

			if (valueLength < 0) {
				// SQL NULL is a null pointer, which is how libpq tells it apart
				// from a zero-length value.
				isNull[static_cast<size_t>(i)] = true;
				continue;
			}

			// Difference, not sum: `cursor + length` overflows for a large
			// length, and signed overflow is undefined, so the truncation check
			// this is here to perform could be optimised away.
			if (valueLength > length - cursor) {
				error = "Truncated parameter block.";
				return false;
			}

			out.offsets[static_cast<size_t>(i)] = out.arena.size();
			out.arena.insert(out.arena.end(), block + cursor, block + cursor + valueLength);
			out.arena.push_back('\0');
			out.lengths[static_cast<size_t>(i)] = valueLength;
			cursor += valueLength;
		}

		// Pointers last: the arena is done growing.
		for (int i = 0; i < count; ++i) {
			if (!isNull[static_cast<size_t>(i)]) {
				out.values[static_cast<size_t>(i)] = out.arena.data() + out.offsets[static_cast<size_t>(i)];
			}
		}

		return true;
	}

	// Encodes a successful result straight into the Haxe array it is returned
	// in: sized first, then written once, so the rows cross from libpq's
	// memory into the caller's in a single copy with nothing in between.
	Array<unsigned char> encodeResult(const LibPQApi* api, PGresult* result) {
		int rows = api->PQntuples(result);
		int fields = api->PQnfields(result);

		long long size = 20;

		for (int field = 0; field < fields; ++field) {
			const char* name = api->PQfname(result, field);
			size += 4 + (name == nullptr ? 0 : static_cast<long long>(std::strlen(name)));
		}

		for (int row = 0; row < rows; ++row) {
			for (int field = 0; field < fields; ++field) {
				size += 4;
				if (api->PQgetisnull(result, row, field) != 1) {
					size += api->PQgetlength(result, row, field);
				}
			}
		}

		if (size > INT_MAX) {
			std::ostringstream message;
			message << "The result is " << size << " bytes, more than one call can return; fetch it in parts.";
			return errorBlock(message.str());
		}

		int total = static_cast<int>(size);
		Array<unsigned char> block = Array_obj<unsigned char>::__new(total, total);
		unsigned char* out = reinterpret_cast<unsigned char*>(block->GetBase());

		out = putInt(out, 0);
		out = putInt(out, parseAffectedRows(api, result));
		out = putInt(out, static_cast<int>(api->PQoidValue(result)));
		out = putInt(out, fields);

		for (int field = 0; field < fields; ++field) {
			const char* name = api->PQfname(result, field);
			int nameLength = name == nullptr ? 0 : static_cast<int>(std::strlen(name));
			out = putInt(out, nameLength);
			out = putBytes(out, name, nameLength);
		}

		out = putInt(out, rows);

		for (int row = 0; row < rows; ++row) {
			for (int field = 0; field < fields; ++field) {
				if (api->PQgetisnull(result, row, field) == 1) {
					out = putInt(out, -1);
					continue;
				}

				// PQgetlength rather than strlen: a value may contain NUL bytes,
				// and measuring it as a C string is exactly how they get lost.
				int length = api->PQgetlength(result, row, field);
				out = putInt(out, length);
				out = putBytes(out, api->PQgetvalue(result, row, field), length);
			}
		}

		return block;
	}
}

void* crossbyte_postgres_open(::String conninfo, Array< ::String > libraryPaths) {
	std::string info = toNative(conninfo);
	std::vector<std::string> candidates;

	if (libraryPaths.mPtr != nullptr) {
		for (int i = 0; i < libraryPaths->length; ++i) {
			std::string entry = toNative(libraryPaths[i]);
			size_t start = entry.find_first_not_of(" \t\r\n");
			size_t end = entry.find_last_not_of(" \t\r\n");
			if (start != std::string::npos) {
				candidates.push_back(entry.substr(start, end - start + 1));
			}
		}
	}

	std::vector<std::string> defaults = defaultCandidates();
	candidates.insert(candidates.end(), defaults.begin(), defaults.end());

	Handle* handle = new Handle();

	{
		hx::AutoGCFreeZone zone;

		handle->api = loadLibrary(candidates, handle->error);

		if (handle->api != nullptr) {
			const LibPQApi* api = handle->api;
			PGconn* connection = api->PQconnectdb(info.c_str());

			if (connection == nullptr) {
				handle->error = "PQconnectdb returned null.";
			} else if (api->PQstatus(connection) != CONNECTION_OK) {
				handle->error = trimMessage(api->PQerrorMessage(connection), "Connection failed.");
				api->PQfinish(connection);
			} else {
				handle->conn = connection;
				handle->cancel = api->PQgetCancel(connection);
			}
		}

		// The connection string carries the password; this copy at least does
		// not outlive the call.
		if (!info.empty()) {
			std::memset(&info[0], 0, info.size());
		}
	}

	return handle;
}

::String crossbyte_postgres_error(void* handle) {
	Handle* h = static_cast<Handle*>(handle);
	return h == nullptr ? ::String("Postgres connection could not be allocated.") : toHaxe(h->error);
}

void crossbyte_postgres_close(void* handle) {
	Handle* h = static_cast<Handle*>(handle);

	if (h == nullptr) {
		return;
	}

	{
		// PQfinish tells the server goodbye, which is a write to a socket that
		// may be past saving.
		hx::AutoGCFreeZone zone;

		if (h->cancel != nullptr) {
			h->api->PQfreeCancel(h->cancel);
		}

		if (h->conn != nullptr) {
			h->api->PQfinish(h->conn);
		}
	}

	delete h;
}

bool crossbyte_postgres_is_open(void* handle) {
	Handle* h = static_cast<Handle*>(handle);
	return h != nullptr && h->conn != nullptr && h->api->PQstatus(h->conn) == CONNECTION_OK;
}

::String crossbyte_postgres_request_json(void* handle, ::String sql) {
	Handle* h = static_cast<Handle*>(handle);

	if (h == nullptr || h->conn == nullptr) {
		return toHaxe(makeErrorJson("Postgres connection is not open."));
	}

	std::string text = toNative(sql);
	std::string json;

	{
		hx::AutoGCFreeZone zone;
		json = renderJson(*h, h->api->PQexec(h->conn, text.c_str()));
	}

	return toHaxe(json);
}

Array<unsigned char> crossbyte_postgres_request_params(void* handle, ::String sql, Array<unsigned char> params, int paramsLength) {
	Handle* h = static_cast<Handle*>(handle);

	if (h == nullptr || h->conn == nullptr) {
		return errorBlock("Postgres connection is not open.");
	}

	int available = params.mPtr == nullptr ? 0 : params->length;

	if (paramsLength < 0 || paramsLength > available) {
		return errorBlock("Malformed parameter block.");
	}

	Parameters bound;
	std::string failure;

	if (!parseParameters(paramsLength == 0 ? nullptr : reinterpret_cast<const unsigned char*>(params->GetBase()), paramsLength, bound, failure)) {
		return errorBlock(failure);
	}

	std::string text = toNative(sql);
	const LibPQApi* api = h->api;
	PGresult* result = nullptr;
	int count = static_cast<int>(bound.values.size());

	{
		hx::AutoGCFreeZone zone;

		// resultFormat 0, so results arrive as text and bytea as its hex
		// rendering, which is exact. Binary results would mean decoding every
		// column type from its network representation by OID.
		result = api->PQexecParams(h->conn, text.c_str(), count, nullptr,
			count == 0 ? nullptr : bound.values.data(), count == 0 ? nullptr : bound.lengths.data(),
			count == 0 ? nullptr : bound.formats.data(), 0);

		if (result == nullptr) {
			failure = trimMessage(api->PQerrorMessage(h->conn), "PQexecParams returned null.");
		} else if (!succeeded(api->PQresultStatus(result))) {
			failure = trimMessage(api->PQerrorMessage(h->conn), "Postgres query failed.");
			api->PQclear(result);
			result = nullptr;
		}
	}

	if (result == nullptr) {
		return errorBlock(failure);
	}

	ResultGuard guard = {api, result};
	return encodeResult(api, result);
}

::String crossbyte_postgres_escape(void* handle, ::String value) {
	Handle* h = static_cast<Handle*>(handle);
	std::string raw = toNative(value);

	if (h == nullptr || h->conn == nullptr) {
		return value;
	}

	std::string out;
	out.resize(raw.size() * 2 + 1);
	int error = 0;
	// On an encoding error libpq still writes an escaped string, the server
	// then rejects it as malformed, so that is what is returned. This used to
	// hand back the value unescaped instead, which is the one answer an escape
	// function must never give.
	size_t written = h->api->PQescapeStringConn(h->conn, &out[0], raw.c_str(), raw.size(), &error);
	out.resize(written);
	return toHaxe(out);
}

bool crossbyte_postgres_cancel(void* handle) {
	Handle* h = static_cast<Handle*>(handle);

	if (h == nullptr || h->cancel == nullptr) {
		return false;
	}

	char errbuf[256];
	int sent = 0;

	{
		// A round trip on a connection of its own, so it blocks as long as
		// the server takes to answer.
		hx::AutoGCFreeZone zone;
		sent = h->api->PQcancel(h->cancel, errbuf, static_cast<int>(sizeof(errbuf)));
	}

	return sent == 1;
}

int crossbyte_postgres_transaction_status(void* handle) {
	Handle* h = static_cast<Handle*>(handle);

	if (h == nullptr || h->conn == nullptr || h->api->PQtransactionStatus == nullptr) {
		return -1;
	}

	// Reads what the server said at the end of the last statement; no I/O,
	// so no GC-free zone.
	return static_cast<int>(h->api->PQtransactionStatus(h->conn));
}
