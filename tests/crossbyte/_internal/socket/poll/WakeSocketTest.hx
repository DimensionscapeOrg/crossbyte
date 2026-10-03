package crossbyte._internal.socket.poll;

import utest.Assert;
#if target.threaded
import sys.thread.Lock;
import sys.thread.Thread;
#end

/**
	A runtime's wake socket, woken from one thread while the runtime closes
	it on its own.

	Every thread that hands a runtime something wakes it: a post, an
	`exit()`, a parent exiting its children as it exits -- and that runtime
	may be exiting at that moment, closing its wake socket on its own
	thread. The wake checked whether the socket was closed and then wrote to
	it, unsynchronised, so a close between the two left the write going to a
	closed descriptor: on the interpreter an error no `catch` can see, which
	ended the process (a server's runtimes being exited together found it),
	and natively a descriptor the system may already have given another
	socket.
**/
@:access(crossbyte._internal.socket.poll.WakeSocket)
class WakeSocketTest extends utest.Test {
	#if (target.threaded && !js)
	@:timeout(60000)
	public function testAWakeRacingACloseNeverWritesToAClosedSocket():Void {
		var rounds:Int = 0;
		var failures:Array<String> = [];
		for (_ in 0...150) {
			var waker:Null<WakeSocket> = WakeSocket.create();
			if (waker == null) {
				// No loopback connection here: nothing to race.
				Assert.pass();
				return;
			}

			var started:Lock = new Lock();
			var finished:Lock = new Lock();
			var stop:Bool = false;
			Thread.create(() -> {
				started.release();
				try {
					while (!stop) {
						waker.wake();
					}
				} catch (error:Dynamic) {
					failures.push(Std.string(error));
				}
				finished.release();
			});
			started.wait(5.0);
			crossbyte.sys.System.sleep(0.0005);
			waker.close();
			// Woken a while longer, after the close, as a late post is.
			crossbyte.sys.System.sleep(0.001);
			stop = true;
			if (!finished.wait(2.0)) {
				// On the interpreter the error kills the thread outright.
				failures.push("the waking thread died in round " + rounds);
				break;
			}
			rounds++;
		}

		Assert.equals(150, rounds);
		Assert.same([], failures, "a wake threw once the socket was closed");
	}

	public function testAClosedWakeSocketIgnoresWakes():Void {
		var waker:Null<WakeSocket> = WakeSocket.create();
		if (waker == null) {
			Assert.pass();
			return;
		}
		waker.close();
		waker.wake();
		waker.close();
		Assert.isTrue(waker.registryClosed);
	}
	#end
}
