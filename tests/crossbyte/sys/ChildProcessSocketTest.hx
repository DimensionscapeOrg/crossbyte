package crossbyte.sys;

import crossbyte.events.NativeProcessEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.NetPump;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import crossbyte.net.WirePeer;
import utest.Assert;
import utest.Async;

/**
	A process a server starts gets none of the server's sockets.

	Natively a child process must not be handed copies of them: on Windows
	a socket must not be inheritable, since a process may be started with
	every inheritable handle, and on posix an accepted socket must be
	close-on-exec. Otherwise a server that started a command while a client
	was connected would give the command that connection, so closing it
	would end nothing: the client would see the end of the stream only when
	the command exited, which for a long-running child is never. On Windows
	the listener would go too, and a server that closed would keep
	answering on its port while the child ran.

	The child here outlives every wait by far, so a socket it holds is still
	open when the wait gives up.

	Natively, built for any OS, and on the jvm, whose sockets no child is
	handed. It runs on any cpp build, the jvm, hl and neko. Not on neko,
	where it does not hold and cannot be made to: its sockets are
	inheritable and its processes are started inheriting, and Haxe can
	change neither, so both cases fail there, the listener and the
	connection held by the child. hl makes its sockets and processes the
	same way, and is not run here.
**/
class ChildProcessSocketTest extends utest.Test {
	#if (cpp || java || jvm)
	private static inline var CHILD_SECONDS:Int = 30;
	private static inline var DEADLINE:Float = 5.0;
	private static inline var PROBES:Int = 20;

	// A server accepts through CrossByte's own crossbyte_socket_accept
	// (NativeSocketAddress.cpp), not hxcpp's accept, so it is that function
	// that has to set close-on-exec on what it accepts, keeping the
	// connection from the child on Linux and macOS.
	@:timeout(30000)
	public function testClosingAConnectionEndsItWhileAChildRuns(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted = e.socket;
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, DEADLINE, function(_) {
			var peer = new WirePeer(server.localPort);

			NetPump.until(() -> accepted != null, DEADLINE, function(connected) {
				if (!connected) {
					Assert.fail("the connection was never accepted");
					peer.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
					return;
				}

				var child = startChild();
				accepted.close();

				NetPump.until(() -> {
					peer.poll();
					return peer.ended;
				}, DEADLINE, function(ended) {
					Assert.isTrue(ended, 'the client saw no end of the stream ${DEADLINE}s after the server closed it: the child process holds the connection');
					peer.close();
					try server.close() catch (_:Dynamic) {}
					stopChild(child, () -> async.done());
				});
			});
		});
	}

	@:timeout(30000)
	public function testAClosedListenerFreesItsPortWhileAChildRuns(async:Async):Void {
		var server = new ServerSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, DEADLINE, function(_) {
			var port:Int = server.localPort;
			var child = startChild();
			server.close();

			// Nothing listens on the port now, so a connection is refused. A
			// child holding a copy of the listener takes it into its backlog
			// instead, every time. Asked more than once because on posix a
			// child holds every descriptor between fork and exec, a moment
			// the first connection can land in; fewer times than a backlog
			// holds, because a full one refuses too.
			var refused:Bool = false;
			for (_ in 0...PROBES) {
				var probe = new sys.net.Socket();
				try {
					probe.connect(new sys.net.Host("127.0.0.1"), port);
				} catch (_:Dynamic) {
					refused = true;
				}
				try probe.close() catch (_:Dynamic) {}
				if (refused) {
					break;
				}
				crossbyte.sys.System.sleep(0.1);
			}

			Assert.isTrue(refused, 'port $port took all $PROBES connections tried after the server closed: the child process holds the listener');
			stopChild(child, () -> async.done());
		});
	}

	// Asked of the system rather than of the build: only a cpp build names
	// the OS it is for, and the jvm's runs on any.
	private static function startChild():NativeProcess {
		var child = new NativeProcess();
		if (Sys.systemName() == "Windows") {
			child.start(new NativeProcessStartupInfo("ping", ["-n", Std.string(CHILD_SECONDS + 1), "127.0.0.1"]));
		} else {
			child.start(new NativeProcessStartupInfo("sleep", [Std.string(CHILD_SECONDS)]));
		}
		return child;
	}

	private static function stopChild(child:NativeProcess, then:Void->Void):Void {
		var exited:Bool = false;
		child.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);
		child.exit();
		NetPump.until(() -> exited, DEADLINE, function(stopped) {
			Assert.isTrue(stopped, "the child process did not exit when stopped");
			then();
		});
	}
	#end
}
