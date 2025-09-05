package crossbyte.net;

import haxe.Timer;
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import haxe.io.Error;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import crossbyte.errors.Error as CBError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.Socket as CBSocket;
import crossbyte.io.ByteArray;
import sys.net.Host;
import sys.net.Socket;

/**
	The ServerSocket class allows code to act as a server for Transport Control Protocol (TCP)
	connections.
	This feature is supported on all desktop operating systems, on iOS, and on Android.
	This feature is not supported on html5. You can test for support at run time using the
	ServerSocket.isSupported property.
	A TCP server listens for incoming connections from remote clients. When a client attempts
	to connect, the ServerSocket dispatches a connect event. The ServerSocketConnectEvent object
	dispatched for the event provides a Socket object representing the TCP connection between the
	server and the client. Use this Socket object for subsequent communication with the connected
	client. You can get the client address and port from the Socket object, if needed.
	Note: Your application is responsible for maintaining a reference to the client Socket object.
	If you don't, the object is eligible for garbage collection and may be destroyed by the runtime
	without warning.
	To put a ServerSocket object into the listening state, call the listen() method. In the
	listening state, the server socket object dispatches connect events whenever a client using the
	TCP protocol attempts to connect to the bound address and port. The ServerSocket object
	continues to listen for additional connections until you call the close() method.
	TCP connections are persistent — they exist until one side of the connection closes it (or a
	serious network failure occurs). Any data sent over the connection is broken into transmittable
	packets and reassembled on the other end. All packets are guaranteed to arrive (within reason) —
	any lost packets are retransmitted. In general, the TCP protocol manages the available network
	bandwidth better than the UDP protocol. Most AIR applications that require socket communications
	should use the ServerSocket and Socket classes rather than the DatagramSocket class.
	The ServerSocket class can only be used in targets that support TCP.
	@event close    Dispatched when the operating system closes this socket.
	@event connect  Dispatched when a remote socket seeks to connect to this server socket.
**/
// @:fileXml('tags="haxe,release"')
// @:noDebug
@:access(crossbyte.net.Socket)
class ServerSocket extends EventDispatcher {
	/**
		Indicates whether the socket is bound to a local address and port.
	**/
	public var bound(default, null):Bool;

	/**
		Indicates whether or not ServerSocket features are supported in the run-time environment.
	**/
	public static var isSupported(default, null):Bool = #if !html5 true #else false #end;

	/**
		Indicates whether the server socket is listening for incoming connections.
	**/
	public var listening(default, null):Bool;

	/**
		The IP address on which the socket is listening.
	**/
	public var localAddress(default, null):String;

	/**
		The port on which the socket is listening.
	**/
	public var localPort(default, null):Int;

	@:noCompletion private var __serverSocket:Socket;
	@:noCompletion private var __closed:Bool;
	@:noCompletion private var __cbInstance:CrossByte;
	@:noCompletion private var __hasListener:Bool = false;

	/**
		Creates a ServerSocket object.
		@throws  SecurityError This error occurs ff the calling content is running outside the AIR
				application security sandbox.
	**/
	public function new() {
		super();

		__init();
	}

	private function __init():Void {
		__serverSocket = new sys.net.Socket();
		__serverSocket.setBlocking(false);
		__serverSocket.setFastSend(true);
		__closed = false;
		bound = false;
		listening = false;
	}

	/**
		Binds this socket to the specified local address and port.
		@param localPort 	(default = 0) The number of the port to bind to on the local computer.
							If localPort, is set to 0 (the default), the next available system port is bound. Permission
							to connect to a port number below 1024 is subject to the system security policy. On Mac and
							Linux systems, for example, the application must be running with root privileges to connect
							to ports below 1024.
		@param localAddress (default = "0.0.0.0") The IP address on the local machine to bind
							to. This address can be an IPv4 or IPv6 address. If localAddress is set to 0.0.0.0 (the
							default), the socket listens on all available IPv4 addresses. To listen on all available IPv6
							addresses, you must specify "::" as the localAddress argument. To use an IPv6 address, the
							computer and network must both be configured to support IPv6. Furthermore, a socket bound to
							an IPv4 address cannot connect to a socket with an IPv6 address. Likewise, a socket bound to
							an IPv6 address cannot connect to a socket with an IPv4 address. The type of address must
							match.
		@throws RangeError    This error occurs when localPort is less than 0 or greater than 65535.
		@throws ArgumentError This error occurs when localAddress is not a syntactically well-formed IP address.
		@throws IOError 	  When the socket cannot be bound, such as when:
							  the underlying network socket (IP and port) is already in bound by another object or process.
							  the application is running under a user account that does not have the privileges necessary to bind to the port. Privilege issues typically occur when attempting to bind to well known ports (localPort < 1024)
							  this ServerSocket object is already bound. (Call close() before binding to a different socket.)
							  when localAddress is not a valid local address.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (localPort > 65535 || localPort < 0) {
			throw new RangeError("Invalid socket port number specified.");
		}

		try {
			var host:Host = new Host(localAddress);
			__serverSocket.bind(host, localPort);

			this.localAddress = localAddress;
			this.localPort = localPort == 0 ? __serverSocket.host().port : localPort;
			bound = true;
		} catch (e:Dynamic) {
			switch (e) {
				case "Bind failed":
					throw new IOError("Operation attempted on invalid socket.");
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
			}
		}
	}

	/**
		Closes the socket and stops listening for connections.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
	**/
	public function close():Void {
		try {
			__serverSocket.close();
		} catch (e:Dynamic) {
			throw new CBError("Operation attempted on invalid socket.");
		}
		listening = false;
		bound = false;
		__closed = true;
		__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
		__cbInstance = null;
	}

