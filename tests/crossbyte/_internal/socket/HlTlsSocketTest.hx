package crossbyte._internal.socket;

#if hl
import crossbyte.net.TLSTestFixture;
import haxe.io.Bytes;
import sys.net.Host;
import sys.thread.Deque;
import sys.thread.Thread;
#end
import utest.Assert;

/**
	A thread waiting for a slow TLS server's answer does not stop the others.

	HashLink's collector stops every thread, and waits for each to reach a safe
	point or to have said it is blocked. Its TLS layer read the network without
	saying so, so the first collection after a thread began waiting on an HTTPS
	response held every thread until the response came: six seconds' wait on a
	pool thread stopped the runtime for six.
**/
class HlTlsSocketTest extends utest.Test {
	#if hl
	static inline var DELAY:Float = 1.5;

	public function testAWaitForTlsDataDoesNotStopTheOtherThreads():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// TLSTestFixture makes its certificate with the openssl CLI.
			Assert.pass("no openssl to make a certificate with; skipped");
			return;
		}

		var events = new Deque<String>();
		var port = new Deque<Int>();

		// A server that answers the request DELAY seconds late. Its accepted
		// socket is the standard library's; what matters here is the client.
		Thread.create(() -> {
			var listener = new sys.ssl.Socket();
			try {
				// Asks the client for no certificate, which it has none of.
				listener.verifyCert = false;
				listener.setCertificate(sys.ssl.Certificate.loadFile(fixture.certificatePath), sys.ssl.Key.loadFile(fixture.keyPath));
				listener.bind(new Host("127.0.0.1"), 0);
				listener.listen(1);
				port.add(listener.host().port);
				var peer = listener.accept();
				peer.handshake();
				var request = Bytes.alloc(4);
				peer.input.readFullBytes(request, 0, 4);
				Sys.sleep(DELAY);
				peer.output.writeString("done");
				peer.output.flush();
				Sys.sleep(0.2);
				peer.close();
			} catch (e:Dynamic) {
				port.add(-1);
				events.add("server failed: " + Std.string(e));
			}
			try listener.close() catch (_:Dynamic) {}
		});

		var serverPort = port.pop(true);
		if (serverPort < 0) {
			Assert.fail(events.pop(false));
			return;
		}

		Thread.create(() -> {
			var client = new HlTlsSocket();
			try {
				client.verifyCert = false;
				client.setTimeout(10);
				client.connect(new Host("127.0.0.1"), serverPort);
				client.output.writeString("ping");
				client.output.flush();
				events.add("waiting");
				var answer = Bytes.alloc(4);
				client.input.readFullBytes(answer, 0, 4);
				events.add("answer " + answer.toString());
			} catch (e:Dynamic) {
				events.add("client failed: " + Std.string(e));
			}
			try client.close() catch (_:Dynamic) {}
		});

		var first = events.pop(true);
		if (first != "waiting") {
			Assert.fail(first);
			return;
		}

		// Garbage enough that the collector runs while the client waits, and
		// the longest this thread went between two turns of the loop.
		var garbage:Array<Bytes> = [];
		var last:Float = haxe.Timer.stamp();
		var longest:Float = 0.0;
		var answer:Null<String> = null;
		var deadline:Float = last + DELAY + 10.0;
		while (answer == null && haxe.Timer.stamp() < deadline) {
			for (_ in 0...10) {
				garbage.push(Bytes.alloc(100000));
			}
			if (garbage.length > 100) {
				garbage = [];
			}
			Sys.sleep(0.001);
			var now:Float = haxe.Timer.stamp();
			if (now - last > longest) {
				longest = now - last;
			}
			last = now;
			answer = events.pop(false);
		}

		Assert.equals("answer done", answer);
		Assert.isTrue(longest < DELAY / 2, "the other threads stopped for " + Math.round(longest * 1000) + " ms while one waited on TLS");
	}
	#end
}
