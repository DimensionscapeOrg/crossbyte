package stress;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * Several CrossByte runtimes, one per thread, all moving bytes at once.
 *
 * Running a runtime per thread is a designed capability with no coverage: the
 * only cross-thread test in the suite asserts that `CrossByte.current()`
 * throws on a thread that has none. Nothing exercised several of them doing
 * real work simultaneously, which is where the state they are supposed to keep
 * apart — a socket registry, a timer scheduler, the thread's current-runtime
 * slot — would show it had not been kept apart.
 *
 * The payloads are the assertion. Each client sends a pattern seeded from its
 * own index and expects exactly that pattern back, in order, byte for byte.
 * That is deliberately hostile to the socket read path, which fills one
 * scratch buffer held per thread rather than per socket: were that buffer
 * shared across threads instead, two runtimes reading at once would splice
 * each other's bytes into their own streams, and the pattern check is what
 * notices. A length-only check would not — the byte counts would still be
 * right.
 *
 * Payloads are sized well past the read chunk so each transfer takes many
 * reads and many pumps, rather than landing in one and proving nothing.
 *
 * Invariants:
 *
 * - every client receives its own payload back, byte for byte
 * - each worker thread resolves its own runtime, never another's
 * - every runtime finishes with an empty socket registry
 */
class MultiRuntimeSocketStress implements StressCase {
	private static inline final WORKERS:Int = 6;
	private static inline final PAYLOAD:Int = 192 * 1024;
	private static inline final TIMEOUT:Float = 45.0;

	private var lock:Mutex;
	private var verified:Int = 0;
	private var mismatched:Int = 0;
	private var wrongRuntime:Int = 0;
	private var registryLeaks:Int = 0;
	private var errors:Array<String> = [];
	private var finished:Int = 0;

	public function new() {
		lock = new Mutex();
	}

	public function run():StressResult {
		// Echo server on the primordial runtime. Whatever arrives goes back
		// out on the same connection, so the client's own bytes are the only
		// thing that can come back to it.
		var server = new ServerSocket();
		var peers:Array<Socket> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event:ServerSocketConnectEvent) {
			var peer:Socket = event.socket;
			peers.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				if (peer.bytesAvailable > 0) {
					var chunk = new ByteArray();
					peer.readBytes(chunk, 0, peer.bytesAvailable);
					peer.writeBytes(chunk, 0, chunk.length);
					peer.flush();
				}
			});
		});

		server.bind(0, "127.0.0.1");
		server.listen(WORKERS * 2);

		var port:Int = server.localPort;
		var started:Float = Sys.time();

		for (i in 0...WORKERS) {
			var index:Int = i;
			Thread.create(function() {
				__worker(index, port);
			});
		}

		var primordial:CrossByte = CrossByte.current();
		var deadline:Float = Sys.time() + TIMEOUT;

		while (Sys.time() < deadline) {
			primordial.pump(1 / 120, 0);

			lock.acquire();
			var done:Bool = finished >= WORKERS;
			lock.release();

			if (done) {
				break;
			}
		}

		var elapsed:Float = Sys.time() - started;

		for (peer in peers) {
			try {
				peer.close();
			} catch (_:Dynamic) {}
		}
		try {
			server.close();
		} catch (_:Dynamic) {}

		lock.acquire();
		var ok:Int = verified;
		var bad:Int = mismatched;
		var foreign:Int = wrongRuntime;
		var leaked:Int = registryLeaks;
		var failed:Array<String> = errors.copy();
		var done:Int = finished;
		lock.release();

		var passed:Bool = ok == WORKERS && bad == 0 && foreign == 0 && leaked == 0 && failed.length == 0;

		return {
			name: "MultiRuntimeSocketStress",
			passed: passed,
			details: [
				'runtimes: $WORKERS, one per thread, ' + Math.round(PAYLOAD / 1024) + 'KB echoed each',
				'payloads verified byte-for-byte: $ok',
				'payload mismatches: $bad',
				'threads resolving the wrong runtime: $foreign',
				'runtimes left holding sockets: $leaked',
				'worker errors: ' + failed.length + (failed.length > 0 ? " -> " + failed[0] : ""),
				'workers finished: $done of $WORKERS',
				'wall time: ' + Math.round(elapsed * 1000) + 'ms, throughput: '
				+ Math.round((ok * PAYLOAD / 1024 / 1024) / elapsed) + ' MB/sec echoed'
			]
		};
	}

	/**
	 * One worker: its own runtime, its own socket, its own payload.
	 */
	private function __worker(index:Int, port:Int):Void {
		var runtime:CrossByte = null;
		var client:Socket = null;

		try {
			// Host-driven so this thread pumps it explicitly. A self-driving
			// child runtime would work too, but then the case could not tell
			// "still transferring" from "wedged", and a hang would read as a
			// timeout rather than as the failure it is.
			runtime = @:privateAccess new CrossByte(false, DEFAULT, true);

			// The runtime this thread resolves must be its own. If the
			// thread-local slot were shared, this is where two workers would
			// start driving each other's sockets.
			if (CrossByte.current() != runtime) {
				lock.acquire();
				wrongRuntime++;
				lock.release();
			}

			var expected:ByteArray = __pattern(index);
			var received = new ByteArray();
			var connected:Bool = false;
			var closed:Bool = false;

			client = new Socket();
			client.addEventListener(Event.CONNECT, function(_) {
				connected = true;
				client.writeBytes(expected, 0, expected.length);
				client.flush();
			});
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				if (client.bytesAvailable > 0) {
					client.readBytes(received, received.length, client.bytesAvailable);
				}
			});
			client.addEventListener(Event.CLOSE, function(_) closed = true);

			client.connect("127.0.0.1", port);

			var deadline:Float = Sys.time() + TIMEOUT;
			while (received.length < PAYLOAD && !closed && Sys.time() < deadline) {
				runtime.pump(1 / 120, 0);
			}

			var matches:Bool = received.length == PAYLOAD;
			if (matches) {
				received.position = 0;
				for (i in 0...PAYLOAD) {
					if (received.readUnsignedByte() != __byteAt(index, i)) {
						matches = false;
						break;
					}
				}
			}

			lock.acquire();
			if (matches) {
				verified++;
			} else {
				mismatched++;
			}
			lock.release();

			try {
				client.close();
			} catch (_:Dynamic) {}

			// Let the close reach the registry before asking whether it is
			// empty; the deregistration is queued and drained on a pump.
			var settle:Float = Sys.time() + 1.0;
			while (Sys.time() < settle) {
				runtime.pump(1 / 120, 0);
			}

			var held:Int = @:privateAccess runtime.__socketRegistry.size;
			if (held != 0) {
				lock.acquire();
				registryLeaks++;
				lock.release();
			}
		} catch (e:Dynamic) {
			lock.acquire();
			errors.push(Std.string(e));
			lock.release();

			if (client != null) {
				try {
					client.close();
				} catch (_:Dynamic) {}
			}
		}

		lock.acquire();
		finished++;
		lock.release();
	}

	/**
	 * Position-dependent and seeded by worker, so a byte belonging to another
	 * worker cannot coincidentally be the right value here.
	 */
	private static inline function __byteAt(worker:Int, i:Int):Int {
		return ((i * 31) ^ (i >> 7) ^ ((worker + 1) * 89)) & 0xFF;
	}

	private static function __pattern(worker:Int):ByteArray {
		var bytes = new ByteArray(PAYLOAD);
		for (i in 0...PAYLOAD) {
			bytes.writeByte(__byteAt(worker, i));
		}
		bytes.position = 0;
		return bytes;
	}
}
