#include <hxcpp.h>
#include "NativeSpawn.h"

#include <string>
#include <vector>
#include <mutex>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(HX_WINDOWS) || defined(_WIN32)
#define CROSSBYTE_SPAWN_WINDOWS 1
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#else
extern char **environ;
#endif
#endif

namespace {

#ifdef CROSSBYTE_SPAWN_WINDOWS
// CreateProcess hands the child every inheritable handle this process holds
// unless it is given the list of those to pass, as hxcpp's process_run
// gives it. The list is a Vista API, looked up at run time as hxcpp does.
#ifndef EXTENDED_STARTUPINFO_PRESENT
#define EXTENDED_STARTUPINFO_PRESENT 0x00080000
#endif
#ifndef PROC_THREAD_ATTRIBUTE_HANDLE_LIST
#define PROC_THREAD_ATTRIBUTE_HANDLE_LIST 0x00020002
#endif

struct StartupInfoWithList {
	STARTUPINFOW info;
	void *attributes;
};

struct HandleListApi {
	typedef BOOL(WINAPI *InitFunc)(void *, DWORD, DWORD, SIZE_T *);
	typedef BOOL(WINAPI *UpdateFunc)(void *, DWORD, DWORD_PTR, void *, SIZE_T, void *, SIZE_T *);
	typedef void(WINAPI *DeleteFunc)(void *);

	InitFunc init;
	UpdateFunc update;
	DeleteFunc remove;

	HandleListApi() : init(0), update(0), remove(0) {
		HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
		if (kernel) {
			init = (InitFunc)GetProcAddress(kernel, "InitializeProcThreadAttributeList");
			update = (UpdateFunc)GetProcAddress(kernel, "UpdateProcThreadAttribute");
			remove = (DeleteFunc)GetProcAddress(kernel, "DeleteProcThreadAttributeList");
		}
	}

	bool available() const {
		return init && update && remove;
	}

	static const HandleListApi &get() {
		static HandleListApi api;
		return api;
	}
};
#endif

// The native side of a child: its pipes and its process, and whether it has
// been waited for or closed. The lock covers those two states and the
// handles kill and close touch; reads and writes use their own pipe, which
// only close closes, once the readers are done.
struct ChildState {
	std::mutex lock;
	bool open;
	bool waited;
#ifdef CROSSBYTE_SPAWN_WINDOWS
	HANDLE outRead;
	HANDLE errRead;
	HANDLE inWrite;
	HANDLE process;
	DWORD pid;
#else
	int outRead;
	int errRead;
	int inWrite;
	pid_t pid;
#endif

	ChildState() : open(true), waited(false) {
#ifdef CROSSBYTE_SPAWN_WINDOWS
		outRead = errRead = inWrite = process = 0;
		pid = 0;
#else
		outRead = errRead = inWrite = -1;
		pid = -1;
#endif
	}

	// Under the lock.
	void closeAll() {
		if (!open) {
			return;
		}
		open = false;
#ifdef CROSSBYTE_SPAWN_WINDOWS
		if (outRead) CloseHandle(outRead);
		if (errRead) CloseHandle(errRead);
		if (inWrite) CloseHandle(inWrite);
		if (process) CloseHandle(process);
		outRead = errRead = inWrite = process = 0;
#else
		if (outRead >= 0) close(outRead);
		if (errRead >= 0) close(errRead);
		if (inWrite >= 0) close(inWrite);
		outRead = errRead = inWrite = -1;
		// Reaped if it has already ended, so it does not stay a zombie; one
		// still running is left to be adopted when this process ends.
		if (!waited && pid > 0) {
			waitpid(pid, 0, WNOHANG);
		}
#endif
	}
};

// The GC's handle on a ChildState, after hxcpp's own vprocess: the finalizer
// closes what close() did not, and frees the state.
struct ChildHandle : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdAbstract };

	ChildState *state;

	void create(ChildState *childState) {
		state = childState;
		_hx_set_finalizer(this, finalize);
	}

	static void finalize(Dynamic obj) {
		ChildHandle *handle = (ChildHandle *)(obj.mPtr);
		if (handle->state != nullptr) {
			{
				std::lock_guard<std::mutex> guard(handle->state->lock);
				handle->state->closeAll();
			}
			delete handle->state;
			handle->state = nullptr;
		}
	}

	String toString() HXCPP_OVERRIDE {
		return HX_CSTRING("NativeProcess child");
	}
};

