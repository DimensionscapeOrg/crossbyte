package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import sys.thread.Thread;

/**
 * Writes hard at a peer that never reads.
 *
 * Invariant: a socket with `maxOutputBufferSize` set stops growing and is
 * closed, rather than buffering until the process runs out of memory.
 *
 * This is the shape of a real outage: one stalled consumer on a fan-out
 * (a phone that slept, a half-open connection) quietly consuming the
 * server's memory while everything else looks healthy.
 */
class SocketBackpressureStress implements StressCase {
	private static inline final LIMIT:Int = 256 * 1024;
	private static inline final CHUNK:Int = 64 * 1024;
	// Far more than any receive window plus the limit, so an unbounded
	// buffer would be unmistakable.
	private static inline final CHUNKS:Int = 400;

	private var served:Socket;
	private var peakBuffer:Int = 0;
	private var closedByPolicy:Bool = false;
	private var writes:Int = 0;

	public function new() {}

	public function run():StressResult {
		var runtime:CrossByte = CrossByte.current();
		var server = new ServerSocket();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			served = e.socket;
			served.maxOutputBufferSize = LIMIT;
			served.outputOverflowPolicy = CLOSE;
		});

		server.bind(0, "127.0.0.1");
		server.listen();
		var port:Int = server.localPort;

		// A peer that connects and then never reads a byte.
		Thread.create(function() {
			try {
				var client = new sys.net.Socket();
				client.connect(new sys.net.Host("127.0.0.1"), port);
				// Hold the connection open without draining it.
				Sys.sleep(6);
				client.close();
			} catch (_:Dynamic) {}
		});

		var payload = new crossbyte.io.ByteArray();
		for (i in 0...CHUNK) {
			payload.writeByte(i & 0xFF);
		}

		var deadline:Float = Sys.time() + 20;
		var finished:Bool = false;

		while (!finished && Sys.time() < deadline) {
			@:privateAccess runtime.pump(0.016);

			if (served != null && writes < CHUNKS) {
				try {
					served.writeBytes(payload, 0, payload.length);
					served.flush();
					writes++;

					if (served.outputBufferLength > peakBuffer) {
						peakBuffer = served.outputBufferLength;
					}
				} catch (_:Dynamic) {
					// The socket was closed by policy mid-write.
					closedByPolicy = true;
					finished = true;
				}
			}

			if (served != null && !served.connected) {
				closedByPolicy = true;
				finished = true;
			}

			if (writes >= CHUNKS) {
				finished = true;
			}
		}

		var totalOffered:Int = writes * CHUNK;
		// Allow one chunk of overshoot: the limit is checked after a flush,
		// so the buffer can exceed it by at most the write that crossed it.
		var bounded:Bool = peakBuffer <= LIMIT + CHUNK;
		var passed:Bool = closedByPolicy && bounded;

		try {
			server.close();
		} catch (_:Dynamic) {}

		return {
			name: "Socket write backpressure",
			passed: passed,
			details: [
				'limit=$LIMIT chunk=$CHUNK offered=$totalOffered bytes over $writes write(s)',
				'peak buffered=$peakBuffer (bound ' + (LIMIT + CHUNK) + ")",
				'closed by policy=$closedByPolicy'
			]
		};
	}
}
