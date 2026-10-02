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
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>
#endif
#if defined(__APPLE__)
#include <stdint.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#endif

// The file operations Haxe's standard library has no call for: replacing a
// file atomically, flushing one to stable storage, measuring one past 2 GB,
// and creating one only where nothing is. Each blocks on the disk, so each
// runs in a GC-free zone, with its paths copied out of the Haxe heap first.
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

double crossbyte_file_size(::String path) {
#if defined(_WIN32)
	std::wstring file = toWide(path);
	WIN32_FILE_ATTRIBUTE_DATA data;
	BOOL ok = FALSE;

	{
		hx::AutoGCFreeZone zone;
		ok = GetFileAttributesExW(file.c_str(), GetFileExInfoStandard, &data);
	}

	if (!ok) {
		return -1;
	}

	return static_cast<double>((static_cast<unsigned long long>(data.nFileSizeHigh) << 32) | data.nFileSizeLow);
#else
	std::string file = toNarrow(path);
	struct stat info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = stat(file.c_str(), &info);
	}

	return status != 0 ? -1 : static_cast<double>(info.st_size);
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

::String crossbyte_file_identity(::String path) {
	// What a file is, rather than what it is called: its volume and its
	// index on that volume. Two names with the same identity are one file --
	// a case-only difference, a hard link, a junction, a short name -- which
	// comparing the names cannot see. Copying a file onto another name for
	// itself truncates the destination before reading it, which is the
	// source, and the data is gone.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	BY_HANDLE_FILE_INFORMATION info;
	BOOL ok = FALSE;

	{
		hx::AutoGCFreeZone zone;
		// No access asked for, and every share mode granted, so a file open
		// elsewhere is still examined; BACKUP_SEMANTICS opens a directory.
		HANDLE handle = CreateFileW(file.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
			FILE_FLAG_BACKUP_SEMANTICS, nullptr);

		if (handle != INVALID_HANDLE_VALUE) {
			ok = GetFileInformationByHandle(handle, &info);
			CloseHandle(handle);
		}
	}

	if (!ok) {
		return ::String("");
	}

	std::string key = std::to_string(static_cast<unsigned long>(info.dwVolumeSerialNumber)) + ":"
		+ std::to_string((static_cast<unsigned long long>(info.nFileIndexHigh) << 32) | info.nFileIndexLow);
	return ::String::create(key.c_str(), static_cast<int>(key.size()));
#else
	std::string file = toNarrow(path);
	struct stat info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = stat(file.c_str(), &info);
	}

	if (status != 0) {
		return ::String("");
	}

	std::string key = std::to_string(static_cast<unsigned long long>(info.st_dev)) + ":"
		+ std::to_string(static_cast<unsigned long long>(info.st_ino));
	return ::String::create(key.c_str(), static_cast<int>(key.size()));
#endif
}

double crossbyte_file_created(::String path) {
	// When the file was made, which is not what POSIX's ctime is: that is
	// when its status last changed, a chmod or a rename moving it on. Linux
	// keeps a birth time behind statx, where the C library has it, and macOS
	// in st_birthtime; Windows in the creation time it has always had.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	WIN32_FILE_ATTRIBUTE_DATA data;
	BOOL ok = FALSE;

	{
		hx::AutoGCFreeZone zone;
		ok = GetFileAttributesExW(file.c_str(), GetFileExInfoStandard, &data);
	}

	if (!ok) {
		return -2;
	}

	unsigned long long ticks = (static_cast<unsigned long long>(data.ftCreationTime.dwHighDateTime) << 32) | data.ftCreationTime.dwLowDateTime;
	// 100ns ticks since 1601 to milliseconds since 1970.
	return (static_cast<double>(ticks) - 116444736000000000.0) / 10000.0;
#elif defined(__APPLE__)
	std::string file = toNarrow(path);
	struct stat info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = stat(file.c_str(), &info);
	}

	if (status != 0) {
		return -2;
	}

	return static_cast<double>(info.st_birthtimespec.tv_sec) * 1000.0 + static_cast<double>(info.st_birthtimespec.tv_nsec) / 1000000.0;
