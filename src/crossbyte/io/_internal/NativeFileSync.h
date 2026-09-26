#pragma once

// Moves `from` over `to` in one step, replacing whatever `to` held. Returns an
// empty string, or why it could not.
::String crossbyte_file_replace(::String from, ::String to);

// Flushes a file's contents to stable storage. Returns an empty string, or why
// it could not.
::String crossbyte_file_sync(::String path);

// Flushes a directory's entries, so a rename inside it survives a power cut.
// Best effort, and nothing to do on Windows.
void crossbyte_file_sync_directory(::String path);
