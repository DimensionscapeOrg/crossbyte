#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void* crossbyte_postgres_open(const char* host, int port, const char* user, const char* password, const char* database, const char* sslMode, int connectTimeout, Array<String> libraryPaths);
void crossbyte_postgres_close(void* handle);
bool crossbyte_postgres_is_open(void* handle);
const char* crossbyte_postgres_request_json(void* handle, const char* sql);
const char* crossbyte_postgres_escape(void* handle, const char* value);
const char* crossbyte_postgres_last_error();

#ifdef __cplusplus
}
#endif
