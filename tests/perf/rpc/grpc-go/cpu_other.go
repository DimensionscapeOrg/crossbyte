//go:build !windows

package main

import (
	"os"
	"strconv"
	"strings"
)

// processSeconds is the processor time a process has used, user and kernel,
// from /proc/<pid>/stat (Linux), in the kernel's clock ticks of 1/100 s.
func processSeconds(pid int) float64 {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return -1
	}
	text := string(raw)
	// The name, in parentheses, may hold spaces; the fields after it are
	// state (3), then on to utime (14) and stime (15).
	end := strings.LastIndexByte(text, ')')
	if end < 0 {
		return -1
	}
	fields := strings.Fields(text[end+1:])
	if len(fields) < 13 {
		return -1
	}
	user, err1 := strconv.ParseFloat(fields[11], 64)
	kernel, err2 := strconv.ParseFloat(fields[12], 64)
	if err1 != nil || err2 != nil {
		return -1
	}
	return (user + kernel) / 100
}
