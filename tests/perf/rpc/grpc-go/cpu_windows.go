//go:build windows

package main

import (
	"sync"
	"syscall"
	"unsafe"
)

const processQueryLimitedInformation = 0x1000

var (
	queryProcessCycleTime = syscall.NewLazyDLL("kernel32.dll").NewProc("QueryProcessCycleTime")
	handles               = map[int]syscall.Handle{}
	cycleHz               float64
	calibrated            sync.Once
)

// processSeconds is the processor time a process has used, counted from the
// cycles its threads ran (QueryProcessCycleTime), as LoadStats' ProcessStats
// counts its own. GetProcessTimes charges a whole clock tick to whichever
// thread is running when the tick lands, so a process that wakes and works
// for less than a tick is mostly never charged; it is the fallback only.
func processSeconds(pid int) float64 {
	handle, ok := handles[pid]
	if !ok {
		h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
		if err != nil {
			return -1
		}
		handle = h
		handles[pid] = handle
	}
	calibrated.Do(func() { cycleHz = measureCycleHz() })
	if cycleHz > 0 {
		var cycles uint64
		if r, _, _ := queryProcessCycleTime.Call(uintptr(handle), uintptr(unsafe.Pointer(&cycles))); r != 0 {
			return float64(cycles) / cycleHz
		}
	}
	var created, exited, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(handle, &created, &exited, &kernel, &user); err != nil {
		return -1
	}
	return float64(filetime(kernel)+filetime(user)) / 1e7
}

func filetime(t syscall.Filetime) uint64 {
	return uint64(t.HighDateTime)<<32 | uint64(t.LowDateTime)
}
