#pragma once

// A child process started in a directory of the caller's choosing, with an
// environment of the caller's choosing: what hxcpp's process_run cannot do,
// for NativeProcess when its startup info sets either. Otherwise the same as
// hxcpp's: three pipes, on Windows the arguments quoted as hxcpp quotes them
// and only the three pipe ends inherited, on POSIX close-on-exec descriptors
// and SIGPIPE ignored here but not in the child.
//
// C++ linkage: these take and return hxcpp types. The handle is a GC object
// whose finalizer closes what close() has not.

// Starts `executable` with `arguments`. `directory` null starts it in this
// process's working directory; `environment` null gives it this process's
// environment, and otherwise is every variable it gets, each "NAME=value".
// A bare name is looked for on this process's PATH. Throws a String saying
// why when it cannot start: on POSIX that includes a directory that cannot
// be entered and an executable that cannot be run, which the child reports
// back before it is replaced.
::Dynamic crossbyte_spawn_start(::String executable, Array< ::String > arguments, ::String directory, Array< ::String > environment);

// Reads up to `length` bytes of the child's output (`fromError` for its
// standard error) into `buffer` at `offset`, waiting for some. Returns how
// many, or 0 once the stream has ended.
int crossbyte_spawn_read(::Dynamic handle, bool fromError, Array< unsigned char > buffer, int offset, int length);

// Writes up to `length` bytes to the child's standard input. Returns how
// many were written, or -1 when it cannot be written (the child has closed
// it or gone).
int crossbyte_spawn_write(::Dynamic handle, Array< unsigned char > buffer, int offset, int length);

void crossbyte_spawn_close_input(::Dynamic handle);

// Ends the child: TerminateProcess on Windows, SIGTERM elsewhere. Nothing
// once it has been waited for or closed, when its id may name another.
void crossbyte_spawn_kill(::Dynamic handle);

// Waits for the child to end and returns its exit code: on POSIX 128 plus
// the signal for one that a signal ended, as hxcpp reports it.
int crossbyte_spawn_wait(::Dynamic handle);

int crossbyte_spawn_pid(::Dynamic handle);

// Closes the pipes and the process handle. After it, kill does nothing.
void crossbyte_spawn_close(::Dynamic handle);
