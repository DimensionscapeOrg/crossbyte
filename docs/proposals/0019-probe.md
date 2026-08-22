# Proposal 0019 — half-close probe

**Status:** Reference measurement, not a change.

It proposes nothing and so cannot be implemented or rejected. It records what
the platform actually does, so that the design in `0019-socket-half-close.md`
can be checked against behaviour rather than against assumption, and so the
same probe can be re-run when the target, the toolchain or the OS changes.

Establishes what the platform does, since the design in
`0019-socket-half-close.md` turns on behaviour that is not obvious and is worth
being able to re-run on another target or OS.

Build against the vendored socket (`-cp src`, so this measures the same
`sys.net.Socket` CrossByte uses) and run. Output on Windows / cpp / hxcpp:

```
listening on 60660
SERVER read=[PING] terminated by: Eof
SERVER write SUCCEEDED after peer FIN
CLIENT-A received after half-close: [PONG-AFTER-PEER-FIN]
SERVER-B read=[BYE] terminated by: Eof
SERVER-B write SUCCEEDED after full close
```

Case A is a peer that calls `shutdown(false, true)`; case B is a peer that
closes outright. Two things to take from it:

- the half-closed peer **received** what was written after its FIN, so the
  capability is real
- both cases terminate the read with `Eof`, and the first write after **either**
  succeeds — a departed peer's write lands in the kernel send buffer and the RST
  comes back later, if at all

The second is why `PeerShutdownPolicy.HALF_OPEN` cannot be the default and why a
consumer choosing it has to bound the connection itself: at `Eof` there is
nothing to tell the two apart, and a successful write is not evidence anyone is
listening.

```haxe
import sys.net.Socket;
import sys.net.Host;
import sys.thread.Thread;

class HalfCloseProbe {
	static function main() {
		var server = new Socket();
		server.bind(new Host("127.0.0.1"), 0);
		server.listen(2);
		var port = server.host().port;
		Sys.println("listening on " + port);

		// Case 1: peer half-closes its write side, then waits to read.
		Thread.create(function() {
			try {
				var c = new Socket();
				c.connect(new Host("127.0.0.1"), port);
				c.output.writeString("PING");
				c.output.flush();
				c.shutdown(false, true);
				var got = "";
				try {
					while (true) got += String.fromCharCode(c.input.readByte());
				} catch (e:haxe.io.Eof) {}
				Sys.println("CLIENT-A received after half-close: [" + got + "]");
				c.close();
			} catch (e:Dynamic) {
				Sys.println("CLIENT-A error: " + Std.string(e));
			}
		});

		var a = server.accept();
		var read = "";
		var readOutcome = "";
		try {
			while (true) {
				read += String.fromCharCode(a.input.readByte());
			}
		} catch (e:haxe.io.Eof) {
			readOutcome = "Eof";
		} catch (e:Dynamic) {
			readOutcome = "OTHER: " + Type.getClassName(Type.getClass(e)) + " / " + Std.string(e);
		}
		Sys.println("SERVER read=[" + read + "] terminated by: " + readOutcome);

		var writeOutcome = "";
		try {
			a.output.writeString("PONG-AFTER-PEER-FIN");
			a.output.flush();
			writeOutcome = "write SUCCEEDED after peer FIN";
		} catch (e:Dynamic) {
			writeOutcome = "write FAILED: " + Std.string(e);
		}
		Sys.println("SERVER " + writeOutcome);
		a.close();

		// Case 2: peer vanishes abruptly (close both directions, unread data).
		Thread.create(function() {
			try {
				var c = new Socket();
				c.connect(new Host("127.0.0.1"), port);
				c.output.writeString("BYE");
				c.output.flush();
				c.close();
			} catch (e:Dynamic) {}
		});

		var b = server.accept();
		Sys.sleep(0.3);
		var r2 = "";
		var o2 = "";
		try {
			while (true) r2 += String.fromCharCode(b.input.readByte());
		} catch (e:haxe.io.Eof) {
			o2 = "Eof";
		} catch (e:Dynamic) {
			o2 = "OTHER: " + Std.string(e);
		}
		Sys.println("SERVER-B read=[" + r2 + "] terminated by: " + o2);
		var w2 = "";
		try {
			b.output.writeString("X");
			b.output.flush();
			w2 = "write SUCCEEDED after full close";
		} catch (e:Dynamic) {
			w2 = "write FAILED: " + Std.string(e);
		}
		Sys.println("SERVER-B " + w2);

		try { b.close(); } catch (_:Dynamic) {}
		server.close();
	}
}
```
