#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Why the last call on this thread failed, as native_sharedObjectLastError()
// reports it.
#define SHARED_OBJECT_ERROR_NONE 0
// Another participant held the region's lock past the call's deadline.
#define SHARED_OBJECT_ERROR_LOCK_TIMEOUT 1
// Anything else: the region could not be made, mapped, locked or read.
#define SHARED_OBJECT_ERROR_FAILED 2

// Each call that takes the region's lock waits at most lockTimeoutMs for it,
// or for as long as it takes with 0 or less.
void* native_sharedObjectOpen(const char* name, int maxSize, int lockTimeoutMs);
void native_sharedObjectClose(void* handle);
int native_sharedObjectReadPayload(void* handle, unsigned char* buffer, int bufferSize, int lockTimeoutMs);
bool native_sharedObjectWrite(void* handle, const unsigned char* data, int dataSize, int lockTimeoutMs);
bool native_sharedObjectClear(void* handle, int lockTimeoutMs);
int native_sharedObjectGetCapacity(void* handle, int lockTimeoutMs);
int native_sharedObjectLastError();

// Tests only: takes the region's lock on the calling thread and keeps it
// until native_sharedObjectReleaseLockForTest, called on the same thread.
bool native_sharedObjectHoldLockForTest(void* handle);
void native_sharedObjectReleaseLockForTest(void* handle);

#ifdef __cplusplus
}
#endif
