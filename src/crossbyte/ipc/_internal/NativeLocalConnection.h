#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Why the last native_createInboundPipe or native_connectWithTimeout on this
// thread failed, as native_localConnectionLastError() reports it.
#define LOCAL_CONNECTION_ERROR_NONE 0
// The name is in use, nothing listens on it, or it cannot be used.
#define LOCAL_CONNECTION_ERROR_FAILED 1
// What is under the name is not this user's own: on Linux and macOS the
// directory names live in, or what is at the name's socket path; on Windows
// the pipe a client found.
#define LOCAL_CONNECTION_ERROR_NOT_OWNED 2

void* native_createInboundPipe(const char* name);
bool native_accept(void* pipe);
bool native_disconnect(void* pipe);
bool native_isOpen(void* pipe);
int native_getBytesAvailable(void* pipe);
int native_read(void* pipe, unsigned char* buffer, int bufferSize);
int native_writeSome(void* pipe, const unsigned char* buffer, int bufferSize);
bool native_write(void* pipe, const unsigned char* buffer, int bufferSize);
void* native_connect(const char* name);
void* native_connectWithTimeout(const char* name, int timeoutMs);
void native_close(void* pipe);
void native_keepName(void* pipe);
int native_localConnectionLastError();

// Tests only: whether a listener's pipe admits anyone but this user and
// SYSTEM, or is owned by anyone else. Always false off Windows.
bool native_admitsOthersForTest(void* pipe);

#ifdef __cplusplus
}
#endif
