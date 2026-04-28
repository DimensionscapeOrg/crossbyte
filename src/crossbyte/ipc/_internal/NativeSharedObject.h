#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void* native_sharedObjectOpen(const char* name, int maxSize);
void native_sharedObjectClose(void* handle);
int native_sharedObjectRead(void* handle, unsigned char* buffer, int bufferSize);
bool native_sharedObjectWrite(void* handle, const unsigned char* data, int dataSize);
void native_sharedObjectClear(void* handle);
int native_sharedObjectGetDataLength(void* handle);
int native_sharedObjectGetCapacity(void* handle);

#ifdef __cplusplus
}
#endif