ChildState *stateOf(Dynamic handle) {
	ChildHandle *child = handle.mPtr == 0 ? nullptr : dynamic_cast<ChildHandle *>(handle.mPtr);
	if (child == nullptr || child->state == nullptr) {
		hx::Throw(HX_CSTRING("Invalid process"));
	}
	return child->state;
}

std::string utf8Of(String value) {
	hx::strbuf buffer;
	const char *text = value.utf8_str(&buffer);
	return std::string(text == nullptr ? "" : text);
}

#ifdef CROSSBYTE_SPAWN_WINDOWS
std::wstring wideOf(String value) {
	const wchar_t *text = value.__WCStr();
	return std::wstring(text == nullptr ? L"" : text);
}

// An argument as the command line carries it. One with nothing to protect goes
// as it is, as libuv, Python and Rust write one: cmd.exe reads its own command
// line, and a quoted "/c" ends its command with a stray quote. Otherwise in
// quotes, as hxcpp's process_run writes one: each quote escaped, and the
// backslashes before a quote or the closing quote doubled. A program reading
// its arguments the usual way (CommandLineToArgvW, the C runtime) gets the same
// arguments either way.
void appendQuoted(std::wstring &line, const std::wstring &argument) {
	if (!argument.empty() && argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
		line += argument;
		return;
	}
	line += L'"';
	size_t backslashes = 0;
	for (size_t i = 0; i < argument.size(); ++i) {
		wchar_t c = argument[i];
		if (c == L'\\') {
			backslashes++;
			continue;
		}
		if (c == L'"') {
			line.append(backslashes * 2 + 1, L'\\');
			line += L'"';
		} else {
			line.append(backslashes, L'\\');
			line += c;
		}
		backslashes = 0;
	}
	line.append(backslashes * 2, L'\\');
	line += L'"';
}

String windowsError(const char *what, DWORD code) {
	char text[512];
	DWORD length = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, 0, code, 0, text, sizeof(text), 0);
	while (length > 0 && (text[length - 1] == '\n' || text[length - 1] == '\r' || text[length - 1] == ' ' || text[length - 1] == '.')) {
		length--;
	}
	text[length] = 0;
	char message[700];
	snprintf(message, sizeof(message), "%s: %s (Windows error %lu)", what, length > 0 ? text : "unknown", (unsigned long)code);
	return String(message);
}
#else
void setCloseOnExec(int fd) {
	int flags = fcntl(fd, F_GETFD);
	if (flags >= 0) {
		fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
	}
}

bool makePipe(int ends[2]) {
#if defined(__linux__)
	// Close-on-exec as it is made, so another thread's fork in between cannot
	// hand it to an unrelated child.
	if (pipe2(ends, O_CLOEXEC) == 0) {
		return true;
	}
	if (errno != ENOSYS) {
		return false;
	}
#endif
	if (pipe(ends) != 0) {
		return false;
	}
	setCloseOnExec(ends[0]);
	setCloseOnExec(ends[1]);
	return true;
}

void closePipe(int ends[2]) {
	if (ends[0] >= 0) close(ends[0]);
	if (ends[1] >= 0) close(ends[1]);
	ends[0] = ends[1] = -1;
}

char **currentEnvironment() {
#if defined(__APPLE__)
	return *_NSGetEnviron();
#else
	return environ;
#endif
}

// What the child sends back before it is replaced, when it cannot be: which
// step failed, and errno.
struct ChildFailure {
	int step;
	int error;
};

enum { STEP_DIRECTORY = 1, STEP_EXEC = 2 };
#endif

} // namespace

