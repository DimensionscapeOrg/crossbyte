#include <hxcpp.h>

#include "NativeSharedObject.h"

#include <cctype>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#if defined(_WIN32)
#include <Windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace
{
	constexpr uint32_t SHARED_OBJECT_MAGIC = 0x4F424A53; // 'OJBS'
	constexpr size_t MAX_SAFE_NAME_LENGTH = 160;

	struct SharedObjectHeader
	{
		uint32_t magic;
		uint32_t payloadSize;
		uint32_t capacity;
	};

	struct SharedObjectState
	{
#if defined(_WIN32)
		HANDLE fileMapping;
		void* view;
		HANDLE mutex;
#else
		int fd;
		void* view;
		size_t viewSize;
#endif
		// What the mapping has room for after the header, measured here
		// rather than taken from the header: the header is written by
		// whichever participant initialised it, and one that opened the name
		// asking for more than its creator made wrote its own size there.
		size_t payloadRoom;
	};

	size_t defaultCapacity()
	{
		return 64 * 1024;
	}

	std::string sourceName(const char* name)
	{
		return (name == nullptr || name[0] == '\0') ? "default" : name;
	}

	uint64_t hashName(const std::string& input)
	{
		uint64_t hash = 1469598103934665603ULL;
		for (unsigned char c : input)
		{
			hash ^= static_cast<uint64_t>(c);
			hash *= 1099511628211ULL;
		}
		return hash;
	}

	std::string hexHash(uint64_t hash)
	{
		const char* digits = "0123456789abcdef";
		std::string output(16, '0');
		for (int i = 15; i >= 0; --i)
		{
			output[i] = digits[hash & 0x0f];
			hash >>= 4;
		}
		return output;
	}

	std::string sanitizeName(const std::string& input)
	{
		std::string safe;
		safe.reserve(input.size());

		for (unsigned char c : input)
		{
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
			{
				safe.push_back(static_cast<char>(c));
			}
			else
			{
				safe.push_back('_');
			}
		}

		if (safe.empty())
		{
			safe = "default";
		}
		if (safe.size() > MAX_SAFE_NAME_LENGTH)
		{
			safe.resize(MAX_SAFE_NAME_LENGTH);
		}

		return safe;
	}

	std::string makeUniqueNameSuffix(const char* name)
	{
		std::string source = sourceName(name);
		return sanitizeName(source) + "_" + hexHash(hashName(source));
	}

#if defined(_WIN32)
	std::string makeSharedName(const char* name)
	{
		return "Local\\CrossByteSharedObject_" + makeUniqueNameSuffix(name);
	}
#else
	std::string makeSharedName(const char* name)
	{
		return "/crossbyte_shared_object_" + makeUniqueNameSuffix(name);
	}
#endif

	SharedObjectHeader* headerFromHandle(void* view)
	{
		return static_cast<SharedObjectHeader*>(view);
	}

	unsigned char* payloadFromHandle(void* view)
	{
		return static_cast<unsigned char*>(view) + sizeof(SharedObjectHeader);
	}

	bool isValidHeader(SharedObjectHeader* header)
	{
		return header != nullptr && header->magic == SHARED_OBJECT_MAGIC;
	}

	// The most a payload may hold: what the header says, but never more than
	// the mapping has.
	size_t payloadLimit(SharedObjectState* state, SharedObjectHeader* header)
	{
		size_t declared = static_cast<size_t>(header->capacity);
		return declared < state->payloadRoom ? declared : state->payloadRoom;
	}

	// Sets up a header nobody has yet, sized to what the mapping holds.
	void initialiseHeader(SharedObjectHeader* header, size_t payloadRoom, int maxSize)
	{
		size_t wanted = static_cast<size_t>(maxSize);
		header->magic = SHARED_OBJECT_MAGIC;
		header->payloadSize = 0;
		header->capacity = static_cast<uint32_t>(wanted < payloadRoom ? wanted : payloadRoom);
	}

	// The region's lock is held by whichever participant is reading or
	// writing it, in any process, and waited for outside the collector's
	// reach: a collection another thread of this process started does not
	// wait on a thread that is waiting on another process. Nothing the
	// collector owns is touched until the wait is over.
#if defined(_WIN32)
	bool lockForHandle(SharedObjectState* state)
	{
		if (state != nullptr && state->mutex != nullptr)
		{
			hx::AutoGCFreeZone waiting;
			DWORD lockResult = WaitForSingleObject(state->mutex, INFINITE);
			return (lockResult == WAIT_OBJECT_0 || lockResult == WAIT_ABANDONED);
		}
		return false;
	}

	void unlockForHandle(SharedObjectState* state)
	{
		if (state != nullptr && state->mutex != nullptr)
		{
			ReleaseMutex(state->mutex);
		}
	}
#else
	bool lockDescriptor(int fd)
	{
		if (fd < 0)
		{
			return false;
		}

		hx::AutoGCFreeZone waiting;
		int result;
		do
		{
			result = flock(fd, LOCK_EX);
		} while (result != 0 && errno == EINTR);
		return result == 0;
	}

	bool lockForHandle(SharedObjectState* state)
	{
		return state != nullptr && lockDescriptor(state->fd);
	}

	void unlockForHandle(SharedObjectState* state)
	{
		if (state != nullptr && state->fd >= 0)
		{
			flock(state->fd, LOCK_UN);
		}
	}
#endif
}

