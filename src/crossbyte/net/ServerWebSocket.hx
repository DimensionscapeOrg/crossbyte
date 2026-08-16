package crossbyte.net;

import crossbyte._internal.websocket.FlexSocket;
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.net.WebSocket;
import haxe.io.Eof;
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
#if (java || jvm)
// TLS is stubbed on the jvm target (see FlexSocket / JvmSsl).
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslCertificate as Certificate;
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslKey as Key;
#else
import sys.ssl.Certificate;
import sys.ssl.Key;
#end

/**
 * ...
 * @author Christopher Speciale
 */
class ServerWebSocket extends ServerSocket {
	// Note: use chrome://flags/#allow-insecure-localhost to allow local host certificates in chrome!

	/**
		The Certificate Authoritiy responsible for signing the SSL Certificate for a Secure WebSocket Server.
	**/
	public var certAuthority(default, set):Certificate;

	/**
		Indicates whether or not ServerSocket features are supported in the run-time environment.
	**/
	public static var isSupported(default, null):Bool = #if html5 false #else true #end;

	/**
		Determines whether or not the Websocket Server should verify the Certificate.
	**/
	public var verifyCert(default, set):Null<Bool>;

	/**
		Applied to every session this server accepts as its
		`WebSocket.maxOutputBufferSize`, or `0` to leave sessions unbounded.

		Set here rather than per session because an application never sees an
		accepted socket before the handshake response is written to it, so a
		per-connection limit is only reachable from the server that accepted
		it. Existing sessions are unaffected; assign before `listen()`.

		Size it to the largest message this server legitimately sends, with
		headroom.
	**/
	public var maxOutputBufferSize:Int = 0;

	@:noCompletion private var __webServerSocket:FlexSocket;
	@:noCompletion private var __isSecure:Bool;

	@:noCompletion private function set_verifyCert(value:Bool):Bool {
		if (__isSecure) {
			return verifyCert = __webServerSocket.verifyCert = value;
		}

		return verifyCert = value;
	}

	@:noCompletion private function set_certAuthority(value:Certificate):Certificate {
		if (__isSecure) {
			__webServerSocket.setCA(value);
		}

		return certAuthority = value;
	}

	/**
		Client connections that have completed their handshake and not yet
		closed. Maintained so `drain()` can shut them down deliberately.
	**/
	public var clientCount(get, never):Int;

	private function get_clientCount():Int {
		return __clients.length;
	}

	/**
		Whether `drain()` has been called and shutdown is in progress.
	**/
	public var draining(default, null):Bool = false;

	@:noCompletion private var __clients:Array<WebSocket> = [];

	/**
		Creates a ServerWebSocket.

		@param secure When `true`, the server terminates TLS (`wss://`) and
			requires a certificate via `cert` before listening.
		@throws SecurityError This error occurs if the calling content is
			running outside the AIR application security sandbox.
	**/
	public function new(secure:Bool = false) {
		__isSecure = secure;
		super();

		// The server dispatches CONNECT to itself once a handshake
		// completes, so it can observe its own connections without the
		// WebSocket needing to know about a registry.
		addEventListener(ServerSocketConnectEvent.CONNECT, __trackClient);
	}

	@:noCompletion private function __trackClient(e:ServerSocketConnectEvent):Void {
		var client:WebSocket = cast e.socket;
		if (client == null || __clients.indexOf(client) >= 0) {
			return;
		}

		if (maxOutputBufferSize > 0) {
			client.maxOutputBufferSize = maxOutputBufferSize;
		}

		__clients.push(client);
		client.addEventListener(Event.CLOSE, function(_) {
			__clients.remove(client);
		});
	}