::Dynamic crossbyte_spawn_start(::String executable, Array< ::String > arguments, ::String directory, Array< ::String > environment) {
	if (executable == null() || executable.length == 0) {
		hx::Throw(HX_CSTRING("No executable to start"));
	}
	bool hasDirectory = !(directory == null());
	bool hasEnvironment = environment.mPtr != nullptr;
	int argumentCount = arguments.mPtr == nullptr ? 0 : arguments->length;

#ifdef CROSSBYTE_SPAWN_WINDOWS
	std::wstring program = wideOf(executable);
	if (program.find(L'"') != std::wstring::npos) {
		// As hxcpp: a quote in the program's name would end it early.
		hx::Throw(HX_CSTRING("Invalid command name"));
	}
	std::wstring line = L"\"" + program + L"\"";
	for (int i = 0; i < argumentCount; ++i) {
		line += L' ';
		appendQuoted(line, wideOf(arguments[i]));
	}
	std::vector<wchar_t> commandLine(line.begin(), line.end());
	commandLine.push_back(0);

	std::wstring workingDirectory = hasDirectory ? wideOf(directory) : std::wstring();
	std::vector<wchar_t> block;
	if (hasEnvironment) {
		for (int i = 0; i < environment->length; ++i) {
			std::wstring entry = wideOf(environment[i]);
			block.insert(block.end(), entry.begin(), entry.end());
			block.push_back(0);
		}
		if (environment->length == 0) {
			block.push_back(0);
		}
		block.push_back(0);
	}

	ChildState *state = new ChildState();
	DWORD failure = 0;
	const char *failedStep = "Could not start the process";

	hx::EnterGCFreeZone();
	{
		SECURITY_ATTRIBUTES attributes;
		attributes.nLength = sizeof(attributes);
		attributes.bInheritHandle = TRUE;
		attributes.lpSecurityDescriptor = NULL;

		STARTUPINFOW startup;
		memset(&startup, 0, sizeof(startup));
		startup.cb = sizeof(startup);
		startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
		// As hxcpp passes it by default; a console program gets no window
		// either way, as CREATE_NO_WINDOW says.
		startup.wShowWindow = SW_SHOWNORMAL;

		HANDLE self = GetCurrentProcess();
		HANDLE outRead = 0, errRead = 0, inWrite = 0;
		bool piped = CreatePipe(&outRead, &startup.hStdOutput, &attributes, 0)
			&& CreatePipe(&errRead, &startup.hStdError, &attributes, 0)
			&& CreatePipe(&startup.hStdInput, &inWrite, &attributes, 0);
		if (!piped) {
			failure = GetLastError();
			failedStep = "Could not make the process's pipes";
		}

		// This process's ends, made not inheritable, so no later child holds
		// them open.
		bool duplicated = piped
			&& DuplicateHandle(self, outRead, self, &state->outRead, 0, FALSE, DUPLICATE_SAME_ACCESS)
			&& DuplicateHandle(self, errRead, self, &state->errRead, 0, FALSE, DUPLICATE_SAME_ACCESS)
			&& DuplicateHandle(self, inWrite, self, &state->inWrite, 0, FALSE, DUPLICATE_SAME_ACCESS);
		if (piped && !duplicated) {
			failure = GetLastError();
			failedStep = "Could not make the process's pipes";
		}
		if (outRead) CloseHandle(outRead);
		if (errRead) CloseHandle(errRead);
		if (inWrite) CloseHandle(inWrite);

		const HandleListApi &api = HandleListApi::get();
		HANDLE inherit[3] = { startup.hStdInput, startup.hStdOutput, startup.hStdError };
		void *list = 0;
		bool initialized = false;
		bool listed = false;
		if (duplicated && api.available()) {
			SIZE_T size = 0;
			api.init(0, 1, 0, &size);
			if (size) {
				list = malloc(size);
			}
			initialized = list && api.init(list, 1, 0, &size);
			listed = initialized && api.update(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit, sizeof(inherit), 0, 0);
		}
		StartupInfoWithList startupWithList;
		memset(&startupWithList, 0, sizeof(startupWithList));
		startupWithList.info = startup;
		startupWithList.info.cb = sizeof(startupWithList);
		startupWithList.attributes = list;

		PROCESS_INFORMATION info;
		memset(&info, 0, sizeof(info));
		bool started = false;
		if (duplicated) {
			DWORD flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | (listed ? EXTENDED_STARTUPINFO_PRESENT : 0);
			started = CreateProcessW(NULL, &commandLine[0], NULL, NULL, TRUE, flags, hasEnvironment ? (void *)&block[0] : NULL,
				hasDirectory ? workingDirectory.c_str() : NULL, listed ? &startupWithList.info : &startup, &info) != 0;
			if (!started) {
				failure = GetLastError();
				failedStep = "Could not start the process";
			}
		}

		if (initialized) api.remove(list);
		if (list) free(list);

		// The child's ends are its own now, or nobody's.
		if (startup.hStdOutput) CloseHandle(startup.hStdOutput);
		if (startup.hStdError) CloseHandle(startup.hStdError);
		if (startup.hStdInput) CloseHandle(startup.hStdInput);

		if (started) {
			CloseHandle(info.hThread);
			state->process = info.hProcess;
			state->pid = info.dwProcessId;
		}
	}
	hx::ExitGCFreeZone();

	if (failure != 0 || state->process == 0) {
		{
			std::lock_guard<std::mutex> guard(state->lock);
			state->closeAll();
		}
		delete state;
		hx::Throw(windowsError(failedStep, failure));
	}
#else
	// Writing to a child that has gone must be an error here, not a SIGPIPE
	// ending this process, as hxcpp's process_run sets it up.
	static bool sigpipeIgnored = false;
	if (!sigpipeIgnored) {
		sigpipeIgnored = true;
		signal(SIGPIPE, SIG_IGN);
	}

	std::vector<std::string> values;
	values.push_back(utf8Of(executable));
	for (int i = 0; i < argumentCount; ++i) {
		values.push_back(utf8Of(arguments[i]));
	}
	std::vector<std::string> variables;
	if (hasEnvironment) {
		for (int i = 0; i < environment->length; ++i) {
			variables.push_back(utf8Of(environment[i]));
		}
	}
	std::string workingDirectory = hasDirectory ? utf8Of(directory) : std::string();

	// Where execve looks: the name itself when it holds a slash, as execvp
	// does, and otherwise each directory on this process's PATH, the child's
	// environment being the one it runs with and not where it is found.
	std::vector<std::string> candidates;
	const std::string &name = values[0];
	if (name.find('/') != std::string::npos) {
		candidates.push_back(name);
	} else {
		const char *path = getenv("PATH");
		std::string search = path != nullptr ? path : "/usr/local/bin:/usr/bin:/bin";
		size_t start = 0;
		while (true) {
			size_t colon = search.find(':', start);
			std::string entry = search.substr(start, colon == std::string::npos ? std::string::npos : colon - start);
			candidates.push_back((entry.empty() ? std::string(".") : entry) + "/" + name);
			if (colon == std::string::npos) {
				break;
			}
			start = colon + 1;
		}
	}

	// Every pointer the child uses, made before the fork: after it, the
	// child of a threaded process may only make async-signal-safe calls.
	std::vector<char *> argv;
	for (size_t i = 0; i < values.size(); ++i) {
		argv.push_back((char *)values[i].c_str());
	}
	argv.push_back(nullptr);
	std::vector<char *> envp;
	if (hasEnvironment) {
		for (size_t i = 0; i < variables.size(); ++i) {
			envp.push_back((char *)variables[i].c_str());
		}
		envp.push_back(nullptr);
	}
	char **childEnvironment = hasEnvironment ? &envp[0] : currentEnvironment();
	std::vector<const char *> paths;
	for (size_t i = 0; i < candidates.size(); ++i) {
		paths.push_back(candidates[i].c_str());
	}
	const char *childDirectory = hasDirectory ? workingDirectory.c_str() : nullptr;

	ChildState *state = new ChildState();
	int input[2] = { -1, -1 }, output[2] = { -1, -1 }, error[2] = { -1, -1 }, report[2] = { -1, -1 };
	int failure = 0;
	ChildFailure childFailure = { 0, 0 };
	bool started = false;

	hx::EnterGCFreeZone();
	if (!makePipe(input) || !makePipe(output) || !makePipe(error) || !makePipe(report)) {
		failure = errno;
	} else {
		pid_t pid = fork();
		if (pid == -1) {
			failure = errno;
		} else if (pid == 0) {
			// The child. dup2 leaves the copies on 0, 1 and 2 open across exec.
			dup2(input[0], 0);
			dup2(output[1], 1);
			dup2(error[1], 2);
			// An ignored signal stays ignored across exec; a child gets the
			// default, as hxcpp and Python give it.
			signal(SIGPIPE, SIG_DFL);
			ChildFailure sent = { 0, 0 };
			if (childDirectory != nullptr && chdir(childDirectory) != 0) {
				sent.step = STEP_DIRECTORY;
				sent.error = errno;
			} else {
				int last = ENOENT;
				bool denied = false;
				for (size_t i = 0; i < paths.size(); ++i) {
					execve(paths[i], &argv[0], childEnvironment);
					last = errno;
					if (last == EACCES) {
						denied = true;
					} else if (last != ENOENT && last != ENOTDIR) {
						break;
					}
				}
				sent.step = STEP_EXEC;
				sent.error = (denied && (last == ENOENT || last == ENOTDIR)) ? EACCES : last;
			}
			ssize_t unused = write(report[1], &sent, sizeof(sent));
			(void)unused;
			_exit(127);
		} else {
			state->pid = pid;
			close(report[1]);
			report[1] = -1;
			// The report's write end closes as exec succeeds, so this reads
			// nothing, or the failure the child sent.
			ssize_t got;
			do {
				got = read(report[0], &childFailure, sizeof(childFailure));
			} while (got < 0 && errno == EINTR);
			if (got == (ssize_t)sizeof(childFailure)) {
				int status = 0;
				while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
				}
				state->waited = true;
			} else {
				started = true;
				childFailure.step = 0;
			}
		}
	}
	if (started) {
		close(input[0]);
		close(output[1]);
		close(error[1]);
		state->inWrite = input[1];
		state->outRead = output[0];
		state->errRead = error[0];
		input[1] = output[0] = error[0] = -1;
		input[0] = output[1] = error[1] = -1;
	}
	closePipe(input);
	closePipe(output);
	closePipe(error);
	closePipe(report);
	hx::ExitGCFreeZone();

	if (!started) {
		state->open = false;
		delete state;
		char message[600];
		if (childFailure.step == STEP_DIRECTORY) {
			snprintf(message, sizeof(message), "Could not enter the working directory %s: %s", workingDirectory.c_str(), strerror(childFailure.error));
		} else if (childFailure.step == STEP_EXEC) {
			snprintf(message, sizeof(message), "Could not run %s: %s", name.c_str(), strerror(childFailure.error));
		} else {
			snprintf(message, sizeof(message), "Could not start the process: %s", strerror(failure));
		}
		hx::Throw(String(message));
	}