extern "C" void* native_sharedObjectOpen(const char* name, int maxSize)
{
	if (maxSize < 1)
	{
		maxSize = static_cast<int>(defaultCapacity());
	}

	std::string sharedName = makeSharedName(name);

#if defined(_WIN32)
	HANDLE fileMapping = CreateFileMappingA(
		INVALID_HANDLE_VALUE,
		nullptr,
		PAGE_READWRITE,
		0,
		sizeof(SharedObjectHeader) + static_cast<DWORD>(maxSize),
		sharedName.c_str());
	if (fileMapping == nullptr)
	{
		return nullptr;
	}

	void* viewHandle = MapViewOfFile(fileMapping, FILE_MAP_ALL_ACCESS, 0, 0, 0);
	if (viewHandle == nullptr)
	{
		CloseHandle(fileMapping);
		return nullptr;
	}

	// A mapping that already existed keeps the size its creator gave it,
	// whatever was asked for here, and the view covers all of it.
	MEMORY_BASIC_INFORMATION viewInfo;
	if (VirtualQuery(viewHandle, &viewInfo, sizeof(viewInfo)) == 0 || viewInfo.RegionSize <= sizeof(SharedObjectHeader))
	{
		UnmapViewOfFile(viewHandle);
		CloseHandle(fileMapping);
		return nullptr;
	}

	std::string mutexName = sharedName + "_mutex";
	HANDLE mutex = CreateMutexA(nullptr, FALSE, mutexName.c_str());
	if (mutex == nullptr)
	{
		UnmapViewOfFile(viewHandle);
		CloseHandle(fileMapping);
		return nullptr;
	}

	auto* state = new (std::nothrow) SharedObjectState();
	if (state == nullptr)
	{
		CloseHandle(mutex);
		UnmapViewOfFile(viewHandle);
		CloseHandle(fileMapping);
		return nullptr;
	}

	state->fileMapping = fileMapping;
	state->view = viewHandle;
	state->mutex = mutex;
	state->payloadRoom = static_cast<size_t>(viewInfo.RegionSize) - sizeof(SharedObjectHeader);

	if (!lockForHandle(state))
	{
		delete state;
		CloseHandle(mutex);
		UnmapViewOfFile(viewHandle);
		CloseHandle(fileMapping);
		return nullptr;
	}

	auto* header = headerFromHandle(viewHandle);
	if (!isValidHeader(header) || header->capacity == 0)
	{
		initialiseHeader(header, state->payloadRoom, maxSize);
	}

	unlockForHandle(state);
	return state;
#else
	int fd = shm_open(sharedName.c_str(), O_RDWR | O_CREAT, 0666);
	if (fd < 0)
	{
		return nullptr;
	}

	// Sized and set up under the region's lock, by whichever participant
	// takes it first. The creator sized it before taking the lock, so one
	// opening the name in that moment found it empty and failed, or, if it
	// took the lock before the creator did, wrote its own maxSize into the
	// header, past the end of a smaller mapping.
	if (!lockDescriptor(fd))
	{
		close(fd);
		return nullptr;
	}

	struct stat sharedInfo;
	bool sized = fstat(fd, &sharedInfo) == 0;
	if (sized && sharedInfo.st_size <= static_cast<off_t>(sizeof(SharedObjectHeader)))
	{
		size_t wantedSize = sizeof(SharedObjectHeader) + static_cast<size_t>(maxSize);
		sized = ftruncate(fd, static_cast<off_t>(wantedSize)) == 0 && fstat(fd, &sharedInfo) == 0;
	}

	if (!sized || sharedInfo.st_size <= static_cast<off_t>(sizeof(SharedObjectHeader)))
	{
		flock(fd, LOCK_UN);
		close(fd);
		return nullptr;
	}

	size_t mappedSize = static_cast<size_t>(sharedInfo.st_size);
	void* viewHandle = mmap(nullptr, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (viewHandle == MAP_FAILED)
	{
		flock(fd, LOCK_UN);
		close(fd);
		return nullptr;
	}

	auto* state = new (std::nothrow) SharedObjectState();
	if (state == nullptr)
	{
		munmap(viewHandle, mappedSize);
		flock(fd, LOCK_UN);
		close(fd);
		return nullptr;
	}

	state->fd = fd;
	state->view = viewHandle;
	state->viewSize = mappedSize;
	state->payloadRoom = mappedSize - sizeof(SharedObjectHeader);

	auto* header = headerFromHandle(viewHandle);
	if (!isValidHeader(header) || header->capacity == 0)
	{
		initialiseHeader(header, state->payloadRoom, maxSize);
	}

	unlockForHandle(state);
	return state;
#endif
}

extern "C" void native_sharedObjectClose(void* handle)
{
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr)
	{
		return;
	}

#if defined(_WIN32)
	if (state->view != nullptr)
	{
		UnmapViewOfFile(state->view);
	}

	if (state->fileMapping != nullptr)
	{
		CloseHandle(state->fileMapping);
	}

	if (state->mutex != nullptr)
	{
		CloseHandle(state->mutex);
	}
#else
	if (state->view != nullptr && state->view != MAP_FAILED)
	{
		munmap(state->view, state->viewSize);
	}

	if (state->fd >= 0)
	{
		close(state->fd);
	}
#endif
	delete state;
}