#elif defined(__linux__) && defined(STATX_BTIME)
	std::string file = toNarrow(path);
	struct statx info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = statx(AT_FDCWD, file.c_str(), 0, STATX_BTIME, &info);
	}

	if (status != 0) {
		return errno == ENOENT || errno == ENOTDIR ? -2 : -1;
	}

	if ((info.stx_mask & STATX_BTIME) == 0) {
		// A file system that keeps none.
		return -1;
	}

	return static_cast<double>(info.stx_btime.tv_sec) * 1000.0 + static_cast<double>(info.stx_btime.tv_nsec) / 1000000.0;
#else
	// A C library without statx.
	std::string file = toNarrow(path);
	struct stat info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = stat(file.c_str(), &info);
	}

	return status != 0 ? -2 : -1;
#endif
}

::String crossbyte_file_real_path(::String path) {
	// The path the file system itself gives the file: every link followed and
	// every name in the case it has on disk.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	std::wstring real;

	{
		hx::AutoGCFreeZone zone;
		HANDLE handle = CreateFileW(file.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
			FILE_FLAG_BACKUP_SEMANTICS, nullptr);

		if (handle != INVALID_HANDLE_VALUE) {
			DWORD needed = GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);

			if (needed > 0) {
				std::wstring buffer(needed, L'\0');
				DWORD written = GetFinalPathNameByHandleW(handle, &buffer[0], needed, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);

				if (written > 0 && written < needed) {
					real.assign(buffer.c_str(), written);
				}
			}

			CloseHandle(handle);
		}
	}

	if (real.empty()) {
		return ::String("");
	}

	// \\?\C:\x is C:\x, and \\?\UNC\server\share is \\server\share.
	if (real.compare(0, 8, L"\\\\?\\UNC\\") == 0) {
		real = L"\\\\" + real.substr(8);
	} else if (real.compare(0, 4, L"\\\\?\\") == 0) {
		real = real.substr(4);
	}

	return ::String::create(real.c_str(), static_cast<int>(real.size()));
#else
	std::string file = toNarrow(path);
	std::string real;

	{
		hx::AutoGCFreeZone zone;
		char* resolved = realpath(file.c_str(), nullptr);

		if (resolved != nullptr) {
			real = resolved;
			free(resolved);
		}
	}

	return real.empty() ? ::String("") : ::String::create(real.c_str(), static_cast<int>(real.size()));
#endif
}

int crossbyte_file_hidden(::String path) {
	// Windows' hidden attribute, asked of the file system. File asked
	// `attrib` through cmd.exe: a process for each question, and cmd
	// expanded any %NAME% in the path, so a file with one in its name was
	// asked about under another.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	DWORD attributes = INVALID_FILE_ATTRIBUTES;

	{
		hx::AutoGCFreeZone zone;
		attributes = GetFileAttributesW(file.c_str());
	}

	if (attributes == INVALID_FILE_ATTRIBUTES) {
		return -1;
	}

	return (attributes & FILE_ATTRIBUTE_HIDDEN) != 0 ? 1 : 0;
#else
	// POSIX keeps no such attribute; File asks the name there.
	return -1;
#endif
}

double crossbyte_file_space_available(::String path) {
	// The bytes this process could still write on the volume `path` is on:
	// a file's, a directory's. File started fsutil or df for each question,
	// and fsutil refused a file's path, which read as a full disk.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	ULARGE_INTEGER available;
	BOOL ok = FALSE;

	{
		hx::AutoGCFreeZone zone;
		DWORD attributes = GetFileAttributesW(file.c_str());

		if (attributes != INVALID_FILE_ATTRIBUTES) {
			// It takes a directory: a file is asked about through the one
			// it is in.
			if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
				size_t cut = file.find_last_of(L"\\/");
				file = cut == std::wstring::npos ? std::wstring(L".") : file.substr(0, cut + 1);
			} else if (!file.empty() && file.back() != L'\\' && file.back() != L'/') {
				// A share's root is named with its separator.
				file += L'\\';
			}

			ok = GetDiskFreeSpaceExW(file.c_str(), &available, nullptr, nullptr);
		}
	}

	return ok ? static_cast<double>(available.QuadPart) : -1.0;
#else
	std::string file = toNarrow(path);
	struct statvfs info;
	int status = 0;

	{
		hx::AutoGCFreeZone zone;
		status = statvfs(file.c_str(), &info);
	}

	if (status != 0) {
		return -1.0;
	}

	return static_cast<double>(info.f_bavail) * static_cast<double>(info.f_frsize);
