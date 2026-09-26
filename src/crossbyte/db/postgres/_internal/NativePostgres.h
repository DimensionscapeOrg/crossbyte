#pragma once

// C++ linkage: these take and return hxcpp types, so every result reaches the
// caller as its own Haxe object rather than through a buffer the bridge keeps.

// Opens a connection. Returns a handle whether or not it succeeded -- null
// only if the handle itself could not be allocated -- and the reason it failed
// is read from crossbyte_postgres_error() before the handle is closed. Per
// handle, so connections opening on several threads cannot report each
// other's failures.
void* crossbyte_postgres_open(::String conninfo, Array< ::String > libraryPaths);
::String crossbyte_postgres_error(void* handle);
void crossbyte_postgres_close(void* handle);
bool crossbyte_postgres_is_open(void* handle);
::String crossbyte_postgres_request_json(void* handle, ::String sql);
// Runs a statement with bound parameters and returns the encoded result block
// in one call. PostgresWire documents the format.
Array<unsigned char> crossbyte_postgres_request_params(void* handle, ::String sql, Array<unsigned char> params, int paramsLength);
::String crossbyte_postgres_escape(void* handle, ::String value);
// Asks the server to cancel whatever the connection is running. Safe from any
// thread while another runs a query on the connection; the caller keeps the
// handle alive for the duration.
bool crossbyte_postgres_cancel(void* handle);