#endif

	ChildHandle *handle = new ChildHandle();
	handle->create(state);
	return handle;
}

int crossbyte_spawn_read(::Dynamic handle, bool fromError, Array< unsigned char > buffer, int offset, int length) {
	ChildState *state = stateOf(handle);
	if (buffer.mPtr == nullptr || offset < 0 || length <= 0 || offset > buffer->length || length > buffer->length - offset) {
		return 0;
	}
	unsigned char *volatile destination = &buffer[0];

#ifdef CROSSBYTE_SPAWN_WINDOWS
	HANDLE pipe = fromError ? state->errRead : state->outRead;
	if (!pipe) {
		return 0;
	}
	DWORD read = 0;
	hx::EnterGCFreeZone();
	if (!ReadFile(pipe, destination + offset, (DWORD)length, &read, 0)) {
		read = 0;
	}
	hx::ExitGCFreeZone();
	return (int)read;
#else
	int fd = fromError ? state->errRead : state->outRead;
	if (fd < 0) {
		return 0;
	}
	ssize_t read;
	hx::EnterGCFreeZone();
	do {
		read = ::read(fd, destination + offset, (size_t)length);
	} while (read < 0 && errno == EINTR);
	hx::ExitGCFreeZone();
	return read < 0 ? 0 : (int)read;
#endif
}

