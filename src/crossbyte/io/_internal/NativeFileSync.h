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
