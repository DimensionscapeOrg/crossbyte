#include <hxcpp.h>

#include "NativeLocalConnection.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#if defined(_WIN32)
#include <Windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#endif

#include <string>

namespace
{
	constexpr int PIPE_BUFFER_SIZE = 65536;
	constexpr int CONNECT_TIMEOUT_MS = 5000;
	constexpr int CONNECT_WAIT_SLICE_MS = 50;
	constexpr int PIPE_LISTEN_BACKLOG = 16;

	const char* PIPE_PREFIX = "/tmp/crossbyte_local_connection_";
	const size_t PIPE_PREFIX_LENGTH = std::strlen(PIPE_PREFIX);

	// Whether another attempt fits before `deadline`: a connect with no time
	// left makes one attempt, and does not sleep a slice first.
	bool sliceLeft(std::chrono::steady_clock::time_point deadline)
	{
		return std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_WAIT_SLICE_MS) < deadline;
	}

	// A connect's deadline is `timeoutMs` from now, or none at all with 0 or
	// less: then it tries until something listens. 0 made a single try,
	// where a connect everywhere else in CrossByte waits without a deadline.
	bool anotherTry(bool forever, std::chrono::steady_clock::time_point deadline)
	{
		return forever || sliceLeft(deadline);
	}

#if defined(_WIN32)
	bool isInvalid(HANDLE pipe)
	{
		return pipe == nullptr || pipe == INVALID_HANDLE_VALUE;
	}

	std::string makePipeName(const char* name)
	{
		return std::string("\\\\.\\pipe\\") + (name == nullptr ? "" : name);
	}

	// The one instance of the name, or nothing if the name is taken.
	//
	// The pipe was made with PIPE_UNLIMITED_INSTANCES, so a second listen()
	// on a name in use made a second instance beside the first, and clients
	// went to whichever the system picked. FILE_FLAG_FIRST_PIPE_INSTANCE
	// refuses a name any instance of which exists, and one instance is all a
	// listener needs: it takes each client in turn, and native_disconnect
	// makes it ready for the next.
	extern "C" void* native_createInboundPipe(const char* name)
	{
		std::string pipeName = makePipeName(name);

		HANDLE pipe = CreateNamedPipeA(
			pipeName.c_str(),
			PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
			PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT,
			1,
			PIPE_BUFFER_SIZE,
			PIPE_BUFFER_SIZE,
			0,
			nullptr);

		return pipe == INVALID_HANDLE_VALUE ? nullptr : pipe;
	}

	extern "C" bool native_accept(void* pipe)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle))
		{
			return false;
		}

		BOOL success = ConnectNamedPipe(handle, nullptr);
		if (success)
		{
			return true;
		}

		// ERROR_NO_DATA: a client came and went before this looked. It is
		// taken like any other: what it wrote is read, its leaving is found,
		// and native_disconnect readies the instance for the next. It was
		// taken for "nobody yet", and the instance stayed closing for good,
		// every later client finding it busy.
		DWORD error = GetLastError();
		return error == ERROR_PIPE_CONNECTED || error == ERROR_NO_DATA;
	}

	// Lets the client go and keeps the name: the instance takes the next
	// client through native_accept, and nobody else can take the name
	// between the two.
	extern "C" bool native_disconnect(void* pipe)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle))
		{
			return false;
		}
		return DisconnectNamedPipe(handle) != FALSE;
	}

	extern "C" int native_read(void* pipe, unsigned char* buffer, int bufferSize)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return ERROR_INVALID_PARAMETER;
		}

		int totalRead = 0;
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_TIMEOUT_MS);
		while (totalRead < bufferSize)
		{
			DWORD bytesRead = 0;
			if (ReadFile(handle, buffer + totalRead, static_cast<DWORD>(bufferSize - totalRead), &bytesRead, nullptr))
			{
				if (bytesRead > 0)
				{
					totalRead += static_cast<int>(bytesRead);
					continue;
				}
			}

			DWORD error = GetLastError();
			if (error == ERROR_MORE_DATA)
			{
				continue;
			}
			if (error == ERROR_NO_DATA)
			{
				if (std::chrono::steady_clock::now() >= deadline)
				{
					return ERROR_TIMEOUT;
				}
				Sleep(1);
				continue;
			}
			if (error == ERROR_BROKEN_PIPE || error == ERROR_INVALID_HANDLE || error == ERROR_PIPE_NOT_CONNECTED)
			{
				return static_cast<int>(error);
			}
			if (std::chrono::steady_clock::now() >= deadline)
			{
				return error == ERROR_SUCCESS ? ERROR_TIMEOUT : static_cast<int>(error);
			}
			Sleep(1);
		}

		return 0;
	}

	// As much of `buffer` as the pipe takes now, without waiting: the bytes
	// written, 0 when the pipe is full, -1 when the connection is gone. A
	// nonblocking byte-mode pipe with too little room writes what fits.
	extern "C" int native_writeSome(void* pipe, const unsigned char* buffer, int bufferSize)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize < 0)
		{
			return -1;
		}

		int totalWritten = 0;
		while (totalWritten < bufferSize)
		{
			int writeSize = bufferSize - totalWritten;
			if (writeSize > PIPE_BUFFER_SIZE)
			{
				writeSize = PIPE_BUFFER_SIZE;
			}
			DWORD bytesWritten = 0;
			if (!WriteFile(handle, buffer + totalWritten, static_cast<DWORD>(writeSize), &bytesWritten, nullptr))
			{
				DWORD error = GetLastError();
				if (error == ERROR_NO_DATA || error == ERROR_BROKEN_PIPE || error == ERROR_INVALID_HANDLE || error == ERROR_PIPE_NOT_CONNECTED)
				{
					return totalWritten > 0 ? totalWritten : -1;
				}
				break;
			}
			if (bytesWritten == 0)
			{
				break;
			}
			totalWritten += static_cast<int>(bytesWritten);
		}

		return totalWritten;
	}

	// All of `buffer`, waiting up to CONNECT_TIMEOUT_MS: for tests that write a
	// raw frame. LocalConnection writes through native_writeSome.
	//
	// It waits outside the collector's reach. LocalConnection.send wrote
	// through this, on the runtime's thread, and a collection another thread
	// started meanwhile waited for it, the peer's reader among them, so a
	// frame larger than the pipe waited on a reader that waited on it, until
	// the five seconds were up. `buffer` stays where it is: the caller holds
	// it, and hxcpp's collector does not move objects.
	extern "C" bool native_write(void* pipe, const unsigned char* buffer, int bufferSize)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return false;
		}

		hx::AutoGCFreeZone waiting;
		int totalWritten = 0;
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_TIMEOUT_MS);
		while (totalWritten < bufferSize)
		{
			int written = native_writeSome(pipe, buffer + totalWritten, bufferSize - totalWritten);
			if (written < 0)
			{
				return false;
			}
			totalWritten += written;
			if (totalWritten < bufferSize)
			{
				if (std::chrono::steady_clock::now() >= deadline)
				{
					return false;
				}
				Sleep(1);
			}
		}

		return true;
	}

	extern "C" void native_close(void* pipe)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle))
		{
			return;
		}

		CloseHandle(handle);
	}

	extern "C" void* native_connectWithTimeout(const char* name, int timeoutMs)
	{
		std::string pipeName = makePipeName(name);
		bool forever = timeoutMs <= 0;
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(forever ? 0 : timeoutMs);

		// It may wait for a listener, on the caller's thread: outside the
		// collector's reach meanwhile, so a collection another thread starts
		// does not wait for it. Nothing of the GC's is touched from here on;
		// the name was copied above.
		hx::AutoGCFreeZone waiting;
		while (true)
		{
			HANDLE pipe = CreateFileA(
				pipeName.c_str(),
				GENERIC_READ | GENERIC_WRITE,
				0,
				nullptr,
				OPEN_EXISTING,
				0,
				nullptr);

			if (pipe != INVALID_HANDLE_VALUE)
			{
				DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
				SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
				return pipe;
			}

			DWORD error = GetLastError();
			if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND)
			{
				return nullptr;
			}
			// No time left for another attempt: one try, without the wait.
			if (!anotherTry(forever, deadline))
			{
				return nullptr;
			}
			if (error == ERROR_PIPE_BUSY)
			{
				WaitNamedPipeA(pipeName.c_str(), CONNECT_WAIT_SLICE_MS);
			}
			else
			{
				Sleep(CONNECT_WAIT_SLICE_MS);
			}
		}
	}

	extern "C" void* native_connect(const char* name)
	{
		return native_connectWithTimeout(name, CONNECT_TIMEOUT_MS);
	}

	extern "C" int native_getBytesAvailable(void* pipe)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle))
		{
			return -1;
		}

		DWORD bytesAvailable = 0;
		if (PeekNamedPipe(handle, nullptr, 0, nullptr, &bytesAvailable, nullptr))
		{
			return static_cast<int>(bytesAvailable);
		}

		DWORD error = GetLastError();
		if (error == ERROR_NO_DATA)
		{
			return 0;
		}
		if (error == ERROR_BROKEN_PIPE || error == ERROR_INVALID_HANDLE || error == ERROR_PIPE_NOT_CONNECTED)
		{
			return -1;
		}
		return 0;
	}

	extern "C" bool native_isOpen(void* pipe)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle))
		{
			return false;
		}

		DWORD bytesAvailable = 0;
		if (PeekNamedPipe(handle, nullptr, 0, nullptr, &bytesAvailable, nullptr))
		{
			return true;
		}

		DWORD error = GetLastError();
		if (error == ERROR_NO_DATA)
		{
			return true;
		}
		return error != ERROR_BROKEN_PIPE && error != ERROR_INVALID_HANDLE && error != ERROR_PIPE_NOT_CONNECTED;
	}
