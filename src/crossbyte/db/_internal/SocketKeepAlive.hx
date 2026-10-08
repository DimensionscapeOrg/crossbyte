package crossbyte.db._internal;

// Not built for any JavaScript target: the database clients that use it are not.
#if !js

/**
	TCP keepalive on a `sys.net.Socket` a database client drives itself, so a
	connection to a server that has vanished (a partition, a host that died
	without closing) is noticed instead of waited on: `idle` seconds without
	traffic before the first probe, `interval` between probes, `count`
	unanswered probes before the connection is dropped, and 0 for any of them
	leaves the system's own. The MySQL client in the hxcpp fork sets it the
	same way on its own socket, and libpq on Postgres's.

	What each target can set:
	- natively, all three on Linux and macOS, and on Windows 10 1703 and
	  later; older Windows has no count, and keeps ten probes;
	- on the jvm, keepalive itself everywhere, and the timings from Java 11
	  on (`jdk.net.ExtendedSocketOptions`); on Java 8 the system's apply,
	  which is two hours before the first probe on Linux and Windows;
	- nothing on the interpreter, hl and neko, whose sockets have no such
	  option: a server that goes silent there is waited on for as long as a
	  read waits.
**/
class SocketKeepAlive {
	/**
		Turns keepalive on for `socket`, with the timings given. Best effort:
		answers whether the system took all of it, and never throws.
	**/
	public static function enable(socket:sys.net.Socket, idle:Int, interval:Int, count:Int):Bool {
		#if cpp
		try {
			return NativeKeepAlive.set(@:privateAccess socket.__s, true, idle, interval, count);
		} catch (_:Dynamic) {
			return false;
		}
		#elseif ((java || jvm) && !macro)
		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess socket.channel;
			channel.setOption(cast java.net.StandardSocketOptions.SO_KEEPALIVE, cast java.lang.Boolean.valueOf(true));
		} catch (_:Dynamic) {
			return false;
		}

		// Each attempted, whichever the JVM refuses.
		var idleSet:Bool = idle <= 0 || __setExtended(socket, "TCP_KEEPIDLE", idle);
		var intervalSet:Bool = interval <= 0 || __setExtended(socket, "TCP_KEEPINTERVAL", interval);
		var countSet:Bool = count <= 0 || __setExtended(socket, "TCP_KEEPCOUNT", count);
		return idleSet && intervalSet && countSet;
		#else
		return false;
		#end
	}

	/**
		The keepalive `socket` has, read back from it: on (1 or 0), then the
		idle and interval seconds and the probe count, each -1 where the
		target or the system does not say.
	**/
	public static function state(socket:sys.net.Socket):Array<Int> {
		#if cpp
		try {
			return NativeKeepAlive.state(@:privateAccess socket.__s);
		} catch (_:Dynamic) {
			return [-1, -1, -1, -1];
		}
		#elseif ((java || jvm) && !macro)
		var state:Array<Int> = [-1, -1, -1, -1];

		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess socket.channel;
			var on:java.lang.Boolean = cast channel.getOption(cast java.net.StandardSocketOptions.SO_KEEPALIVE);
			state[0] = on.booleanValue() ? 1 : 0;
		} catch (_:Dynamic) {}

		state[1] = __getExtended(socket, "TCP_KEEPIDLE");
		state[2] = __getExtended(socket, "TCP_KEEPINTERVAL");
		state[3] = __getExtended(socket, "TCP_KEEPCOUNT");
		return state;
		#else
		return [-1, -1, -1, -1];
		#end
	}

	#if ((java || jvm) && !macro)
	/**
		One of Java 11's `jdk.net.ExtendedSocketOptions`, looked up rather
		than named: the jvm build targets Java 8, which has no such field.
	**/
	@:noCompletion private static function __extended(name:String):Dynamic {
		try {
			var options:java.lang.Class<Dynamic> = cast java.lang.Class.forName("jdk.net.ExtendedSocketOptions");
			return options.getField(name).get(null);
		} catch (_:Dynamic) {
			return null;
		}
	}

	@:noCompletion private static function __setExtended(socket:sys.net.Socket, name:String, value:Int):Bool {
		var option:Dynamic = __extended(name);

		if (option == null) {
			return false;
		}

		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess socket.channel;
			channel.setOption(cast option, cast java.lang.Integer.valueOf(value));
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	@:noCompletion private static function __getExtended(socket:sys.net.Socket, name:String):Int {
		var option:Dynamic = __extended(name);

		if (option == null) {
			return -1;
		}

		try {
			var channel:java.nio.channels.NetworkChannel = cast @:privateAccess socket.channel;
			var value:java.lang.Integer = cast channel.getOption(cast option);
			return value.intValue();
		} catch (_:Dynamic) {
			return -1;
		}
	}
	#end
}
#end
