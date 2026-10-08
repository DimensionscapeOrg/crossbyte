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
#include <chrono>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <thread>
#include <unistd.h>
#endif

namespace
{
	constexpr uint32_t SHARED_OBJECT_MAGIC = 0x4F424A53; // 'OJBS'
	constexpr size_t MAX_SAFE_NAME_LENGTH = 160;

	// Why the last call on this thread failed: what
	// native_sharedObjectLastError answers, so that a caller can tell a lock
	// another participant did not release in time from a region that cannot
	// be used.
	thread_local int lastError = SHARED_OBJECT_ERROR_NONE;

#if !defined(_WIN32)
	// flock() has no timed form, so a wait with a deadline asks again and
	// again without blocking, pausing between asks: briefly at first, since
	// a live holder keeps the lock for one copy, then up to this long.
	constexpr long LOCK_POLL_MAX_US = 1000;

	// How often, at most, a lock file in use has its times brought up to
	// date: often enough that a cleaner of old files in /tmp (macOS's
	// takes what nobody has touched for three days, systemd's for ten)
	// never finds one in use old.
	constexpr long LOCK_FILE_REFRESH_SECONDS = 3600;
#endif

#if !defined(_WIN32)
	// macOS caps a shared memory object's name at 31 characters (PSHMNAMLEN)
	// and refuses flock() on its descriptor (ENOTSUP, since it locks only
	// files), so a region there could neither be opened under its name nor
	// locked. There a region takes a
	// short name, its hash alone, and is locked through a regular file in
	// /tmp, which a process's death unlocks as it does a region's. Both ways
	// are compiled on every POSIX target, so a Linux build checks the macOS
	// one, and turning this on runs it there.
#if defined(__APPLE__)
	constexpr bool SHORT_NAME_AND_LOCK_FILE = true;
#else
	constexpr bool SHORT_NAME_AND_LOCK_FILE = false;
#endif
#endif

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
		// The descriptor the region's lock is taken on: `fd` itself, or on
		// macOS the lock file's (-1 when the file there could not be taken
		// again); see lockFileOfState.
		int lockFd;
		void* view;
		size_t viewSize;
		// macOS: the lock file's path, and when its times were last brought
		// up to date.
		std::string lockPath;
		std::chrono::steady_clock::time_point lockRefreshed;
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
		if (SHORT_NAME_AND_LOCK_FILE)
		{
			// 22 characters: the 64-bit hash of the whole name.
			return "/cbso_" + hexHash(hashName(sourceName(name)));
		}
		return "/crossbyte_shared_object_" + makeUniqueNameSuffix(name);
	}

	// The regular file whose lock stands for the region's on macOS.
	std::string makeLockPath(const char* name)
	{
		return "/tmp/cbso_" + hexHash(hashName(sourceName(name))) + ".lock";
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
	//
	// The wait ends after `timeoutMs`, or never with 0 or less, so a
	// participant stopped while holding the lock (suspended in a debugger,
	// sent SIGSTOP, starved on a loaded machine) stops every other
	// participant with it no longer than that. One that
	// dies releases it: Windows abandons a dead owner's mutex to the next
	// waiter, and a process's flock() locks go with its descriptors.
#if defined(_WIN32)
	bool lockForHandle(SharedObjectState* state, int timeoutMs)
	{
		if (state == nullptr || state->mutex == nullptr)
		{
			lastError = SHARED_OBJECT_ERROR_FAILED;
			return false;
		}

		// Free, nearly always: taken without entering the zone.
		DWORD lockResult = WaitForSingleObject(state->mutex, 0);
		if (lockResult == WAIT_TIMEOUT)
		{
			hx::AutoGCFreeZone waiting;
			lockResult = WaitForSingleObject(state->mutex, timeoutMs > 0 ? static_cast<DWORD>(timeoutMs) : INFINITE);
		}
		if (lockResult == WAIT_OBJECT_0 || lockResult == WAIT_ABANDONED)
		{
			return true;
		}

		lastError = lockResult == WAIT_TIMEOUT ? SHARED_OBJECT_ERROR_LOCK_TIMEOUT : SHARED_OBJECT_ERROR_FAILED;
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
	// Whether the lock was refused only because someone holds it.
	bool lockIsBusy()
	{
		return errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR;
	}

	bool lockDescriptor(int fd, int timeoutMs)
	{
		if (fd < 0)
		{
			lastError = SHARED_OBJECT_ERROR_FAILED;
			return false;
		}

		// Free, nearly always: taken with no clock read and no wait.
		if (flock(fd, LOCK_EX | LOCK_NB) == 0)
		{
			return true;
		}
		if (!lockIsBusy())
		{
			lastError = SHARED_OBJECT_ERROR_FAILED;
			return false;
		}

		hx::AutoGCFreeZone waiting;
		if (timeoutMs <= 0)
		{
			int result;
			do
			{
				result = flock(fd, LOCK_EX);
			} while (result != 0 && errno == EINTR);
			if (result != 0)
			{
				lastError = SHARED_OBJECT_ERROR_FAILED;
			}
			return result == 0;
		}

		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
		long pauseUs = 50;
		while (true)
		{
			auto now = std::chrono::steady_clock::now();
			if (now >= deadline)
			{
				lastError = SHARED_OBJECT_ERROR_LOCK_TIMEOUT;
				return false;
			}

			long leftUs = static_cast<long>(std::chrono::duration_cast<std::chrono::microseconds>(deadline - now).count());
			std::this_thread::sleep_for(std::chrono::microseconds(pauseUs < leftUs ? pauseUs : leftUs));
			if (pauseUs < LOCK_POLL_MAX_US)
			{
				pauseUs = pauseUs * 2 < LOCK_POLL_MAX_US ? pauseUs * 2 : LOCK_POLL_MAX_US;
			}

			if (flock(fd, LOCK_EX | LOCK_NB) == 0)
			{
				return true;
			}
			if (!lockIsBusy())
			{
				lastError = SHARED_OBJECT_ERROR_FAILED;
				return false;
			}
		}
	}

	int takeLockFile(const std::string& path, int timeoutMs);
	bool lockFileOfState(SharedObjectState* state, int timeoutMs);

	bool lockForHandle(SharedObjectState* state, int timeoutMs)
	{
		if (state == nullptr)
		{
			lastError = SHARED_OBJECT_ERROR_FAILED;
			return false;
		}
		if (SHORT_NAME_AND_LOCK_FILE)
		{
			return lockFileOfState(state, timeoutMs);
		}
		return lockDescriptor(state->lockFd, timeoutMs);
	}

	void unlockForHandle(SharedObjectState* state)
	{
		if (state != nullptr && state->lockFd >= 0)
		{
			flock(state->lockFd, LOCK_UN);
		}
	}

	// Undoes an open that failed after taking the region's lock.
	void abandonOpen(int fd, int lockFd)
	{
		flock(lockFd, LOCK_UN);
		if (lockFd != fd)
		{
			close(lockFd);
		}
		close(fd);
	}

	// Whether `fd` is this user's, so another user cannot have put it
	// under a shared name to be used in its place: owned by this user, and
	// for a lock file a regular file. One readable or writable by others is
	// made this user's alone: anyone who could open a lock file could hold
	// its lock, and anyone who could read a region could read what it holds.
	// (A region's mode on macOS carries no file type, so a region's is not
	// asked for.)
	bool isOwnFile(int fd, bool regular)
	{
		struct stat info;
		if (fstat(fd, &info) != 0 || info.st_uid != geteuid() || (regular && !S_ISREG(info.st_mode)))
		{
			return false;
		}
		if ((info.st_mode & 077) != 0)
		{
			// As far as the system lets it: not every OS takes a mode for a
			// shared memory object after it is made.
			fchmod(fd, 0600);
		}
		return true;
	}

	// Whether what failed to open under a shared name failed because
	// something not this user's is there: a link, a directory, another
	// user's file.
	bool isForeign(int error)
	{
		return error == ELOOP || error == EACCES || error == EPERM || error == EISDIR || error == ENXIO || error == EMLINK;
	}

	// Whether `fd` is the file at `path` now. Not following a link there: one
	// would name something else.
	bool isAtPath(int fd, const std::string& path)
	{
		struct stat held;
		struct stat named;
		return fstat(fd, &held) == 0 && lstat(path.c_str(), &named) == 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino;
	}

	// macOS: the lock file at `path`, opened (made, if there is none) and
	// checked to be this user's own regular file.
	//
	// It is in /tmp, where any user can put something at a name first, so
	// it is not opened through a link (another user's link there would make
	// this process make or lock a file wherever it pointed), not waited on
	// as a FIFO (which would hold the open, and this process's collector
	// with it, until someone wrote to it), and is this user's alone (flock()
	// needs only read access, so any user could otherwise hold every
	// participant's lock). Anything else is refused.
	int openLockFile(const std::string& path)
	{
		int lockFd = open(path.c_str(), O_RDONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
		if (lockFd < 0)
		{
			lastError = isForeign(errno) ? SHARED_OBJECT_ERROR_NOT_OWNED : SHARED_OBJECT_ERROR_FAILED;
			return -1;
		}
		if (!isOwnFile(lockFd, true))
		{
			close(lockFd);
			lastError = SHARED_OBJECT_ERROR_NOT_OWNED;
			return -1;
		}
		return lockFd;
	}

	// Brings the lock file's times up to date: see LOCK_FILE_REFRESH_SECONDS.
	// Its owner may, whatever its mode.
	void refreshLockFile(int lockFd)
	{
		futimes(lockFd, nullptr);
	}

	// macOS: the lock file's descriptor with its lock held, checked once held
	// to be the file at `path` still. native_sharedObjectRemove takes the
	// region and its lock file away under that lock, so a file opened before
	// a removal and locked after it stands for no region: it is let go, and
	// the file at the path (a new one, if need be) taken instead. Every
	// participant of a region locks the same file.
	int takeLockFile(const std::string& path, int timeoutMs)
	{
		for (int attempt = 0; attempt < 8; attempt++)
		{
			int lockFd = openLockFile(path);
			if (lockFd < 0)
			{
				return -1;
			}
			if (!lockDescriptor(lockFd, timeoutMs))
			{
				close(lockFd);
				return -1;
			}
			if (isAtPath(lockFd, path))
			{
				refreshLockFile(lockFd);
				return lockFd;
			}
			flock(lockFd, LOCK_UN);
			close(lockFd);
		}
		lastError = SHARED_OBJECT_ERROR_FAILED;
		return -1;
	}

	// macOS: the region's lock, taken through the lock file at its path now.
	//
	// The file can go while a handle lives: macOS's cleaner deletes what in
	// /tmp nobody has touched for three days, and a lock taken does not
	// touch it. The next participant to open the name would then make a new
	// file and lock that, while this one went on locking the old: two
	// participants each holding the region's lock, both writing. So the
	// file held is checked once locked to be the one at the path still, and
	// if it is not, let go for the one there, made anew if need be, as the
	// next participant to open would make it. The times of the file in use
	// are brought up to date hourly, so the cleaner does not find it old to
	// begin with.
	bool lockFileOfState(SharedObjectState* state, int timeoutMs)
	{
		if (state->lockFd >= 0)
		{
			if (!lockDescriptor(state->lockFd, timeoutMs))
			{
				return false;
			}
			if (isAtPath(state->lockFd, state->lockPath))
			{
				auto now = std::chrono::steady_clock::now();
				if (now - state->lockRefreshed >= std::chrono::seconds(LOCK_FILE_REFRESH_SECONDS))
				{
					refreshLockFile(state->lockFd);
					state->lockRefreshed = now;
				}
				return true;
			}
			flock(state->lockFd, LOCK_UN);
			close(state->lockFd);
			state->lockFd = -1;
		}

		int lockFd = takeLockFile(state->lockPath, timeoutMs);
		if (lockFd < 0)
		{
			return false;
		}
		state->lockFd = lockFd;
		state->lockRefreshed = std::chrono::steady_clock::now();
		return true;
	}
#endif
}

extern "C" int native_sharedObjectLastError()
{
	return lastError;
}

extern "C" void* native_sharedObjectOpen(const char* name, int maxSize, int lockTimeoutMs)
{
	// Anything below that does not say otherwise failed outright.
	lastError = SHARED_OBJECT_ERROR_FAILED;

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

	if (!lockForHandle(state, lockTimeoutMs))
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
	lastError = SHARED_OBJECT_ERROR_NONE;
	return state;
#else
	// Sized and set up under the region's lock, by whichever participant
	// takes it first, so one opening the name as it is made does not find
	// it empty, nor write its own maxSize into the header past the end of a
	// smaller mapping.
	//
	// On macOS the lock file is taken first, and the region opened under its
	// lock: a removal, which holds that lock, then cannot come between the
	// two and leave this participant a removed region's lock with a new
	// region, or a new lock with the removed region.
	int lockFd = -1;
	std::string lockPath;
	if (SHORT_NAME_AND_LOCK_FILE)
	{
		lockPath = makeLockPath(name);
		lockFd = takeLockFile(lockPath, lockTimeoutMs);
		if (lockFd < 0)
		{
			return nullptr;
		}
	}

	// This user's alone, and one another user made under the name refused.
	// Made for anyone to read (0666 less the umask), every local user could
	// read what every SharedObject held, and hold its lock on Linux; and one
	// another user made first, for anyone to write, would be used as if it
	// were this one's.
	int fd = shm_open(sharedName.c_str(), O_RDWR | O_CREAT, 0600);
	int openError = errno;
	if (fd >= 0 && !isOwnFile(fd, false))
	{
		close(fd);
		fd = -1;
		openError = EPERM;
	}
	if (fd < 0)
	{
		lastError = isForeign(openError) ? SHARED_OBJECT_ERROR_NOT_OWNED : SHARED_OBJECT_ERROR_FAILED;
		if (lockFd >= 0)
		{
			flock(lockFd, LOCK_UN);
			close(lockFd);
		}
		return nullptr;
	}

	if (!SHORT_NAME_AND_LOCK_FILE)
	{
		lockFd = fd;
		if (!lockDescriptor(lockFd, lockTimeoutMs))
		{
			close(fd);
			return nullptr;
		}
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
		abandonOpen(fd, lockFd);
		return nullptr;
	}

	size_t mappedSize = static_cast<size_t>(sharedInfo.st_size);
	void* viewHandle = mmap(nullptr, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (viewHandle == MAP_FAILED)
	{
		abandonOpen(fd, lockFd);
		return nullptr;
	}

	auto* state = new (std::nothrow) SharedObjectState();
	if (state == nullptr)
	{
		munmap(viewHandle, mappedSize);
		abandonOpen(fd, lockFd);
		return nullptr;
	}

	state->fd = fd;
	state->lockFd = lockFd;
	state->view = viewHandle;
	state->viewSize = mappedSize;
	state->payloadRoom = mappedSize - sizeof(SharedObjectHeader);
	state->lockPath = lockPath;
	state->lockRefreshed = std::chrono::steady_clock::now();

	auto* header = headerFromHandle(viewHandle);
	if (!isValidHeader(header) || header->capacity == 0)
	{
		initialiseHeader(header, state->payloadRoom, maxSize);
	}

	unlockForHandle(state);
	lastError = SHARED_OBJECT_ERROR_NONE;
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

	if (state->lockFd >= 0 && state->lockFd != state->fd)
	{
		close(state->lockFd);
	}

	if (state->fd >= 0)
	{
		close(state->fd);
	}
#endif
	delete state;
}

extern "C" int native_sharedObjectGetCapacity(void* handle, int lockTimeoutMs)
{
	lastError = SHARED_OBJECT_ERROR_FAILED;
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr)
	{
		return -1;
	}

	if (!lockForHandle(state, lockTimeoutMs))
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
	lastError = SHARED_OBJECT_ERROR_NONE;
	return capacity;
}

extern "C" bool native_sharedObjectWrite(void* handle, const unsigned char* data, int dataSize, int lockTimeoutMs)
{
	lastError = SHARED_OBJECT_ERROR_FAILED;
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr || data == nullptr || dataSize < 0)
	{
		return false;
	}

	if (!lockForHandle(state, lockTimeoutMs))
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
	lastError = SHARED_OBJECT_ERROR_NONE;
	return true;
}

// The payload's length and its bytes, under one acquisition of the lock:
// copied into `buffer` when it fits there, and its length returned either
// way, so a caller whose buffer was too small knows what to take next time.
// -1 when the region cannot be read.
//
// One lock for both, so a flush between the length and the bytes cannot
// leave a copy cut to the old length or short of the new.
extern "C" int native_sharedObjectReadPayload(void* handle, unsigned char* buffer, int bufferSize, int lockTimeoutMs)
{
	lastError = SHARED_OBJECT_ERROR_FAILED;
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr || buffer == nullptr || bufferSize < 0)
	{
		return -1;
	}

	if (!lockForHandle(state, lockTimeoutMs))
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
	lastError = SHARED_OBJECT_ERROR_NONE;
	return dataSize;
}