extern "C" int native_sharedObjectGetCapacity(void* handle)
{
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr)
	{
		return -1;
	}

	if (!lockForHandle(state))
	{
		return -1;
	}

	auto* header = headerFromHandle(state->view);
	if (!isValidHeader(header))
	{
		unlockForHandle(state);
		return -1;
	}

	int capacity = static_cast<int>(payloadLimit(state, header));
	unlockForHandle(state);
	return capacity;
}

extern "C" bool native_sharedObjectWrite(void* handle, const unsigned char* data, int dataSize)
{
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr || data == nullptr || dataSize < 0)
	{
		return false;
	}

	if (!lockForHandle(state))
	{
		return false;
	}

	auto* header = headerFromHandle(state->view);
	if (!isValidHeader(header) || static_cast<size_t>(dataSize) > payloadLimit(state, header))
	{
		unlockForHandle(state);
		return false;
	}

	std::memcpy(payloadFromHandle(state->view), data, static_cast<size_t>(dataSize));
	header->payloadSize = static_cast<uint32_t>(dataSize);
	unlockForHandle(state);
	return true;
}

// The payload's length and its bytes, under one acquisition of the lock:
// copied into `buffer` when it fits there, and its length returned either
// way, so a caller whose buffer was too small knows what to take next time.
// -1 when the region cannot be read.
//
// The length and the bytes were two calls, each locking for itself, and a
// flush between them left a copy cut to the old length or short of the new.
extern "C" int native_sharedObjectReadPayload(void* handle, unsigned char* buffer, int bufferSize)
{
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr || buffer == nullptr || bufferSize < 0)
	{
		return -1;
	}

	if (!lockForHandle(state))
	{
		return -1;
	}

	auto* header = headerFromHandle(state->view);
	if (!isValidHeader(header) || static_cast<size_t>(header->payloadSize) > payloadLimit(state, header))
	{
		unlockForHandle(state);
		return -1;
	}

	int dataSize = static_cast<int>(header->payloadSize);
	if (dataSize > 0 && dataSize <= bufferSize)
	{
		std::memcpy(buffer, payloadFromHandle(state->view), static_cast<size_t>(dataSize));
	}

	unlockForHandle(state);
	return dataSize;
}

extern "C" void native_sharedObjectClear(void* handle)
{
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr)
	{
		return;
	}

	if (!lockForHandle(state))
	{
		return;
	}

	auto* header = headerFromHandle(state->view);
	if (isValidHeader(header))
	{
		header->payloadSize = 0;
	}

	unlockForHandle(state);
}
