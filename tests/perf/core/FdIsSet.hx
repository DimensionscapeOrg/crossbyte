#if (cpp && windows)
import haxe.Timer;

/**
	What hxcpp's Windows poll does around its select() call, alone: copying
	the read set, building the exception set with FD_SET, and then asking
	FD_ISSET of every registered socket against the ready set select left.
	On Windows an fd_set is an array, FD_ISSET a linear search of it, and
	FD_SET a search for a duplicate, so the last step is registered x ready.

	`PerfCore fdisset N` times it for N registered sockets with N/2 ready,
	the shape of a busy echo pass (`echo` with N/2 connections). A micro-
	measure of glue the workload pays once a pass, to apportion `echo`'s
	per-pass time; not a workload of its own. The loop is copied from the
	fork's src/hx/libs/std/Socket.cpp, _hx_std_socket_poll_events.
**/
@:cppFileCode("
#include <winsock2.h>
#include <stdlib.h>
#include <string.h>
#define PERF_FDSIZE(n) (offsetof(fd_set, fd_array) + (n) * sizeof(SOCKET))

static int perf_fd_pass(int n)
{
	static fd_set *fdr = 0;
	static fd_set *outr = 0;
	static int made = 0;
	if (made != n)
	{
		free(fdr);
		free(outr);
		fdr = (fd_set *)malloc(PERF_FDSIZE(n));
		outr = (fd_set *)malloc(PERF_FDSIZE(n));
		for (int i = 0; i < n; i++)
			fdr->fd_array[i] = (SOCKET)(1000 + 4 * i);
		fdr->fd_count = n;
		made = n;
	}

	// As the poll does before select.
	memcpy(outr, fdr, PERF_FDSIZE(fdr->fd_count));
	fd_set oute;
	FD_ZERO(&oute);
	for (u_int i = 0; i < fdr->fd_count; ++i)
		FD_SET(fdr->fd_array[i], &oute);

	// What select leaves: every other socket readable, no exceptions.
	int ready = 0;
	for (int i = 0; i < n; i += 2)
		outr->fd_array[ready++] = fdr->fd_array[i];
	outr->fd_count = ready;
	oute.fd_count = 0;

	// As the poll does after select.
	int k = 0;
	for (u_int i = 0; i < fdr->fd_count; ++i)
	{
		SOCKET fd = fdr->fd_array[i];
		if (FD_ISSET(fd, outr) || FD_ISSET(fd, &oute))
			k++;
	}
	return k;
}

// The fork's branch perf-core-pc2-select: one walk alongside the ready set.
static int perf_fd_pass_walk(int n)
{
	static fd_set *fdr = 0;
	static fd_set *outr = 0;
	static int made = 0;
	if (made != n)
	{
		free(fdr);
		free(outr);
		fdr = (fd_set *)malloc(PERF_FDSIZE(n));
		outr = (fd_set *)malloc(PERF_FDSIZE(n));
		for (int i = 0; i < n; i++)
			fdr->fd_array[i] = (SOCKET)(1000 + 4 * i);
		fdr->fd_count = n;
		made = n;
	}

	memcpy(outr, fdr, PERF_FDSIZE(fdr->fd_count));
	fd_set oute;
	FD_ZERO(&oute);
	u_int count = fdr->fd_count < FD_SETSIZE ? fdr->fd_count : FD_SETSIZE;
	for (u_int i = 0; i < count; ++i)
		oute.fd_array[i] = fdr->fd_array[i];
	oute.fd_count = count;

	int ready = 0;
	for (int i = 0; i < n; i += 2)
		outr->fd_array[ready++] = fdr->fd_array[i];
	outr->fd_count = ready;
	oute.fd_count = 0;

	int k = 0;
	u_int r = 0, e = 0;
	for (u_int i = 0; i < fdr->fd_count; ++i)
	{
		SOCKET fd = fdr->fd_array[i];
		bool hit = false;
		if (r < outr->fd_count && outr->fd_array[r] == fd) { hit = true; r++; }
		if (e < oute.fd_count && oute.fd_array[e] == fd) { hit = true; e++; }
		if (hit)
			k++;
	}
	return k;
}
")
class FdIsSet {
	public static function run(n:Int, seconds:Float, walk:Bool = false):Void {
		var passes = 0;
		var found = 0;
		var t0 = Sys.cpuTime();
		var w0 = Timer.stamp();
		while (Timer.stamp() - w0 < seconds) {
			found += walk ? passWalk(n) : pass(n);
			passes++;
		}
		var used = Sys.cpuTime() - t0;
		Sys.println('RESULT ${walk ? "fdwalk" : "fdisset"} $n passes=$passes found=$found cpu_s=${Math.round(used * 1000) / 1000} us_per_pass=${Math.round(used / passes * 1e9) / 1000}');
	}

	static function pass(n:Int):Int {
		return untyped __cpp__("perf_fd_pass({0})", n);
	}

	static function passWalk(n:Int):Int {
		return untyped __cpp__("perf_fd_pass_walk({0})", n);
	}
}
#end
