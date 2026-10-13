package main

import (
	"sync"
	"time"
)

// rdtsc reads the processor's time-stamp counter (tsc_windows_amd64.s).
func rdtsc() uint64

// measureCycleHz is the rate the cycle counter runs at, measured once against
// the clock: an invariant TSC, which QueryProcessCycleTime counts, ticks at a
// constant rate whatever the clock speed.
func measureCycleHz() float64 {
	start := time.Now()
	c0 := rdtsc()
	for time.Since(start) < 50*time.Millisecond {
	}
	c1 := rdtsc()
	return float64(c1-c0) / time.Since(start).Seconds()
}

var (
	clockHz   float64
	clockOnce sync.Once
)

// nanos is a clock for timing one round trip. Go's own clock on Windows
// moves in steps of about a millisecond (the system's interrupt time), too
// coarse for calls that take tens of microseconds; the time-stamp counter
// moves every cycle.
func nanos() int64 {
	clockOnce.Do(func() { clockHz = measureCycleHz() })
	return int64(float64(rdtsc()) * 1e9 / clockHz)
}
