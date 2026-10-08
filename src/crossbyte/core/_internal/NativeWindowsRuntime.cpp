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

// The class the process had before it was raised, so lowering it again puts
// back what the process was started with (a `start /low` included)
// rather than assuming normal. Zero while the process is not raised.
static DWORD crossbyte_windows_class_before_raise = 0;

extern "C" void crossbyte_windows_set_high_priority_process(int high)
{
	HANDLE process = GetCurrentProcess();
	if (high)
	{
		if (crossbyte_windows_class_before_raise == 0)
		{
			crossbyte_windows_class_before_raise = GetPriorityClass(process);
		}
		SetPriorityClass(process, HIGH_PRIORITY_CLASS);
	}
	else if (crossbyte_windows_class_before_raise != 0)
	{
		SetPriorityClass(process, crossbyte_windows_class_before_raise);
		crossbyte_windows_class_before_raise = 0;
	}
}

extern "C" int crossbyte_windows_get_priority_class()
{
	return static_cast<int>(GetPriorityClass(GetCurrentProcess()));
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
