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

#if defined(_WIN32)
	bool lockForHandle(SharedObjectState* state)
	{
		if (state != nullptr && state->mutex != nullptr)
		{
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
	bool lockForHandle(SharedObjectState* state)
	{
		return state != nullptr && state->fd >= 0 && flock(state->fd, LOCK_EX) == 0;
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

	if (!lockForHandle(state))
	{
		delete state;
		CloseHandle(mutex);
		UnmapViewOfFile(viewHandle);
		CloseHandle(fileMapping);
		return nullptr;
	}

	auto* header = headerFromHandle(viewHandle);
	if (!isValidHeader(header))
	{
		header->magic = SHARED_OBJECT_MAGIC;
		header->payloadSize = 0;
		header->capacity = static_cast<uint32_t>(maxSize);
	}
	else if (header->capacity == 0)
	{
		header->capacity = static_cast<uint32_t>(maxSize);
	}

	unlockForHandle(state);
	return state;
#else
	bool created = false;
	int fd = shm_open(sharedName.c_str(), O_RDWR | O_CREAT | O_EXCL, 0666);
	if (fd >= 0)
	{
		created = true;
	}
	else if (errno == EEXIST)
	{
		fd = shm_open(sharedName.c_str(), O_RDWR, 0666);
	}
	else
	{
		return nullptr;
	}

	if (fd < 0)
	{
		return nullptr;
	}

	if (created)
	{
		size_t mappedSize = sizeof(SharedObjectHeader) + static_cast<size_t>(maxSize);
		if (ftruncate(fd, static_cast<off_t>(mappedSize)) != 0)
		{
			close(fd);
			return nullptr;
		}
	}

	struct stat sharedInfo;
	if (fstat(fd, &sharedInfo) != 0 || sharedInfo.st_size < static_cast<off_t>(sizeof(SharedObjectHeader)))
	{
		close(fd);
		return nullptr;
	}

	size_t mappedSize = static_cast<size_t>(sharedInfo.st_size);
	void* viewHandle = mmap(nullptr, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (viewHandle == MAP_FAILED)
	{
		close(fd);
		return nullptr;
	}

	auto* state = new (std::nothrow) SharedObjectState();
	if (state == nullptr)
	{
		munmap(viewHandle, mappedSize);
		close(fd);
		return nullptr;
	}

	state->fd = fd;
	state->view = viewHandle;
	state->viewSize = mappedSize;

	if (!lockForHandle(state))
	{
		munmap(viewHandle, mappedSize);
		close(fd);
		delete state;
		return nullptr;
	}

	auto* header = headerFromHandle(viewHandle);
	if (!isValidHeader(header) || header->capacity == 0)
	{
		header->magic = SHARED_OBJECT_MAGIC;
		header->payloadSize = 0;
		header->capacity = static_cast<uint32_t>(maxSize);
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

extern "C" int native_sharedObjectGetDataLength(void* handle)
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

	int dataLength = static_cast<int>(header->payloadSize);
	unlockForHandle(state);
	return dataLength;
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

	int capacity = static_cast<int>(header->capacity);
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
	if (!isValidHeader(header) || dataSize > static_cast<int>(header->capacity))
	{
		unlockForHandle(state);
		return false;
	}

	std::memcpy(payloadFromHandle(state->view), data, static_cast<size_t>(dataSize));
	header->payloadSize = static_cast<uint32_t>(dataSize);
	unlockForHandle(state);
	return true;
}

extern "C" int native_sharedObjectRead(void* handle, unsigned char* buffer, int bufferSize)
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
	if (!isValidHeader(header))
	{
		unlockForHandle(state);
		return -1;
	}

	int dataSize = static_cast<int>(header->payloadSize);
	int bytesToCopy = (bufferSize < dataSize ? bufferSize : dataSize);
	if (bytesToCopy > 0)
	{
		std::memcpy(buffer, payloadFromHandle(state->view), static_cast<size_t>(bytesToCopy));
	}

	unlockForHandle(state);
	return bytesToCopy;
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
