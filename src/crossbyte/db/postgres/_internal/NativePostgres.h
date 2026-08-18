#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void* crossbyte_postgres_open(const char* host, int port, const char* user, const char* password, const char* database, const char* sslMode, int connectTimeout, Array<String> libraryPaths);
void crossbyte_postgres_close(void* handle);
bool crossbyte_postgres_is_open(void* handle);
const char* crossbyte_postgres_request_json(void* handle, const char* sql);
// Runs a statement with bound parameters and returns the length of the encoded
// result block, which is then read from crossbyte_postgres_result_data(). Two
// calls rather than one because the block carries NUL bytes and so cannot be
// returned as a C string. PostgresWire documents the format.
int crossbyte_postgres_request_params(void* handle, const char* sql, const unsigned char* params, int paramsLength);

const unsigned char* crossbyte_postgres_result_data();

const char* crossbyte_postgres_escape(void* handle, const char* value);
const char* crossbyte_postgres_last_error();

#ifdef __cplusplus
}
#endif