	/**
		 Initiates listening for TCP connections on the bound IP address and port.
		The listen() method returns immediately. Once you call listen(), the ServerSocket
		object dispatches a connect event whenever a connection attempt is made. The socket
		property of the ServerSocketConnectEvent event object references a Socket object
		representing the server-client connection.
		The backlog parameter specifies how many pending connections are queued while the
		connect events are processed by your application. If the queue is full, additional
		connections are denied without a connect event being dispatched. If the default
		value of zero is specified, then the system-maximum queue length is used. This
		length varies by platform and can be configured per computer. If the specified
		value exceeds the system-maximum length, then the system-maximum length is used
		instead. No means for discovering the actual backlog value is provided. (The
		system-maximum value is determined by the SOMAXCONN setting of the TCP network
		subsystem on the host computer.)
		@throws RangeError	There is insufficient data available to read.
		@throws IOError		This error occurs if the socket is not open or bound.
							This error also occurs if the call to listen() fails for any
							other reason.
	**/
	public function listen(backlog:Int = 0):Void {
		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			throw "ServerSocket can only be initiated in a CrossByte threaded instance";
		} else {
			if (__closed) {
				throw new IOError("Operation attempted on invalid socket.");
			}
			if (backlog < 0) {
				throw new RangeError("The supplied index is out of bounds.");
			} else if (backlog == 0) {
				backlog = 0x7FFFFFFF;
			}

			__serverSocket.listen(backlog);
			/* @:privateAccess
				__cbInstance.beginSocketPolling();
				@:privateAccess
				__cbInstance.registerSocket(__serverSocket); */
			listening = true;
			if (__hasListener) {
				__cbInstance.addEventListener(Event.TICK, this_onTick);
			}
		}
	}

	@:noCompletion private function __fromSocket(socket:sys.net.Socket):CBSocket {
		socket.setFastSend(true);
		socket.setBlocking(false);

		var cbSocket = new CBSocket();
		cbSocket.__socket = socket;
		cbSocket.__connected = true;
		cbSocket.__timestamp = Sys.time();

		cbSocket.__host = socket.peer().host.host;
		cbSocket.__port = socket.peer().port;

		cbSocket.__output = new ByteArray();
		cbSocket.__output.endian = cbSocket.__endian;

		cbSocket.__input = new ByteArray();
		cbSocket.__input.endian = cbSocket.__endian;

		cbSocket.__cbInstance = __cbInstance;

		Timer.delay(() -> {
			if (!cbSocket.__connected) {
				cbSocket.dispatchEvent(new Event(Event.CLOSE));
			}
		}, 0);

		socket.custom = cbSocket;

		@:privateAccess
		__cbInstance.registerSocket(socket);

		return cbSocket;
	}

	@:noCompletion private function this_onTick(e:TickEvent):Void {
		var sysSocket = null;

		try {
			sysSocket = __serverSocket.accept();
			var socket:CBSocket = __fromSocket(sysSocket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		} catch (e:Error) {
			close();
			dispatchEvent(new Event(Event.CLOSE));
		} catch (e:Dynamic) {
			// Do nothing.
		}

		/* if (sysSocket != null) {
			var socket:CBSocket = __fromSocket(sysSocket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		}*/
	}

	override public function addEventListener(type:String, listener:Dynamic->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);

		if (type == Event.CONNECT) {
			__hasListener = true;
			if (listening) {
				__cbInstance.addEventListener(TickEvent.TICK, this_onTick);
			}
		}
	}

	override public function removeEventListener(type:String, listener:Dynamic->Void):Void {
		super.removeEventListener(type, listener);

		if (type == Event.CONNECT) {
			__hasListener = false;
			if (__cbInstance != null) {
				__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
			}
		}
	}

	private function get_isSupported():Bool {
		return true;
	}
}
