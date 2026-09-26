#include <hxcpp.h>

#include "NativeFileSync.h"

#include <string>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

// The file operations Haxe's standard library has no call for: replacing a
// file atomically, and flushing one to stable storage. Each blocks on the
// disk, so each runs in a GC-free zone, with its paths copied out of the Haxe
// heap first.
namespace {
#if defined(_WIN32)
	std::wstring toWide(const ::String& value) {
		hx::strbuf buffer;
		const wchar_t* wide = value.wchar_str(&buffer);
		return wide == nullptr ? std::wstring() : std::wstring(wide);
	}

	::String describe(const char* what, DWORD code) {
		char message[512];
		DWORD length = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, message,
			static_cast<DWORD>(sizeof(message)), nullptr);

		while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r' || message[length - 1] == ' ')) {
			length--;
		}

		std::string out = std::string(what) + " failed (" + std::to_string(static_cast<unsigned long>(code)) + ")";

		if (length > 0) {
			out += ": " + std::string(message, length);
		}

		return ::String::create(out.c_str(), static_cast<int>(out.size()));
	}
#else
	std::string toNarrow(const ::String& value) {
		int length = 0;
		const char* utf8 = value.utf8_str(nullptr, true, &length);
		return utf8 == nullptr ? std::string() : std::string(utf8, static_cast<size_t>(length));
	}

	::String describe(const char* what, int code) {
		std::string out = std::string(what) + " failed: " + strerror(code);
		return ::String::create(out.c_str(), static_cast<int>(out.size()));
	}
#endif
}

::String crossbyte_file_replace(::String from, ::String to) {
#if defined(_WIN32)
	std::wstring source = toWide(from);
	std::wstring target = toWide(to);
	DWORD error = 0;

	{
		hx::AutoGCFreeZone zone;

		// A reader that has the old file open, as the C runtime opens files --
		// without FILE_SHARE_DELETE -- makes the replace fail for as long as it
		// holds it. A read is short, so a moment's retry rides it out rather
		// than failing a write because someone was looking.
		for (int attempt = 0; attempt < 200; ++attempt) {
			if (MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
				error = 0;
				break;
			}

			error = GetLastError();

			if (error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION) {
				break;
			}

			Sleep(1);
		}
	}

	return error == 0 ? ::String("") : describe("MoveFileExW", error);
#else
	std::string source = toNarrow(from);
	std::string target = toNarrow(to);
	int error = 0;

	{
		hx::AutoGCFreeZone zone;

		if (rename(source.c_str(), target.c_str()) != 0) {
			error = errno;
		}
	}

	return error == 0 ? ::String("") : describe("rename", error);
#endif
}

::String crossbyte_file_sync(::String path) {
#if defined(_WIN32)
	std::wstring file = toWide(path);
	DWORD error = 0;

	{
		hx::AutoGCFreeZone zone;
		HANDLE handle = CreateFileW(file.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
			OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);

		if (handle == INVALID_HANDLE_VALUE) {
			error = GetLastError();
		} else {
			if (!FlushFileBuffers(handle)) {
				error = GetLastError();
			}

			CloseHandle(handle);
		}
	}

	return error == 0 ? ::String("") : describe("FlushFileBuffers", error);
#else
	std::string file = toNarrow(path);
	int error = 0;

	{
		hx::AutoGCFreeZone zone;
		int fd = open(file.c_str(), O_RDONLY);

		if (fd < 0) {
			error = errno;
		} else {
			if (fsync(fd) != 0) {
				error = errno;
			}

			close(fd);
		}
	}

	return error == 0 ? ::String("") : describe("fsync", error);
#endif
}

void crossbyte_file_sync_directory(::String path) {
#if !defined(_WIN32)
	// So the rename itself survives a power cut: a new name is an entry in the
	// directory, and on POSIX that is flushed separately from the file. Best
	// effort -- some filesystems refuse to sync a directory, and a failure here
	// leaves the value as durable as it was before this call existed.
	std::string directory = toNarrow(path);

	{
		hx::AutoGCFreeZone zone;
		int fd = open(directory.c_str(), O_RDONLY);

		if (fd >= 0) {
			fsync(fd);
			close(fd);
		}
	}
#else
	// NTFS journals the rename with the MOVEFILE_WRITE_THROUGH it was made
	// with; there is no directory handle to flush.
	(void)path;
#endif
}