int crossbyte_spawn_write(::Dynamic handle, Array< unsigned char > buffer, int offset, int length) {
	ChildState *state = stateOf(handle);
	if (buffer.mPtr == nullptr || offset < 0 || length < 0 || offset > buffer->length || length > buffer->length - offset) {
		return -1;
	}
	if (length == 0) {
		return 0;
	}
	unsigned char *volatile source = &buffer[0];

#ifdef CROSSBYTE_SPAWN_WINDOWS
	HANDLE pipe = state->inWrite;
	if (!pipe) {
		return -1;
	}
	DWORD written = 0;
	hx::EnterGCFreeZone();
	BOOL ok = WriteFile(pipe, source + offset, (DWORD)length, &written, 0);
	hx::ExitGCFreeZone();
	return ok ? (int)written : -1;
#else
	int fd = state->inWrite;
	if (fd < 0) {
		return -1;
	}
	ssize_t written;
	hx::EnterGCFreeZone();
	do {
		written = ::write(fd, source + offset, (size_t)length);
	} while (written < 0 && errno == EINTR);
	hx::ExitGCFreeZone();
	return written < 0 ? -1 : (int)written;
#endif
}

void crossbyte_spawn_close_input(::Dynamic handle) {
	ChildState *state = stateOf(handle);
	std::lock_guard<std::mutex> guard(state->lock);
#ifdef CROSSBYTE_SPAWN_WINDOWS
	if (state->inWrite) {
		CloseHandle(state->inWrite);
		state->inWrite = 0;
	}
#else
	if (state->inWrite >= 0) {
		close(state->inWrite);
		state->inWrite = -1;
	}
#endif
}