	override function __init():Void {
		__webServerSocket = new FlexSocket(__isSecure);

		if (__isSecure) {
			verifyCert = false;
		}

		__webServerSocket.setBlocking(false);
		__webServerSocket.setFastSend(true);
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
	override public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (localPort > 65535 || localPort < 0) {
			throw new RangeError("Invalid socket port number specified.");
		}
		try {
			this.localAddress = localAddress;
			__webServerSocket.bind(localAddress, localPort);

			// Port 0 asks the operating system to choose. Report the port it
			// actually assigned, matching ServerSocket: otherwise localPort
			// stays 0 and a caller has no way to learn where to connect.
			this.localPort = localPort == 0 ? __webServerSocket.host().port : localPort;
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
		Stops accepting new connections while leaving established sessions
		open and usable.

		The listening socket is released, so a successor process can bind
		the port immediately during a deploy. Unlike `close()`, no `close`
		event is dispatched and the server is not marked closed. Safe to
		call more than once.
	**/
	override public function stopAccepting():Void {
		if (!listening && !bound) {
			return;
		}

		if (__cbInstance != null) {
			__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
		}

		try {
			__webServerSocket.close();
		} catch (_:Dynamic) {
			// Best-effort: the listener may already be gone.
		}

		listening = false;
		bound = false;
		__listenerReleased = true;
	}

	/**
		Gracefully shuts the server down.

		A WebSocket session is long-lived by design, so unlike an HTTP
		request there is nothing to "finish". Draining therefore means
		telling clients to go away: every session is sent a close frame
		with `closeCode`, and sessions still open when `timeoutSeconds`
		elapses are dropped.

		Sending a close frame rather than severing the socket is what lets
		a client distinguish an orderly shutdown from a network failure,
		and so reconnect sensibly instead of treating it as an error.

		Pairs with `ProcessLifecycle`:

		```haxe
		ProcessLifecycle.onShutdown(() -> server.drain());
		ProcessLifecycle.installDefaultHandlers();
		```

		@param timeoutSeconds How long to wait for clients to acknowledge
			before dropping them. Values at or below zero close at once.
		@param onComplete Invoked once shutdown finishes, on the runtime
			thread.
		@param closeCode WebSocket close code sent to clients. Defaults to
			1001 ("going away"), the code meaning a server is shutting
			down.
	**/
	public function drain(timeoutSeconds:Float = 30.0, ?onComplete:Void->Void, closeCode:Int = 1001):Void {
		if (draining) {
			return;
		}
		draining = true;

		stopAccepting();

		var pending:Array<WebSocket> = __clients.copy();
		for (client in pending) {
			try {
				client.closeWith(closeCode, "server shutting down");
			} catch (_:Dynamic) {
				// A session that is already gone needs no close frame.
			}
		}

		if (__clients.length == 0 || timeoutSeconds <= 0 || __cbInstance == null) {
			__finishDrain(onComplete);
			return;
		}

		var deadline:Float = Sys.time() + timeoutSeconds;
		var runtime = __cbInstance;
		var onTick:TickEvent->Void = null;

		onTick = function(_:TickEvent):Void {
			if (__clients.length > 0 && Sys.time() < deadline) {
				return;
			}

			runtime.removeEventListener(TickEvent.TICK, onTick);
			__finishDrain(onComplete);
		};
		runtime.addEventListener(TickEvent.TICK, onTick);
	}

	@:noCompletion private function __finishDrain(onComplete:Void->Void):Void {
		for (client in __clients.copy()) {
			try {
				client.close();
			} catch (_:Dynamic) {}
		}
		__clients = [];

		try {
			close();
		} catch (_:Dynamic) {}

		if (onComplete != null) {
			onComplete();
		}
	}

	/**
		Closes the socket and stops listening for connections.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
	**/
	override public function close():Void {
		// stopAccepting() may already have released the listener as the
		// first half of a graceful shutdown; closing again is not an error.
		if (__listenerReleased) {
			listening = false;
			bound = false;
			__closed = true;
			if (__cbInstance != null) {
				__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
				__cbInstance = null;
			}
			return;
		}

		try {
			__webServerSocket.close();
		} catch (e:Dynamic) {
			throw new CBError("Operation attempted on invalid socket.");
		}
		listening = false;
		bound = false;
		__closed = true;
		if (__cbInstance != null) {
			__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
			__cbInstance = null;
		}
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
	override public function listen(backlog:Int = 0):Void {
		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			throw "ServerWebSocket can only be initiated in a CrossByte threaded instance";
		}
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		if (backlog < 0) {
			throw new RangeError("The supplied index is out of bounds.");
		} else if (backlog == 0) {
			backlog = 0x7FFFFFF;
		}

		__webServerSocket.listen(backlog);
		listening = true;
		if (__hasListener) {
			__cbInstance.addEventListener(TickEvent.TICK, this_onTick);
		}
	}

	@:noCompletion private function __fromSockettoWebsocket(socket:FlexSocket):WebSocket {
		socket.setFastSend(true);
		socket.setBlocking(false);

		var webSocket:WebSocket = WebSocket.toWebSocket(socket, this);
		/*var cbSocket = new WebSocket(); 
			cbSocket.__socket = socket;
			cbSocket.__connected = true;
			cbSocket.__timestamp = Sys.time();

			cbSocket.__host = socket.peer().host.host;
			cbSocket.__port = socket.peer().port;

			cbSocket.__output = new ByteArray();
			cbSocket.__output.endian = cbSocket.__endian;

			cbSocket.__input = new ByteArray();
			cbSocket.__input.endian = cbSocket.__endian; */

		// CrossByte.current().addEventListener(TickEvent.TICK, cbSocket.this_onTick);

		return webSocket;
	}

	@:noCompletion override private function this_onTick(e:TickEvent):Void {
		// Extracted from a single method with a local assigned inside try/catch and
		// used afterwards: that shape mis-compiles (VerifyError) on the jvm target.
		var socket:FlexSocket = __acceptPending();
		if (socket != null) {
			__fromSockettoWebsocket(socket);
		}
	}

	@:noCompletion private function __acceptPending():FlexSocket {
		try {
			return __webServerSocket.accept();
		} catch (e:Error) {
			#if (java || jvm)
			// The enum switch-in-catch mis-compiles (VerifyError: bad type on
			// operand stack) on the jvm target; match the transient Blocked case
			// by string instead. Error.Blocked -> "Blocked", Custom(Blocked) ->
			// "Custom(Blocked)"; both contain "Blocked".
			if (Std.string(e).indexOf("Blocked") < 0) {
				close();
				dispatchEvent(new Event(Event.CLOSE));
			}
			#else
			switch (e) {
				case Error.Blocked:
				case Error.Custom(Error.Blocked):
				default:
					close();
					dispatchEvent(new Event(Event.CLOSE));
			}
			#end
		} catch (e:Dynamic) {
			// Do nothing.
		}
		return null;
	}

	/**
		The certificate for a Secure WebSocket Server.
	**/
	public var cert(default, set):{certificate:Certificate, key:Key};

	@:noCompletion private function set_cert(value:{certificate:Certificate, key:Key}):{certificate:Certificate, key:Key} {
		if (__isSecure) {
			__webServerSocket.setCertificate(value.certificate, value.key);
		}

		return cert = value;
	}
}
