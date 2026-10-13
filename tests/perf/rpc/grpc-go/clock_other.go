//go:build !windows

package main

import "time"

var base = time.Now()

// nanos is a clock for timing one round trip: Go's monotonic clock, which
// moves every nanosecond off Windows.
func nanos() int64 {
	return int64(time.Since(base))
}