void crossbyte_spawn_kill(::Dynamic handle) {
	ChildState *state = stateOf(handle);
	std::lock_guard<std::mutex> guard(state->lock);
	if (!state->open || state->waited) {
		return;
	}
#ifdef CROSSBYTE_SPAWN_WINDOWS
	TerminateProcess(state->process, (UINT)-1);
#else
	kill(state->pid, SIGTERM);
#endif
}

int crossbyte_spawn_wait(::Dynamic handle) {
	ChildState *state = stateOf(handle);
#ifdef CROSSBYTE_SPAWN_WINDOWS
	HANDLE process;
	{
		std::lock_guard<std::mutex> guard(state->lock);
		if (!state->open) {
			hx::Throw(HX_CSTRING("Process closed"));
		}
		process = state->process;
	}
	DWORD code = 0;
	hx::EnterGCFreeZone();
	WaitForSingleObject(process, INFINITE);
	BOOL ok = GetExitCodeProcess(process, &code);
	hx::ExitGCFreeZone();
	{
		std::lock_guard<std::mutex> guard(state->lock);
		state->waited = true;
	}
	return ok ? (int)code : 0;
#else
	pid_t pid;
	{
		std::lock_guard<std::mutex> guard(state->lock);
		if (!state->open) {
			hx::Throw(HX_CSTRING("Process closed"));
		}
		pid = state->pid;
	}
	int status = 0;
	pid_t got;
	hx::EnterGCFreeZone();
	do {
		got = waitpid(pid, &status, 0);
	} while (got < 0 && errno == EINTR);
	hx::ExitGCFreeZone();
	{
		std::lock_guard<std::mutex> guard(state->lock);
		state->waited = true;
	}
	if (got != pid) {
		return 0;
	}
	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}
	if (WIFSIGNALED(status)) {
		return 128 + WTERMSIG(status);
	}
	return 0;
#endif
}

int crossbyte_spawn_pid(::Dynamic handle) {
	ChildState *state = stateOf(handle);
	return (int)state->pid;
}

void crossbyte_spawn_close(::Dynamic handle) {
	ChildState *state = stateOf(handle);
	std::lock_guard<std::mutex> guard(state->lock);
	state->closeAll();
}
