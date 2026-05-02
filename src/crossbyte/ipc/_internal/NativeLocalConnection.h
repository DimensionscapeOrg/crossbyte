#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void* native_createInboundPipe(const char* name);
bool native_accept(void* pipe);
bool native_isOpen(void* pipe);
int native_getBytesAvailable(void* pipe);
int native_read(void* pipe, unsigned char* buffer, int bufferSize);
bool native_write(void* pipe, const unsigned char* buffer, int bufferSize);
void* native_connect(const char* name);
void* native_connectWithTimeout(const char* name, int timeoutMs);
void native_close(void* pipe);

#ifdef __cplusplus
}
#endif
