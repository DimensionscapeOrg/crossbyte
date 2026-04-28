#include <hxcpp.h>

#include "NativeWindowsRuntime.h"

#include <Windows.h>
#include <mmsystem.h>

extern "C" void crossbyte_windows_begin_timing_period(int milliseconds)
{
	if (milliseconds > 0)
	{
		timeBeginPeriod(static_cast<UINT>(milliseconds));
	}
}

extern "C" void crossbyte_windows_end_timing_period(int milliseconds)
{
	if (milliseconds > 0)
	{
		timeEndPeriod(static_cast<UINT>(milliseconds));
	}
}

extern "C" void crossbyte_windows_set_high_priority_process()
{
	SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
}

extern "C" int crossbyte_windows_get_current_thread_id()
{
	return static_cast<int>(GetCurrentThreadId());
}

extern "C" void crossbyte_windows_set_thread_priority(int threadId, int priority)
{
	if (threadId == 0)
	{
		return;
	}

	HANDLE thread = OpenThread(THREAD_SET_INFORMATION, FALSE, static_cast<DWORD>(threadId));
	if (thread == nullptr)
	{
		return;
	}

	SetThreadPriority(thread, priority);
	CloseHandle(thread);
}
