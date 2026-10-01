#pragma once

// Moves `from` over `to` in one step, replacing whatever `to` held. Returns an
// empty string, or why it could not.
::String crossbyte_file_replace(::String from, ::String to);

// Flushes a file's contents to stable storage. Returns an empty string, or why
// it could not.
::String crossbyte_file_sync(::String path);

// A file's size in bytes, whole past 2 GB, where the standard library's stat
// has an Int. -1 if the file cannot be examined.
double crossbyte_file_size(::String path);

// Flushes a directory's entries, so a rename inside it survives a power cut.
// Best effort, and nothing to do on Windows.
void crossbyte_file_sync_directory(::String path);

// Creates a file, or a directory, only if nothing is at `path`. Returns 0 when
// it was created, 1 when something was already there, -1 on any other failure.
int crossbyte_file_create_exclusive(::String path, bool directory);

// The file at `path` as "<volume>:<index>", the same for every name the file
// has, or an empty string if it cannot be examined.
::String crossbyte_file_identity(::String path);

// Cuts or extends the file at `path` to `length` bytes. Returns an empty
// string, or why it could not.
::String crossbyte_file_truncate(::String path, double length);

// When the file at `path` was created, in milliseconds since 1970; -1 if the
// system keeps no creation time for it, -2 if it cannot be examined.
double crossbyte_file_created(::String path);

// The file system's own path for `path`, links followed and names in their
// case on disk, or an empty string if there is no such file.
::String crossbyte_file_real_path(::String path);

// 1 if Windows marks the file at `path` hidden, 0 if not, -1 if it cannot be
// examined, or on POSIX, which keeps no such attribute.
int crossbyte_file_hidden(::String path);

// The bytes this process could still write on the volume the file or
// directory at `path` is on, or -1 if it cannot be examined.
double crossbyte_file_space_available(::String path);

// Windows' physical memory, in bytes: all of it, or what is available to
// start programs without swapping. -1 where it cannot be asked: POSIX,
// where System reads /proc/meminfo or asks sysctl.
double crossbyte_system_memory(bool available);
