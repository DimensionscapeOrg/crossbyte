package crossbyte.net._internal;

#if (!js && target.threaded)
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.IOError;
import sys.net.Host;
import sys.net.Socket;

/**
	`SO_REUSEPORT` for the listeners of a server spread over runtimes with
	`ServerSocket.reusePort`: set on each socket before it binds, so that
	several listening sockets share one port and the kernel shares the
	connections out among them.

	Linux only, natively and on the jvm from Java 9, which is the first to
	name the option. `ServerSocket.reusePort` says why nowhere else.
**/
@:noCompletion
@:access(sys.net.Socket)
@:access(sys.net.Host)
class ReusePort {
	/**
		Binds `socket` to `host`:`port` with `SO_REUSEPORT` set on it first.

		@throws IOError When the option cannot be set or the bind fails.
		@throws IllegalOperationError Where there is no such option.
	**/
	public static function bind(socket:Socket, host:Host, port:Int):Void {
		#if (cpp && linux)
		var ipv6:haxe.io.BytesData = host.ip == 0 && host.host != "0.0.0.0" ? Reflect.field(host, "ipv6") : null;
		if (ipv6 != null && !Std.isOfType(socket, sys.ssl.Socket)) {
			// The socket's bind() makes a new IPv6 socket for an IPv6 address,
			// which would not carry the option: made here instead, with it.
			socket.close();
			socket.__s = socket.__createSocket(true);
			socket.init();
			__set(socket);
			cpp.NativeSocket.socket_bind_ipv6(socket.__s, ipv6, port);
			return;
		}
		__set(socket);
		socket.bind(host, port);
		#elseif (java || jvm)
		var refusal:Null<String> = jvmRefusal();
		if (refusal != null) {
			throw new IllegalOperationError(refusal);
		}
		// The shim opens its server channel in bind() unless it has one, and
		// the option has to be on the channel before it binds.
		var channel:java.nio.channels.ServerSocketChannel = java.nio.channels.ServerSocketChannel.open();
		channel.configureBlocking(socket.__blocking);
		try {
			// Through the interface: the channel's own setOption and the
			// bridge to it are both visible, and Haxe cannot pick.
			var option:java.net.SocketOption<java.lang.Boolean> = cast __jvmOption();
			var network:java.nio.channels.NetworkChannel = channel;
			network.setOption(option, java.lang.Boolean.TRUE);
		} catch (error:Dynamic) {
			try {
				channel.close();
			} catch (_:Dynamic) {}
			throw new IOError("SO_REUSEPORT could not be set: " + Std.string(error));
		}
		socket.serverChannel = channel;
		socket.bind(host, port);
		#else
		throw new IllegalOperationError("reusePort is SO_REUSEPORT, available natively and on the jvm, on Linux.");
		#end
	}

	/**
		Binds the server's own socket to `host`:`port` with `SO_REUSEPORT`, to
		hold the port without listening on it. The system shares connections
		out among every socket on the port that listens, so a listening one
		that nobody accepts from would be given its share and leave them
		waiting: on Linux one connection in five with four runtimes.

		Natively that is `bind`, which only binds. On the jvm a server
		channel listens as it binds, so the socket's own channel, a
		connection's, is bound instead, as `bind()` binds a client's socket
		before it connects.

		@throws IOError When the option cannot be set or the bind fails.
		@throws IllegalOperationError Where there is no such option.
	**/
	public static function reserve(socket:Socket, host:Host, port:Int):Void {
		#if (java || jvm)
		var refusal:Null<String> = jvmRefusal();
		if (refusal != null) {
			throw new IllegalOperationError(refusal);
		}
		// Through the interface, as in bind.
		var network:java.nio.channels.NetworkChannel = cast socket.channel;
		try {
			var option:java.net.SocketOption<java.lang.Boolean> = cast __jvmOption();
			network.setOption(option, java.lang.Boolean.TRUE);
		} catch (error:Dynamic) {
			throw new IOError("SO_REUSEPORT could not be set: " + Std.string(error));
		}
		network.bind(new java.net.InetSocketAddress(host.wrapped, port));
		#else
		bind(socket, host, port);
		#end
	}

	#if (cpp && linux)
	@:noCompletion private static function __set(socket:Socket):Void {
		var failure:Null<String> = NativeReusePort.set(socket.__s);
		if (failure != null) {
			throw new IOError("SO_REUSEPORT could not be set: " + failure);
		}
	}
	#end

	#if (java || jvm)
	/**
		Why the jvm here cannot set the option, or null where it can: Linux,
		and a Java that names it.
	**/
	public static function jvmRefusal():Null<String> {
		if (Sys.systemName() != "Linux") {
			return "reusePort is SO_REUSEPORT on Linux; macOS and the BSDs accept it without spreading connections, and Windows has nothing like it. Leave it off: runtimes hands connections out on every system.";
		}
		if (__jvmOption() == null) {
			return "reusePort needs Java 9 or later on the jvm, the first to expose SO_REUSEPORT; this is Java "
				+ java.lang.System.getProperty("java.version") + ". Leave it off: runtimes hands connections out on every Java.";
		}
		return null;
	}

	/**
		`StandardSocketOptions.SO_REUSEPORT`, looked up rather than named: it
		is Java 9's, and the jvm build targets Java 8.
	**/
	@:noCompletion private static function __jvmOption():Dynamic {
		try {
			var options:java.lang.Class<Dynamic> = cast java.lang.Class.forName("java.net.StandardSocketOptions");
			return options.getField("SO_REUSEPORT").get(null);
		} catch (_:Dynamic) {
			return null;
		}
	}
	#end
}
#end
