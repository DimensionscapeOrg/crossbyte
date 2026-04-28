#include <hxcpp.h>

#include "NativeLocalConnection.h"

#include <Windows.h>

#include <chrono>
#include <string>

namespace
{
	constexpr DWORD PIPE_BUFFER_SIZE = 4096;
	constexpr DWORD CONNECT_TIMEOUT_MS = 5000;
	constexpr DWORD CONNECT_WAIT_SLICE_MS = 50;

	std::string makePipeName(const char* name)
	{
		return std::string("\\\\.\\pipe\\") + (name == nullptr ? "" : name);
	}

	bool isInvalid(HANDLE pipe)
	{
		return pipe == nullptr || pipe == INVALID_HANDLE_VALUE;
	}
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
	return error == ERROR_PIPE_CONNECTED;
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
	return error != ERROR_BROKEN_PIPE && error != ERROR_INVALID_HANDLE && error != ERROR_PIPE_NOT_CONNECTED;
}
