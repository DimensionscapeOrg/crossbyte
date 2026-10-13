//go:build windows && !amd64

package main

import "time"

// measureCycleHz has no counter to read here, so processSeconds falls back on
// GetProcessTimes.
func measureCycleHz() float64 {
	return 0
}

var base = time.Now()

// nanos is a clock for timing one round trip (coarse on Windows).
func nanos() int64 {
	return int64(time.Since(base))
}
