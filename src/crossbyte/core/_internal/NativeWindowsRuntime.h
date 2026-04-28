#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void crossbyte_windows_begin_timing_period(int milliseconds);
void crossbyte_windows_end_timing_period(int milliseconds);
void crossbyte_windows_set_high_priority_process();
int crossbyte_windows_get_current_thread_id();
void crossbyte_windows_set_thread_priority(int threadId, int priority);

#ifdef __cplusplus
}
#endif
