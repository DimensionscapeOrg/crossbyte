#include <hxcpp.h>

#include "NativeLocalConnection.h"

#include <chrono>
#include <cstring>
#if defined(_WIN32)
#include <Windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#endif

#include <string>

namespace
{
	constexpr int PIPE_BUFFER_SIZE = 4096;
	constexpr int CONNECT_TIMEOUT_MS = 5000;
	constexpr int CONNECT_WAIT_SLICE_MS = 50;
	constexpr int PIPE_LISTEN_BACKLOG = 16;

	const char* PIPE_PREFIX = "/tmp/crossbyte_local_connection_";
	const size_t PIPE_PREFIX_LENGTH = std::strlen(PIPE_PREFIX);

#if defined(_WIN32)
	bool isInvalid(HANDLE pipe)
	{
		return pipe == nullptr || pipe == INVALID_HANDLE_VALUE;
	}

	std::string makePipeName(const char* name)
	{
		return std::string("\\\\.\\pipe\\") + (name == nullptr ? "" : name);
	}

	extern "C" void* native_createInboundPipe(const char* name)
	{
		std::string pipeName = makePipeName(name);

		HANDLE pipe = CreateNamedPipeA(
			pipeName.c_str(),
			PIPE_ACCESS_DUPLEX,
			PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT,
			PIPE_UNLIMITED_INSTANCES,
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

		DWORD error = GetLastError();
		return error == ERROR_PIPE_CONNECTED || error == ERROR_NO_DATA;
	}

	extern "C" int native_read(void* pipe, unsigned char* buffer, int bufferSize)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return ERROR_INVALID_PARAMETER;
		}

		DWORD bytesRead = 0;
		if (!ReadFile(handle, buffer, static_cast<DWORD>(bufferSize), &bytesRead, nullptr))
		{
			DWORD error = GetLastError();
			if (error == ERROR_MORE_DATA)
			{
				return 0;
			}
			return static_cast<int>(error);
		}

		return 0;
	}

	extern "C" bool native_write(void* pipe, const unsigned char* buffer, int bufferSize)
	{
		HANDLE handle = static_cast<HANDLE>(pipe);
		if (isInvalid(handle) || buffer == nullptr || bufferSize <= 0)
		{
			return false;
		}

		DWORD bytesWritten = 0;
		if (!WriteFile(handle, buffer, static_cast<DWORD>(bufferSize), &bytesWritten, nullptr))
		{
			return false;
		}

		return bytesWritten == static_cast<DWORD>(bufferSize);
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

	extern "C" void* native_connect(const char* name)
	{
		std::string pipeName = makePipeName(name);
		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_TIMEOUT_MS);

		while (std::chrono::steady_clock::now() < deadline)
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
				DWORD mode = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
				SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
				return pipe;
			}

			DWORD error = GetLastError();
			if (error == ERROR_PIPE_BUSY)
			{
				WaitNamedPipeA(pipeName.c_str(), CONNECT_WAIT_SLICE_MS);
			}
			else if (error == ERROR_FILE_NOT_FOUND)
			{
				Sleep(CONNECT_WAIT_SLICE_MS);
			}
			else
			{
				return nullptr;
			}
		}

		return nullptr;
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
		if (error == ERROR_BROKEN_PIPE || error == ERROR_INVALID_HANDLE || error == ERROR_NO_DATA || error == ERROR_PIPE_NOT_CONNECTED)
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
		return error != ERROR_BROKEN_PIPE && error != ERROR_INVALID_HANDLE && error != ERROR_NO_DATA && error != ERROR_PIPE_NOT_CONNECTED;
	}
#else
	struct NativeLocalConnectionHandle
	{
		int listenFd;
		int clientFd;
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

	std::string sanitizePipeName(const char* name)
	{
		std::string source = (name == nullptr || name[0] == '\0') ? "default" : name;
		std::string sanitized;

		for (char c : source)
		{
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
			{
				sanitized.push_back(c);
			}
			else
			{
				sanitized.push_back('_');
			}
		}

		if (sanitized.empty())
		{
			sanitized = "default";
		}

		if (sanitized.size() + PIPE_PREFIX_LENGTH > 80)
		{
			sanitized = sanitized.substr(0, 80 - PIPE_PREFIX_LENGTH);
		}

		return std::string(PIPE_PREFIX) + sanitized;
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

	extern "C" void* native_createInboundPipe(const char* name)
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

		int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (listenFd < 0)
		{
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
			delete handle;
			return nullptr;
		}

		configureListeningSocket(listenFd);
		handle->listenFd = listenFd;
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

		int bytesWritten = 0;
		while (bytesWritten < bufferSize)
		{
			ssize_t sendResult = send(fd, reinterpret_cast<const char*>(buffer) + bytesWritten, bufferSize - bytesWritten, 0);
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
			handle->path[0] = '\0';
		}

		delete handle;
	}

	extern "C" void* native_connect(const char* name)
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

		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_TIMEOUT_MS);
		while (std::chrono::steady_clock::now() < deadline)
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
			if (error != ENOENT && error != ECONNREFUSED)
			{
				delete handle;
				return nullptr;
			}

			std::this_thread::sleep_for(std::chrono::milliseconds(CONNECT_WAIT_SLICE_MS));
		}

		delete handle;
		return nullptr;
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