// Whether the lock was taken: a region whose header is not one of ours has
// nothing to clear, and is left as it is.
extern "C" bool native_sharedObjectClear(void* handle, int lockTimeoutMs)
{
	lastError = SHARED_OBJECT_ERROR_FAILED;
	auto* state = static_cast<SharedObjectState*>(handle);
	if (state == nullptr || state->view == nullptr)
	{
		return false;
	}

	if (!lockForHandle(state, lockTimeoutMs))
	{
		return false;
	}

	auto* header = headerFromHandle(state->view);
	if (isValidHeader(header))
	{
		header->payloadSize = 0;
	}

	unlockForHandle(state);
	lastError = SHARED_OBJECT_ERROR_NONE;
	return true;
}

// Takes the name `name` away from its region: 1 when one had it, 0 when none
// did, -1 when it could not be done (native_sharedObjectLastError says why).
// Handles open on the region keep it, between them, until they close; the
// next open of the name makes a new one.
//
// Windows has no name to take away while a handle is open, and none to take
// once the last one closes: a region goes with its last handle. 0 there.
extern "C" int native_sharedObjectRemove(const char* name, int lockTimeoutMs)
{
#if defined(_WIN32)
	lastError = SHARED_OBJECT_ERROR_NONE;
	return 0;
#else
	lastError = SHARED_OBJECT_ERROR_FAILED;
	std::string sharedName = makeSharedName(name);

	// On macOS under the lock file's lock, which every open takes before it
	// opens the region; see native_sharedObjectOpen. The lock file goes with
	// the region. On Linux the lock is the region's own, and an open that
	// found the region before it lost its name shares it with the rest.
	std::string lockPath;
	int lockFd = -1;
	if (SHORT_NAME_AND_LOCK_FILE)
	{
		lockPath = makeLockPath(name);
		lockFd = takeLockFile(lockPath, lockTimeoutMs);
		if (lockFd < 0)
		{
			return -1;
		}
	}

	int removed = shm_unlink(sharedName.c_str()) == 0 ? 1 : (errno == ENOENT ? 0 : -1);

	if (lockFd >= 0)
	{
		unlink(lockPath.c_str());
		flock(lockFd, LOCK_UN);
		close(lockFd);
	}
	if (removed >= 0)
	{
		lastError = SHARED_OBJECT_ERROR_NONE;
	}
	return removed;
#endif
}

// Tests only: the region's lock, taken through `handle` on the calling thread
// with no deadline and kept until native_sharedObjectReleaseLockForTest: a
// participant stopped while holding it. Windows' mutex belongs to the thread
// that took it, so another thread of the same process waits on it as another
// process would, and the same thread releases it.
extern "C" bool native_sharedObjectHoldLockForTest(void* handle)
{
	return lockForHandle(static_cast<SharedObjectState*>(handle), 0);
}

extern "C" void native_sharedObjectReleaseLockForTest(void* handle)
{
	unlockForHandle(static_cast<SharedObjectState*>(handle));
}