#else
	// A send to a peer that has gone raises SIGPIPE, whose default action
	// ends the process, unless the send says not to. macOS has no flag for
	// it and sets SO_NOSIGPIPE on the socket instead; see
	// configureConnectedSocket.
#if defined(MSG_NOSIGNAL)
	constexpr int SEND_FLAGS = MSG_NOSIGNAL;
#else
	constexpr int SEND_FLAGS = 0;
#endif

	struct NativeLocalConnectionHandle
	{
		int listenFd;
		int clientFd;
		// Held for as long as this listens on its name: see createInboundPipe.
		int lockFd;
		char path[108];
	};

	bool isInvalid(NativeLocalConnectionHandle* handle)
	{
		return handle == nullptr;
	}

	void configureListeningSocket(int fd)
	{
		int flags = fcntl(fd, F_GETFL, 0);
		if (flags != -1)
		{
			fcntl(fd, F_SETFL, flags | O_NONBLOCK);
		}
	}

	void configureConnectedSocket(int fd)
	{
#if defined(__APPLE__)
		int optionValue = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &optionValue, sizeof(optionValue));
#endif
	}

	// The socket path for `name`.
	//
	// It was the name with everything outside [A-Za-z0-9_-] made '_' and cut to
	// 48 characters, so "a.b" and "a_b", or two long names alike for their
	// first 48, were one socket, and the second to listen took the first's
	// clients. A name that needs neither keeps its path; any other is a
	// readable part of it and a 64-bit FNV-1a hash of the whole.
	std::string sanitizePipeName(const char* name)
	{
		const size_t budget = 48;
		std::string source = (name == nullptr || name[0] == '\0') ? "default" : name;
		std::string sanitized;
		bool changed = false;

		for (char c : source)
		{
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
			{
				sanitized.push_back(c);
			}
			else
			{
				sanitized.push_back('_');
				changed = true;
			}
		}

		if (!changed && sanitized.size() <= budget)
		{
			return std::string(PIPE_PREFIX) + sanitized;
		}

		uint64_t hash = 1469598103934665603ULL;
		for (unsigned char c : source)
		{
			hash ^= c;
			hash *= 1099511628211ULL;
		}
		char hex[17];
		std::snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(hash));

		const size_t keep = budget - 17;
		return std::string(PIPE_PREFIX) + sanitized.substr(0, sanitized.size() < keep ? sanitized.size() : keep) + "_" + hex;
	}

	std::string makePipeName(const char* name)
	{
		return sanitizePipeName(name);
	}

	NativeLocalConnectionHandle* createHandle()
	{
		auto* handle = new (std::nothrow) NativeLocalConnectionHandle();
		if (handle == nullptr)
		{
			return nullptr;
		}

		handle->listenFd = -1;
		handle->clientFd = -1;
		handle->lockFd = -1;
		handle->path[0] = '\0';
		return handle;
	}

	int getActiveFd(NativeLocalConnectionHandle* handle)
	{
		if (isInvalid(handle))
		{
			return -1;
		}

		return handle->clientFd >= 0 ? handle->clientFd : handle->listenFd;
	}

	// An exclusive lock on `path`.lock, taken without waiting: the descriptor
	// holding it, or -1 when another listener has it. The system lets it go
	// when its holder exits, however it exits, so a name a crashed listener
	// left is free again. Checked to be the file now at that path, since a
	// listener closing removes it: a lock on one already removed holds
	// nothing.
	int lockName(const std::string& path)
	{
		std::string lockPath = path + ".lock";
		for (int attempt = 0; attempt < 8; attempt++)
		{
			int fd = open(lockPath.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
			if (fd < 0)
			{
				return -1;
			}
			if (flock(fd, LOCK_EX | LOCK_NB) != 0)
			{
				close(fd);
				return -1;
			}
			struct stat held;
			struct stat current;
			if (fstat(fd, &held) == 0 && stat(lockPath.c_str(), &current) == 0 && held.st_ino == current.st_ino && held.st_dev == current.st_dev)
			{
				return fd;
			}
			close(fd);
		}
		return -1;
	}

	// The listener for `name`, or nothing if another listener has it.
	//
	// It removed whatever socket file was at the path before binding, so a
	// second listen() on a name in use took the first's place, and its
	// clients. The name is now held by a lock: a live listener's name is
	// refused, and only a stale file, from a listener that has gone, is
	// removed.
	extern "C" void* native_createInboundPipe(const char* name)
	{
		std::string pipeName = makePipeName(name);
		if (pipeName.size() + 5 >= sizeof(((sockaddr_un*)nullptr)->sun_path))
		{
			return nullptr;
		}

		NativeLocalConnectionHandle* handle = createHandle();
		if (handle == nullptr)
		{
			return nullptr;
		}

		int lockFd = lockName(pipeName);
		if (lockFd < 0)
		{
			delete handle;
			return nullptr;
		}

		int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (listenFd < 0)
		{
			close(lockFd);
			delete handle;
			return nullptr;
		}

		sockaddr_un address;
		std::memset(&address, 0, sizeof(address));
		address.sun_family = AF_UNIX;
		std::memcpy(address.sun_path, pipeName.data(), pipeName.size());
		address.sun_path[pipeName.size()] = '\0';

		unlink(pipeName.c_str());
		if (bind(listenFd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0
			|| listen(listenFd, PIPE_LISTEN_BACKLOG) < 0
		)
		{
			close(listenFd);
			close(lockFd);
			delete handle;
			return nullptr;
		}

		configureListeningSocket(listenFd);
		handle->listenFd = listenFd;
		handle->lockFd = lockFd;
		std::memcpy(handle->path, pipeName.data(), pipeName.size());
		handle->path[pipeName.size()] = '\0';
		return handle;
	}

	extern "C" bool native_accept(void* pipe)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle) || handle->listenFd < 0)
		{
			return false;
		}

		int clientFd = accept(handle->listenFd, nullptr, nullptr);
		if (clientFd < 0)
		{
			return false;
		}

		if (handle->clientFd >= 0)
		{
			close(handle->clientFd);
		}
		handle->clientFd = clientFd;
		configureConnectedSocket(clientFd);
		return true;
	}

	// Lets the client go and keeps listening: the next accept takes the next
	// client, and the name is held throughout.
	extern "C" bool native_disconnect(void* pipe)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle) || handle->listenFd < 0)
		{
			return false;
		}
		if (handle->clientFd >= 0)
		{
			close(handle->clientFd);
			handle->clientFd = -1;
		}
		return true;
	}

	extern "C" bool native_isOpen(void* pipe)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle))
		{
			return false;
		}

		int fd = getActiveFd(handle);
		if (fd < 0)
		{
			return false;
		}

		char probe;
		ssize_t result = recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT);
		if (result > 0)
		{
			return true;
		}
		if (result == 0)
		{
			return false;
		}
		return errno == EAGAIN || errno == EWOULDBLOCK;
	}

	extern "C" int native_read(void* pipe, unsigned char* buffer, int bufferSize)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return -1;
		}

		int fd = getActiveFd(handle);
		if (fd < 0)
		{
			return -1;
		}

		int bytesReadTotal = 0;
		while (bytesReadTotal < bufferSize)
		{
			ssize_t bytesRead = recv(fd, reinterpret_cast<char*>(buffer) + bytesReadTotal, bufferSize - bytesReadTotal, 0);
			if (bytesRead > 0)
			{
				bytesReadTotal += static_cast<int>(bytesRead);
				continue;
			}

			if (bytesRead == 0)
			{
				return -1;
			}
			if (errno == EINTR)
			{
				continue;
			}
			return -1;
		}

		return 0;
	}

	// As much of `buffer` as the socket takes now, without waiting: the bytes
	// written, 0 when it is full, -1 when the connection is gone.
	extern "C" int native_writeSome(void* pipe, const unsigned char* buffer, int bufferSize)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize < 0)
		{
			return -1;
		}

		int fd = getActiveFd(handle);
		if (fd < 0 || fd == handle->listenFd)
		{
			return -1;
		}

		int bytesWritten = 0;
		while (bytesWritten < bufferSize)
		{
			ssize_t sendResult = send(fd, reinterpret_cast<const char*>(buffer) + bytesWritten, bufferSize - bytesWritten, MSG_DONTWAIT | SEND_FLAGS);
			if (sendResult > 0)
			{
				bytesWritten += static_cast<int>(sendResult);
				continue;
			}
			if (sendResult < 0 && errno == EINTR)
			{
				continue;
			}
			if (sendResult < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			{
				break;
			}
			return bytesWritten > 0 ? bytesWritten : -1;
		}

		return bytesWritten;
	}

	// All of `buffer`: for tests that write a raw frame. LocalConnection
	// writes through native_writeSome. It waits outside the collector's
	// reach; see the Windows version.
	extern "C" bool native_write(void* pipe, const unsigned char* buffer, int bufferSize)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return false;
		}

		int fd = getActiveFd(handle);
		if (fd < 0)
		{
			return false;
		}

		hx::AutoGCFreeZone waiting;
		int bytesWritten = 0;
		while (bytesWritten < bufferSize)
		{
			ssize_t sendResult = send(fd, reinterpret_cast<const char*>(buffer) + bytesWritten, bufferSize - bytesWritten, SEND_FLAGS);
			if (sendResult > 0)
			{
				bytesWritten += static_cast<int>(sendResult);
				continue;
			}
			if (sendResult == 0 || errno == EPIPE)
			{
				return false;
			}
			if (errno == EINTR)
			{
				continue;
			}
			return false;
		}

		return true;
	}

	extern "C" void native_close(void* pipe)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle))
		{
			return;
		}

		if (handle->clientFd >= 0)
		{
			close(handle->clientFd);
			handle->clientFd = -1;
		}

		if (handle->listenFd >= 0)
		{
			close(handle->listenFd);
			unlink(handle->path);
			handle->listenFd = -1;
		}

		if (handle->lockFd >= 0)
		{
			// Removed while still held, so nobody locks the file on its way
			// out; see lockName.
			std::string lockPath = std::string(handle->path) + ".lock";
			unlink(lockPath.c_str());
			close(handle->lockFd);
			handle->lockFd = -1;
		}
		handle->path[0] = '\0';

		delete handle;
	}

	extern "C" void* native_connectWithTimeout(const char* name, int timeoutMs)
	{
		std::string pipeName = makePipeName(name);
		if (pipeName.size() >= sizeof(((sockaddr_un*)nullptr)->sun_path))
		{
			return nullptr;
		}

		NativeLocalConnectionHandle* handle = createHandle();
		if (handle == nullptr)
		{
			return nullptr;
		}

		sockaddr_un address;
		std::memset(&address, 0, sizeof(address));
		address.sun_family = AF_UNIX;
		std::memcpy(address.sun_path, pipeName.data(), pipeName.size());
		address.sun_path[pipeName.size()] = '\0';

		bool forever = timeoutMs <= 0;
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(forever ? 0 : timeoutMs);
		// See the Windows version: it may wait, so it waits outside the
		// collector's reach, having copied the name.
		hx::AutoGCFreeZone waiting;
		while (true)
		{
			int fd = socket(AF_UNIX, SOCK_STREAM, 0);
			if (fd < 0)
			{
				delete handle;
				return nullptr;
			}

			if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0)
			{
				configureConnectedSocket(fd);
				handle->clientFd = fd;
				return handle;
			}

			int error = errno;
			close(fd);
			if ((error != ENOENT && error != ECONNREFUSED) || !anotherTry(forever, deadline))
			{
				delete handle;
				return nullptr;
			}

			std::this_thread::sleep_for(std::chrono::milliseconds(CONNECT_WAIT_SLICE_MS));
		}
	}

	extern "C" void* native_connect(const char* name)
	{
		return native_connectWithTimeout(name, CONNECT_TIMEOUT_MS);
	}

	extern "C" int native_getBytesAvailable(void* pipe)
	{
		auto* handle = static_cast<NativeLocalConnectionHandle*>(pipe);
		if (isInvalid(handle))
		{
			return -1;
		}

		int fd = getActiveFd(handle);
		if (fd < 0)
		{
			return -1;
		}

		int bytesAvailable = 0;
		if (ioctl(fd, FIONREAD, &bytesAvailable) == 0)
		{
			return bytesAvailable;
		}

		if (errno == EBADF || errno == ENOTCONN || errno == ECONNRESET)
		{
			return -1;
		}
		return 0;
	}
#endif
}