#endif
}

double crossbyte_system_memory(bool available) {
	// Not a file operation: System's, kept in this bridge so that it has
	// one. It started wmic for each figure, which takes half a second.
#if defined(_WIN32)
	MEMORYSTATUSEX status;
	status.dwLength = sizeof(status);

	if (!GlobalMemoryStatusEx(&status)) {
		return -1.0;
	}

	return static_cast<double>(available ? status.ullAvailPhys : status.ullTotalPhys);
#elif defined(__APPLE__)
	// Asked of the kernel: System ran sysctl and vm_stat for these, two
	// processes and about 0.1 s on the CI runner.
	if (!available) {
		uint64_t total = 0;
		size_t size = sizeof(total);
		if (sysctlbyname("hw.memsize", &total, &size, nullptr, 0) != 0) {
			return -1.0;
		}
		return static_cast<double>(total);
	}

	// vm_stat's free, inactive and speculative pages: what a program can be
	// given without anything being paged out. The host port is asked for
	// once; each mach_host_self() is a send right of its own.
	static mach_port_t host = mach_host_self();
	vm_statistics64_data_t stats;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&stats), &count) != KERN_SUCCESS) {
		return -1.0;
	}
	vm_size_t page = 0;
	if (host_page_size(host, &page) != KERN_SUCCESS) {
		return -1.0;
	}
	uint64_t pages = static_cast<uint64_t>(stats.free_count) + stats.inactive_count + stats.speculative_count;
	return static_cast<double>(pages * static_cast<uint64_t>(page));
#else
	// System reads /proc/meminfo there.
	return -1.0;
#endif
}

::String crossbyte_file_truncate(::String path, double length) {
	// The standard library has no truncate. FileStream read the whole file
	// into memory and wrote back the part it kept, which is a file's size of
	// memory and a window in which a crash leaves it empty.
#if defined(_WIN32)
	std::wstring file = toWide(path);
	DWORD error = 0;

	{
		hx::AutoGCFreeZone zone;
		// Shared both ways: the stream truncating has the file open itself.
		HANDLE handle = CreateFileW(file.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
			OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);

		if (handle == INVALID_HANDLE_VALUE) {
			error = GetLastError();
		} else {
			LARGE_INTEGER at;
			at.QuadPart = static_cast<LONGLONG>(length);

			if (!SetFilePointerEx(handle, at, nullptr, FILE_BEGIN) || !SetEndOfFile(handle)) {
				error = GetLastError();
			}

			CloseHandle(handle);
		}
	}

	return error == 0 ? ::String("") : describe("SetEndOfFile", error);
#else
	std::string file = toNarrow(path);
	int error = 0;

	{
		hx::AutoGCFreeZone zone;

		if (truncate(file.c_str(), static_cast<off_t>(length)) != 0) {
			error = errno;
		}
	}

	return error == 0 ? ::String("") : describe("truncate", error);
#endif
}

int crossbyte_file_create_exclusive(::String path, bool directory) {
#if defined(_WIN32)
	std::wstring target = toWide(path);
	DWORD error = 0;

	{
		hx::AutoGCFreeZone zone;

		if (directory) {
			if (!CreateDirectoryW(target.c_str(), nullptr)) {
				error = GetLastError();
			}
		} else {
			// CREATE_NEW fails if anything is at the path, a link included, so
			// nothing planted there ahead of time is ever opened.
			HANDLE handle = CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);

			if (handle == INVALID_HANDLE_VALUE) {
				error = GetLastError();
			} else {
				CloseHandle(handle);
			}
		}
	}

	if (error == 0) {
		return 0;
	}

	return (error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS) ? 1 : -1;
#else
	std::string target = toNarrow(path);
	int error = 0;

	{
		hx::AutoGCFreeZone zone;

		if (directory) {
			if (mkdir(target.c_str(), 0700) != 0) {
				error = errno;
			}
		} else {
			// O_EXCL with O_CREAT fails on anything at the path, a symbolic
			// link included, and O_NOFOLLOW says so twice. Readable by the
			// owner only, as mkstemp makes them.
			int fd = open(target.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);

			if (fd < 0) {
				error = errno;
			} else {
				close(fd);
			}
		}
	}

	if (error == 0) {
		return 0;
	}

	return error == EEXIST ? 1 : -1;
#endif
}
