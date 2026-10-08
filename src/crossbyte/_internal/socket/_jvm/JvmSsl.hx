package crossbyte._internal.socket._jvm;

// Only built for java/jvm: everything here is javax.net.ssl and java.security,
// and no other target references this module.
#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte._internal.socket._jvm.JvmSslExterns.Certificate as JCertificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManager;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManagerFactory;
import crossbyte._internal.socket._jvm.JvmSslExterns.JArrayList;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyStore;
import crossbyte._internal.socket._jvm.JvmSslExterns.PrivateKey;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLContext;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLEngine;
import crossbyte._internal.socket._jvm.JvmSslExterns.TrustManager;
import crossbyte._internal.socket._jvm.JvmSslExterns.TrustManagerFactory;
import java.nio.ByteBuffer;

/**
	A TLS socket for the jvm target, over `SSLEngine`.

	Java ships two TLS APIs and only one of them fits here. `SSLSocket` is
	blocking, which no event-driven server can use; `SSLEngine` is a
	transport-agnostic state machine fed byte buffers, which is the shape a
	poll-driven runtime wants. This drives the engine over the same NIO channel
	the plain socket already uses, so the registry, the accept loop and the read
	path above it are unchanged.

	`handshake()` reports an unfinished handshake by throwing `Blocked`, which is
	what `ServerSocket.__pumpHandshakes` already catches to mean "come back next
	tick". Its pending set and deadline therefore work here unaltered.
**/
@:access(sys.net.Socket)
class JvmSslSocket extends sys.net.Socket {
	public static var DEFAULT_CA:Null<JvmSslCertificate>;
	public static var DEFAULT_VERIFY_CERT:Null<Bool>;

	public var verifyCert:Null<Bool>;

	/**
		This socket's own `verifyCert`, or `DEFAULT_VERIFY_CERT` when it has
		none, the order the native socket uses, so turning verification off
		for every socket, as a development setup does, reaches the jvm too.
	**/
	@:noCompletion private inline function __verifies():Null<Bool> {
		return verifyCert != null ? verifyCert : DEFAULT_VERIFY_CERT;
	}

	// Configured on the listener before bind(); copied to each connection.
	@:noCompletion private var __certificate:JvmSslCertificate;
	@:noCompletion private var __key:JvmSslKey;
	@:noCompletion private var __ca:JvmSslCertificate;
	@:noCompletion private var __hostname:String;
	// The port connect() dialled; the engine is told it with the host.
	@:noCompletion private var __peerPort:Int = -1;
	@:noCompletion private var __alpn:Array<String>;
	@:noCompletion private var __sni:Array<crossbyte._internal.socket._jvm.JvmSniKeyManager.SniEntry>;

	// The context this connection's engine is made from: for an accepted
	// connection, its listener's.
	@:noCompletion private var __context:SSLContext;
	// A listener's context, made on its first accept and handed to every
	// connection after, with what it was made from; see __serverContext.
	@:noCompletion private var __listenerContext:SSLContext;
	@:noCompletion private var __listenerVerifies:Null<Bool>;
	@:noCompletion private var __listenerDefaultCA:JvmSslCertificate;

	/**
		How many handshakes after the first a server connection carries through
		for its peer before refusing the next. Each is a full handshake (a
		private-key operation) on a connection already admitted, so a peer
		free to ask without limit has the server's CPU for the price of a
		record. Node allows three.
	**/
	@:noCompletion private static inline var RENEGOTIATIONS:Int = 3;

	// What __unwrapRecord answers besides a count of plaintext bytes.
	@:noCompletion private static inline var NOTHING:Int = -1;
	@:noCompletion private static inline var TOO_SMALL:Int = -2;
	@:noCompletion private static inline var CLOSED:Int = -3;
	@:noCompletion private static inline var UNDERFLOW:Int = -4;

	// Per-connection engine state.
	@:noCompletion private var __engine:SSLEngine;

	// The engine's buffers, each held only while it holds something (see
	// JvmSslBuffers), and null otherwise: ciphertext read and not yet
	// decrypted (a record that has arrived in part, or what a full caller's
	// buffer left), in write mode; plaintext decrypted and not yet taken, in
	// read mode; ciphertext made and not yet sent, in read mode.
	@:noCompletion private var __netIn:ByteBuffer;
	@:noCompletion private var __appIn:ByteBuffer;
	@:noCompletion private var __netOut:ByteBuffer;

	// Making records and sending them is one step: they have to reach the
	// wire in the order the engine made them, and a read that answers the
	// peer's handshake makes records too, on another thread than the
	// writer's for the HTTP/2 client's reader.
	@:noCompletion private var __outbound:sys.thread.Mutex;

	// What a pooled buffer holds: room for a whole record, either way.
	@:noCompletion private var __bufferSize:Int = 0;

	@:noCompletion private var __handshaken:Bool = false;
	// The peer has closed its side, by close_notify or by closing the
	// connection; and whether a read has reported that yet.
	@:noCompletion private var __inboundDone:Bool = false;
	@:noCompletion private var __eofTold:Bool = false;
	// A failure met after plaintext was already on its way to the caller:
	// thrown by the next read, once that plaintext has been handed over.
	@:noCompletion private var __deferred:Dynamic = null;
	// When a blocking handshake has to be done by, from haxe.Timer.stamp();
	// 0 when none is running or the socket has no timeout.
	@:noCompletion private var __deadline:Float = 0.0;
	// A handshake after the first is under way; how many the peer has begun.
	@:noCompletion private var __renegotiating:Bool = false;
	@:noCompletion private var __renegotiations:Int = 0;
	// A failure's alert has been sent, so close() lingers; see there.
	@:noCompletion private var __refused:Bool = false;

	@:noCompletion private static var __EMPTY:ByteBuffer = ByteBuffer.allocate(0);

	public function new() {
		super();
	}

	// -------------------------------------------------------- configuration

	public function setCertificate(cert:JvmSslCertificate, key:JvmSslKey):Void {
		__certificate = cert;
		__key = key;
		__listenerContext = null;
	}

	public function setCA(cert:JvmSslCertificate):Void {
		__ca = cert;
		__listenerContext = null;
	}

	public function setHostname(name:String):Void {
		__hostname = name;
	}

	/**
		Offers these protocol names during the handshake.

		Built into the JDK, unlike the cpp path, which needs a native extension
		to reach mbedTLS's ALPN. `null` or an empty list disables it.
	**/
	public function setALPN(protocols:Null<Array<String>>):Void {
		__alpn = (protocols != null && protocols.length > 0) ? protocols : null;
	}

	/** The protocol agreed on, or null when none was. **/
	public function getALPN():Null<String> {
		if (__engine == null) {
			return null;
		}

		// The JDK reports "no agreement" as an empty string and "not yet
		// negotiated" as null; both mean there is nothing to report.
		var negotiated = try {
			__engine.getApplicationProtocol();
		} catch (e:Dynamic) {
			null;
		}

		return (negotiated == null || negotiated == "") ? null : negotiated;
	}

	/**
		Adds a certificate chosen by the hostname the client asks for.

		Order is preference: the first entry whose predicate matches wins, and a
		name none of them claims falls back to the certificate installed with
		`setCertificate`.
	**/
	public function addSNICertificate(cbServernameMatch:String->Bool, cert:JvmSslCertificate, key:JvmSslKey):Void {
		if (cbServernameMatch == null || cert == null || key == null) {
			throw "addSNICertificate needs a predicate, a certificate and a key.";
		}

		if (__sni == null) {
			__sni = [];
		}

		__sni.push({matches: cbServernameMatch, chain: JvmSniKeyManager.chainOf(cert), key: key.native});
		__listenerContext = null;
	}

	public function peerCertificate():JvmSslCertificate {
		if (__engine == null) {
			return null;
		}

		return try {
			var chain = __engine.getSession().getPeerCertificates();
			chain.length > 0 ? new JvmSslCertificate(chain[0], chain) : null;
		} catch (e:Dynamic) {
			null;
		}
	}

	// ------------------------------------------------------------ lifecycle

	/**
		Accepts a connection and gives it a server-mode engine.

		The certificate lives on the listener, and so does the context made
		from it: every accepted connection's engine comes from the one context,
		rather than each building its own (a key store, key and trust managers
		and a random source per connection, some 9 ms of CPU). A context is
		also where the sessions a server issued are kept, so a client can
		resume one. Nothing is negotiated here; the handshake is driven later,
		by the pump.
	**/
	override public function accept():sys.net.Socket {
		var incoming:java.nio.channels.SocketChannel = try {
			this.serverChannel.accept();
		} catch (e:Dynamic) {
			throw haxe.io.Error.Custom(e);
		}

		if (incoming == null) {
			throw haxe.io.Error.Blocked;
		}

		incoming.configureBlocking(false);

		var accepted = Type.createEmptyInstance(JvmSslSocket);
		accepted.__init(incoming);
		accepted.__certificate = __certificate;
		accepted.__key = __key;
		accepted.__ca = __ca;
		accepted.__alpn = __alpn;
		accepted.__sni = __sni;
		accepted.verifyCert = verifyCert;
		accepted.__context = __serverContext();
		accepted.__startEngine(false);
		return accepted;
	}

	/**
		The context a listener hands every connection it accepts: made on the
		first accept and kept, and made again only if what it was made from has
		changed. `ServerSocket` refuses new material once it is bound, so in
		practice that is never.
	**/
	@:noCompletion private function __serverContext():SSLContext {
		var verifies:Null<Bool> = __verifies();
		if (__listenerContext == null || __listenerVerifies != verifies || __listenerDefaultCA != DEFAULT_CA) {
			__listenerContext = __buildContext();
			__listenerVerifies = verifies;
			__listenerDefaultCA = DEFAULT_CA;
		}
		return __listenerContext;
	}

	/**
		Connects and terminates TLS as the client.

		`Http` reaches here for every https request: `FlexSocket(secure)` builds
		one of these and calls connect.

		The channel stays blocking, as it is for any client connect, so the
		handshake below runs to completion here rather than being driven by a
		pump. It is bounded by the socket's timeout as a whole, not per read:
		each read waits at most what is left of it.

		Only `Blocked` (a record that has arrived in part) sends it round
		again, and the next read then waits for the rest. Anything else is the
		answer and is thrown as it came: a timeout, a reset, a certificate
		refused.

		By default the certificate is verified against the JDK's default trust
		store and the hostname is checked against the certificate. Both matter:
		a client that skips the second accepts any valid certificate for any
		host, which is most of the value of TLS gone.

		`verifyCert = false` turns both off, for the self-signed development
		server the setting exists for. It has to be asked for: unset verifies.

		A socket made non-blocking before it connects is left to finish the
		handshake the way every other target does, through `handshake()`
		calls that report `Blocked` until it is done. Completing it here
		would hold the calling thread for the whole exchange, and when that
		thread is a runtime's and the server on the far side runs on the same
		runtime, the server could never answer.
	**/
	override public function connect(host:sys.net.Host, port:Int):Void {
		super.connect(host, port);

		if (__hostname == null) {
			__hostname = host.host;
		}
		__peerPort = port;

		__startEngine(true);

		if (!__blocking) {
			return;
		}

		__deadline = __timeout > 0 ? haxe.Timer.stamp() + __timeout : 0.0;

		try {
			while (!__handshaken) {
				try {
					handshake();
				} catch (e:haxe.io.Error) {
					switch (e) {
						case Blocked:
						// A record that arrived in part; the next read waits
						// for the rest, within what is left of the deadline.
						case Custom(detail) if (detail == "Timeout"):
							throw haxe.io.Error.Custom("Timeout: the TLS handshake with " + __hostname + ":" + port + " had no answer within "
								+ __timeout + " s");
						default:
							throw e;
					}
				}
			}
		} catch (e:Dynamic) {
			__deadline = 0.0;
			throw e;
		}

		__deadline = 0.0;
	}

	/**
		Advances the handshake, or reports that it needs more from the peer.

		@throws haxe.io.Error.Blocked The handshake is unfinished and the socket
		has nothing further to read, or could not write. Call again.
	**/
	public function handshake():Void {
		if (__engine == null) {
			throw "This socket has no TLS engine; set a certificate before listening.";
		}

		if (__handshaken) {
			return;
		}

		// A non-blocking connect returns while the connection is still being
		// made, and until it is up there is no one to say anything to.
		var connecting:java.nio.channels.SocketChannel = cast this.channel;
		if (connecting.isConnectionPending()) {
			var connected:Bool = try {
				connecting.finishConnect();
			} catch (e:Dynamic) {
				throw haxe.io.Error.Custom(e);
			}
			if (!connected) {
				throw haxe.io.Error.Blocked;
			}
			__onConnected();
		}

		try {
			__advance();
		} catch (e:Dynamic) {
			// A handshake that failed says why before the connection goes: the
			// engine has an alert waiting for exactly that. Closed without
			// it, the peer would report a network fault ("Remote host terminated
			// the handshake") in place of the certificate it was refused for.
			if (!crossbyte._internal.socket.BlockedError.isBlocked(e) && !Std.isOfType(e, haxe.io.Eof)) {
				__alert();
			}
			throw e;
		}

		__handshaken = true;
	}

	/**
		Steps the handshake as far as it goes without waiting on the peer or on
		the socket.

		@throws haxe.io.Error.Blocked It needs more from the peer, or the socket
		would not take what it had to send.
	**/
	@:noCompletion private function __advance():Void {
		// Anything a previous pass made but could not send goes first: the
		// peer is waiting on it, and records made after it would reach the
		// wire before it.
		if (!__flush()) {
			throw haxe.io.Error.Blocked;
		}

		while (true) {
			switch (__engine.getHandshakeStatus().name()) {
				case "NEED_TASK":
					__runTasks();

				case "NEED_WRAP":
					if (!__wrapHandshake()) {
						throw haxe.io.Error.Blocked;
					}

				case "NEED_UNWRAP", "NEED_UNWRAP_AGAIN":
					// Into the held plaintext: a handshake record decrypts to
					// nothing, and application data arriving with the last
					// flight is kept for the first read.
					var produced:Int = __unwrapRecord(null, true, true);
					if (produced == NOTHING) {
						throw haxe.io.Error.Blocked;
					}
					if (produced == CLOSED) {
						throw new haxe.io.Eof();
					}

				case "FINISHED", "NOT_HANDSHAKING":
					// An engine that has closed is not handshaking either.
					if (__engine.isOutboundDone() || __engine.isInboundDone()) {
						throw new haxe.io.Eof();
					}
					return;

				case other:
					throw "Unexpected TLS handshake status: " + other;
			}
		}
	}

	// --------------------------------------------------------------- engine

	@:noCompletion private function __startEngine(clientMode:Bool):Void {
		// A client's engine is told whom it is talking to. The JDK checks the
		// certificate against the SNI name first and falls back to the peer's
		// host, and an engine made without one has none: on the JDKs that fall
		// back, a certificate that did not name the SNI host, or a connection
		// by IP address, which sends no SNI, would be refused as "Hostname or
		// IP address is undefined", the right connection along with the wrong
		// one, for a reason naming neither.
		//
		// The host and port are also what the context's session cache is
		// keyed by, so a client's next connection to them can resume.
		var context:SSLContext = __context;
		if (context == null) {
			context = clientMode ? JvmSslContexts.client(this) : __buildContext();
			__context = context;
		}
		__engine = clientMode && __hostname != null
			? context.createSSLEngine(__hostname, __peerPort)
			: context.createSSLEngine();
		__engine.setUseClientMode(clientMode);

		// A trust store on its own only says which authorities are acceptable;
		// without this the client is never asked for a certificate and the
		// store is never consulted. `verifyCert` is what requireClientCertificate
		// sets, so the two travel together.
		if (!clientMode && __verifies() == true) {
			__engine.setNeedClientAuth(true);
		}

		if (clientMode && __hostname != null) {
			var parameters = __engine.getSSLParameters();

			// The name goes out as SNI so the server knows which of its hosts
			// is being asked for, and the same name is then checked against the
			// certificate that comes back.
			// Not for an address, which RFC 6066 forbids in SNI: the JDK
			// refuses an IPv6 literal as a host name outright, before a byte
			// is sent.
			if (!crossbyte._internal.net.IPv6.isNumericAddress(__hostname)) {
				var names = new JArrayList<JvmSslExterns.SNIServerName>();
				names.add(cast new JvmSslExterns.SNIHostName(__hostname));
				parameters.setServerNames(cast names);
			}

			// Only the check is optional. Sending the name is how a virtual
			// host picks a certificate at all, so a client that is not
			// verifying still has to ask for the right one; dropping SNI here
			// would quietly get it served the wrong host.
			if (__verifies() != false) {
				parameters.setEndpointIdentificationAlgorithm("HTTPS");
			}

			__engine.setSSLParameters(parameters);
		}

		if (__alpn != null) {
			var names:java.NativeArray<String> = new java.NativeArray(__alpn.length);
			for (i in 0...__alpn.length) {
				names[i] = __alpn[i];
			}

			var parameters = __engine.getSSLParameters();
			parameters.setApplicationProtocols(names);
			__engine.setSSLParameters(parameters);
		}

		// Nothing is allocated for the engine here: its buffers come from the
		// thread's pool as reads and writes need them (see JvmSslBuffers).
		var session = __engine.getSession();
		var packet:Int = session.getPacketBufferSize();
		var application:Int = session.getApplicationBufferSize();
		__bufferSize = packet > application ? packet : application;
		__outbound = new sys.thread.Mutex();

		this.input = new JvmSslInput(this);
		this.output = new JvmSslOutput(this);

		__engine.beginHandshake();
	}

	@:noCompletion private function __buildContext():SSLContext {
		var blank:java.NativeArray<java.StdTypes.Char16> = new java.NativeArray(0);
		var managers:Null<java.NativeArray<KeyManager>> = null;

		if (__certificate != null && __key != null) {
			var store = KeyStore.getInstance(KeyStore.getDefaultType());
			store.load(null, null);

			// The whole chain: the leaf and whatever intermediates came with
			// it, which is what goes to the peer.
			store.setKeyEntry("crossbyte", cast __key.native, blank, __certificate.chain);

			if (__sni != null && __sni.length > 0) {
				// One key manager of our own, rather than the default one built
				// from the store: choosing per requested hostname is something
				// only a key manager can do.
				var picker = new crossbyte._internal.socket._jvm.JvmSniKeyManager({
					matches: function(_) return true,
					chain: JvmSniKeyManager.chainOf(__certificate),
					key: __key.native
				}, __sni);

				managers = new java.NativeArray(1);
				managers[0] = cast picker;
			} else {
				var factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
				factory.init(store, blank);
				managers = factory.getKeyManagers();
			}
		}

		var trust:Null<java.NativeArray<TrustManager>> = null;
		var ca = __ca != null ? __ca : DEFAULT_CA;

		if (__verifies() == false) {
			// Asked for explicitly, and it means the peer is no longer
			// authenticated: the traffic is still encrypted, but anything able
			// to sit in the middle can present its own certificate. Unset (the
			// default) verifies.
			var accepting:java.NativeArray<TrustManager> = new java.NativeArray(1);
			accepting[0] = cast new crossbyte._internal.socket._jvm.JvmTrustAll();
			trust = accepting;
			ca = null;
		}

		if (ca != null) {
			// Every authority of a bundle, not only its first.
			var store = KeyStore.getInstance(KeyStore.getDefaultType());
			store.load(null, null);
			for (i in 0...ca.chain.length) {
				store.setCertificateEntry("ca" + i, ca.chain[i]);
			}
			var factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
			factory.init(store);
			trust = factory.getTrustManagers();
		}

		var context = SSLContext.getInstance("TLS");
		context.init(managers, trust, null);
		return context;
	}

	// -------------------------------------------------------------- records

	@:noCompletion private function __runTasks():Void {
		var task = __engine.getDelegatedTask();
		while (task != null) {
			task.run();
			task = __engine.getDelegatedTask();
		}
	}

	/**
		Sends what was made and not yet sent.

		@return Whether nothing is left waiting for the socket.
	**/
	@:noCompletion private function __flush():Bool {
		if (__netOut == null) {
			return true;
		}

		__outbound.acquire();
		var sent:Bool = try {
			__flushLocked();
		} catch (e:Dynamic) {
			__outbound.release();
			throw e;
		}
		__outbound.release();
		return sent;
	}

	/** `__flush`, for a caller holding `__outbound`. **/
	@:noCompletion private function __flushLocked():Bool {
		var out = __netOut;
		if (out == null) {
			return true;
		}

		var socket:java.nio.channels.SocketChannel = cast this.channel;
		while (out.hasRemaining()) {
			var written:Int = try {
				socket.write(out);
			} catch (e:Dynamic) {
				throw haxe.io.Error.Custom(e);
			}
			if (written <= 0) {
				return false;
			}
		}

		__netOut = null;
		JvmSslBuffers.give(out, __bufferSize);
		return true;
	}

	/**
		Makes records from `source` and sends them, for a caller holding
		`__outbound` with nothing left over from before. What the socket will
		not take yet stays in `__netOut`, to go first next time.
	**/
	@:noCompletion private function __wrapLocked(source:ByteBuffer):SSLEngineResult {
		var out = JvmSslBuffers.take(__bufferSize);
		var result:SSLEngineResult = null;

		while (true) {
			result = try {
				__engine.wrap(source, out);
			} catch (e:Dynamic) {
				JvmSslBuffers.give(out, __bufferSize);
				throw e;
			}
			if (result.getStatus().name() != "BUFFER_OVERFLOW") {
				break;
			}
			// A record larger than the session said: made again with room.
			JvmSslBuffers.give(out, __bufferSize);
			out = ByteBuffer.allocate(out.capacity() * 2);
		}

		out.flip();
		if (out.hasRemaining()) {
			__netOut = out;
			__flushLocked();
		} else {
			JvmSslBuffers.give(out, __bufferSize);
		}
		return result;
	}

	/**
		Makes and sends what the handshake has to say.

		@return Whether all of it reached the socket.
	**/
	@:noCompletion private function __wrapHandshake():Bool {
		__outbound.acquire();
		var sent:Bool = try {
			if (!__flushLocked()) {
				false;
			} else {
				var result = __wrapLocked(__EMPTY);
				if (result.getStatus().name() == "CLOSED" && result.bytesProduced() == 0) {
					throw new haxe.io.Eof();
				}
				__netOut == null;
			}
		} catch (e:Dynamic) {
			__outbound.release();
			throw e;
		}
		__outbound.release();
		return sent;
	}

	/**
		Sends what the engine has to say about a failure (the alert naming it)
		ahead of the close. Best effort: it goes if the socket takes it now.
	**/
	@:noCompletion private function __alert():Void {
		if (__engine == null || __outbound == null) {
			return;
		}

		__outbound.acquire();
		try {
			if (__flushLocked()) {
				var rounds:Int = 0;
				while (rounds++ < 4) {
					var result = __wrapLocked(__EMPTY);
					if (result.bytesProduced() == 0 || __netOut != null) {
						break;
					}
				}
			}
		} catch (_:Dynamic) {}
		__refused = true;
		__outbound.release();
	}

	/**
		Does what the engine asks for once a record is through: runs its tasks
		and sends what it has to say. After the first handshake that is a
		handshake the peer has begun again, or a TLS 1.3 key update to answer.

		Without this, once the first handshake was over a TLS 1.2
		renegotiation (a server asking for a client certificate part way
		through, a client asking for new keys) would wait for ever on a
		reply that was never made, and neither side would be told.
	**/
	@:noCompletion private function __service(result:SSLEngineResult):Void {
		var status:String = result.getHandshakeStatus().name();

		if (!__renegotiating && (status == "NOT_HANDSHAKING" || status == "FINISHED")) {
			// The steady state: nothing to do, and nothing asked of the engine.
			return;
		}

		if (__handshaken && !__renegotiating && status != "NOT_HANDSHAKING" && status != "FINISHED") {
			__renegotiating = true;
			__begunAgain();
		}

		while (true) {
			switch (__engine.getHandshakeStatus().name()) {
				case "NEED_TASK":
					__runTasks();

				case "NEED_WRAP":
					if (!__wrapHandshake()) {
						// The rest goes with the next read or write.
						return;
					}

				case "NOT_HANDSHAKING":
					__renegotiating = false;
					return;

				default:
					// Waiting on the peer, whose next records carry it on.
					return;
			}
		}
	}

	/**
		A handshake after the first has begun. Carried through for a client,
		whose server asked; for a server, only `RENEGOTIATIONS` times. A TLS 1.3
		key update is not a handshake and is never counted.
	**/
	@:noCompletion private function __begunAgain():Void {
		if (__engine.getUseClientMode()) {
			return;
		}

		var protocol:String = try {
			__engine.getSession().getProtocol();
		} catch (_:Dynamic) {
			null;
		}
		if (protocol == "TLSv1.3") {
			return;
		}

		if (++__renegotiations > RENEGOTIATIONS) {
			// Told rather than left waiting: the engine closes, and its
			// close_notify goes if the socket takes it.
			try {
				__engine.closeOutbound();
				__wrapHandshake();
			} catch (_:Dynamic) {}
			throw haxe.io.Error.Custom("TLS renegotiation refused: the peer asked for more than " + RENEGOTIATIONS);
		}
	}

	/**
		Decrypts one record, into `into` (the caller's own buffer) or, when
		that is null, into the held plaintext.

		What is held is tried before the socket is read. A single read
		routinely carries several records (a TLS 1.3 server sends its whole
		flight in one go), and going back to the socket before those are
		decoded waits for bytes the peer has already sent, or for bytes it will
		only send once answered.

		@param mayWait For a blocking socket, whether to wait for the peer, up
		to its timeout. A non-blocking socket never waits.
		@param mayRead Whether to read the socket at all, rather than only
		decode what is held.
		@return Plaintext bytes produced (0 for a record that carried none,
		as a handshake message or a session ticket does), or `NOTHING` when no
		whole record can be had without waiting, `TOO_SMALL` when `into` has
		no room for this record's plaintext, or `CLOSED` when the peer has
		closed.
	**/
	@:noCompletion private function __unwrapRecord(into:Null<ByteBuffer>, mayWait:Bool, mayRead:Bool):Int {
		var answer:Int = NOTHING;

		while (true) {
			if (__inboundDone) {
				answer = CLOSED;
				break;
			}

			if (__netIn != null && __netIn.position() > 0) {
				var produced:Int = try {
					__unwrapHeld(into);
				} catch (e:Dynamic) {
					__settleIn();
					throw e;
				}
				if (produced != UNDERFLOW) {
					answer = produced;
					break;
				}
			}

			if (!mayRead) {
				break;
			}

			var read:Int = try {
				__fill(mayWait);
			} catch (e:Dynamic) {
				__settleIn();
				throw e;
			}
			if (read < 0) {
				// Closed under the stream, without close_notify: reported the
				// same way, as the end of it.
				__inboundDone = true;
				answer = CLOSED;
				break;
			}
			if (read == 0) {
				break;
			}
		}

		__settleIn();
		return answer;
	}

	/** Gives back the ciphertext buffer once it holds nothing. **/
	@:noCompletion private inline function __settleIn():Void {
		var input = __netIn;
		if (input != null && input.position() == 0) {
			__netIn = null;
			JvmSslBuffers.give(input, __bufferSize);
		}
	}

	/**
		Reads more ciphertext onto what is held.

		@return Bytes read; 0 when none could be had without waiting; -1 at the
		end of the stream.
	**/
	@:noCompletion private function __fill(mayWait:Bool):Int {
		var socket:java.nio.channels.SocketChannel = cast this.channel;

		if (socket.isBlocking()) {
			if (!mayWait) {
				return 0;
			}

			// A blocking read on the channel has no timeout of its own, so without
			// this an https response that stopped arriving would be waited for for
			// ever. In a handshake the wait is what is left of the whole, so a
			// peer that answers a byte at a time cannot stretch it.
			var wait:Float = __timeout;
			if (__deadline > 0) {
				var left:Float = __deadline - haxe.Timer.stamp();
				if (left <= 0) {
					throw haxe.io.Error.Custom("Timeout");
				}
				if (left < wait) {
					wait = left;
				}
			}
			sys.net.Socket.__awaitReadable(socket, wait);
		}

		if (__netIn == null) {
			__netIn = JvmSslBuffers.take(__bufferSize);
		}

		return try {
			socket.read(__netIn);
		} catch (e:Dynamic) {
			throw haxe.io.Error.Custom(e);
		}
	}

	/** One engine unwrap of what is held; see `__unwrapRecord`. **/
	@:noCompletion private function __unwrapHeld(into:Null<ByteBuffer>):Int {
		var held:Bool = into == null;
		var dst:ByteBuffer = into;

		if (held) {
			if (__appIn == null) {
				__appIn = JvmSslBuffers.take(__bufferSize);
			} else {
				// Read mode to write mode, what is unread kept at the front.
				__appIn.compact();
			}
			dst = __appIn;
		}

		var input = __netIn;
		input.flip();
		var result:SSLEngineResult = null;
		var failure:Dynamic = null;
		try {
			result = __engine.unwrap(input, dst);
		} catch (e:Dynamic) {
			failure = e;
		}
		input.compact();
		if (held) {
			__settleHeld();
		}

		if (failure != null) {
			// The engine has an alert to send about it.
			__alert();
			throw failure;
		}

		switch (result.getStatus().name()) {
			case "BUFFER_UNDERFLOW":
				// Less than a whole record. If the buffer is already full, the
				// record is larger than the buffer, and reading on cannot help:
				// the read takes nothing, reports would-block, and the record
				// never completes. Grown to what the session now says a record
				// can be, or double, so the next read has room for the rest.
				if (input.position() == input.capacity()) {
					var wanted:Int = __engine.getSession().getPacketBufferSize();
					var grown = ByteBuffer.allocate(wanted > input.capacity() ? wanted : input.capacity() * 2);
					input.flip();
					grown.put(input);
					__netIn = grown;
				}
				return UNDERFLOW;

			case "BUFFER_OVERFLOW":
				if (!held) {
					return TOO_SMALL;
				}
				// No room in the held plaintext for this record: made larger,
				// with what it holds kept, and the record tried again.
				var wanted:Int = __engine.getSession().getApplicationBufferSize();
				var size:Int = dst.capacity() * 2;
				var grown = ByteBuffer.allocate(wanted > size ? wanted : size);
				if (__appIn != null) {
					grown.put(__appIn);
				}
				grown.flip();
				__appIn = grown;
				return 0;

			case "CLOSED":
				__inboundDone = true;
				// Its own close_notify in answer, if the socket takes it.
				__service(result);
				return CLOSED;

			default:
				__service(result);
				return result.bytesProduced();
		}
	}

	/** The held plaintext back to read mode, and given back if empty. **/
	@:noCompletion private inline function __settleHeld():Void {
		var held = __appIn;
		held.flip();
		if (!held.hasRemaining()) {
			__appIn = null;
			JvmSslBuffers.give(held, __bufferSize);
		}
	}

	/** Hands over held plaintext, as much as fits; gives the buffer back once empty. **/
	@:noCompletion private function __takeHeld(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		var held = __appIn;
		if (held == null) {
			return 0;
		}

		var take:Int = held.remaining();
		if (take > length) {
			take = length;
		}
		held.get(buffer.getData(), position, take);

		if (!held.hasRemaining()) {
			__appIn = null;
			JvmSslBuffers.give(held, __bufferSize);
		}
		return take;
	}

	/**
		Closes the socket. A connection refused with an alert is not closed
		at once but handed to `JvmSslLinger`: its output is shut behind the
		alert, and what the peer still sends is read and dropped until it
		closes, for a second at most.

		Closed at once, it would be reset by whatever the peer sent next, and
		a reset throws away what the peer has not read yet: the alert saying
		why it was refused. A JDK client still writing its half of the
		handshake would fail that write and report "readHandshakeRecord" on
		Linux; on Windows the alert would simply be gone.
	**/
	override public function close():Void {
		var lingering:java.nio.channels.SocketChannel = null;
		if (__refused && channel != null && channel.isOpen()) {
			lingering = cast channel;
			// Shut only behind a whole alert: one still partly unsent would
			// be cut short.
			if (__netOut == null) {
				try {
					lingering.shutdownOutput();
				} catch (_:Dynamic) {}
			}
			// The base close lets the runtime's selector go of the channel
			// by closing it; here the key is cancelled instead, and the base
			// close, with no channel to close, still has the selector drop it.
			if (__selectKey != null) {
				__selectKey.cancel();
			}
			channel = null;
		}

		super.close();
		// Whatever it still held goes with it rather than with the socket
		// object, which a caller may keep.
		__netIn = null;
		__appIn = null;
		__netOut = null;

		if (lingering != null) {
			JvmSslLinger.hold(lingering);
		}
	}

	/**
		Whether this socket holds bytes the kernel no longer has.

		A TLS read takes whole records off the channel, so the end of the
		handshake routinely arrives in the same read as the first application
		record (a client that sends a request the instant it connects, which
		is to say every HTTPS client, lands exactly there). Those bytes then
		sit here while the channel looks idle, and a reactor that asks only
		the kernel what is readable never comes back for them.

		`SocketRegistry` asks this so a socket in that state is serviced
		anyway, rather than stranded until something else disturbs the
		connection.
	**/
	public function hasBufferedInput():Bool {
		if (!__handshaken) {
			return false;
		}

		if (__appIn != null && __appIn.hasRemaining()) {
			return true;
		}

		// The peer's close, decoded ahead of the read that reports it, once,
		// so that a socket nobody reads after its close is not reported
		// readable on every pump, holding the select at zero and spinning the
		// runtime.
		if (__inboundDone) {
			return !__eofTold;
		}

		if (__deferred != null) {
			return true;
		}

		if (__netIn == null || __netIn.position() == 0) {
			return false;
		}

		// Bytes present is not the same as bytes readable: a partial record
		// sits held until the rest of it arrives, and reporting that as
		// readable would pin the registry's select to a zero timeout and spin
		// the pump. What is whole is decoded, touching no socket, and only
		// plaintext it actually produced counts; a record can be decoded and
		// yield none, which is what a TLS 1.3 session ticket is.
		return try {
			__unwrapRecord(null, false, false);
			(__appIn != null && __appIn.hasRemaining()) || (__inboundDone && !__eofTold);
		} catch (e:Dynamic) {
			// For the read the registry makes next, which reports it and
			// closes; the read clears it, so it is answered once.
			__deferred = e;
			true;
		}
	}

	/**
		Hands back decrypted bytes: what is held, then every record that has
		already arrived, for as much as the caller's buffer takes.

		Records are decrypted straight into the caller's buffer where they fit,
		with no copy and no buffer held for them. Only when nothing has been
		read yet does a blocking socket wait for the peer.
	**/
	@:noCompletion private function __readApp(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		if (!__handshaken) {
			handshake();
		}

		if (__deferred != null) {
			var failure:Dynamic = __deferred;
			__deferred = null;
			throw failure;
		}

		if (length <= 0) {
			return 0;
		}

		// A reply the handshake still owes the peer goes first: it may be
		// what the peer is waiting on before it sends anything more.
		if (__netOut != null) {
			__flush();
		}

		var total:Int = __takeHeld(buffer, position, length);
		var direct:ByteBuffer = null;

		try {
			while (total < length) {
				var mayWait:Bool = total == 0;
				var produced:Int;

				if (__appIn == null) {
					if (direct == null) {
						direct = ByteBuffer.wrap(buffer.getData(), position, length);
					}
					direct.position(position + total);
					produced = __unwrapRecord(direct, mayWait, true);
					if (produced > 0) {
						total += produced;
						continue;
					}
					if (produced == TOO_SMALL) {
						// Too little room left for this record: it is held,
						// and handed over as far as the room goes.
						produced = __unwrapRecord(null, mayWait, true);
					}
				} else {
					produced = __unwrapRecord(null, mayWait, true);
				}

				if (produced < 0) {
					break;
				}
				total += __takeHeld(buffer, position + total, length - total);
			}
		} catch (e:Dynamic) {
			if (total > 0) {
				// What arrived before the failure is handed over first.
				__deferred = e;
				return total;
			}
			throw e;
		}

		if (total > 0) {
			return total;
		}
		if (__inboundDone) {
			__eofTold = true;
			throw new haxe.io.Eof();
		}
		throw haxe.io.Error.Blocked;
	}

	/** Encrypts application bytes and sends them: one record's worth a call. **/
	@:noCompletion private function __writeApp(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		if (!__handshaken) {
			handshake();
		}

		if (length <= 0) {
			return 0;
		}

		var source = ByteBuffer.wrap(buffer.getData(), position, length);
		var consumed:Int = 0;

		__outbound.acquire();
		try {
			// What was made before goes first, or the records would reach the
			// wire out of order.
			if (__flushLocked()) {
				var rounds:Int = 0;
				while (consumed == 0 && rounds++ < 8) {
					var result = __wrapLocked(source);
					consumed += result.bytesConsumed();

					if (result.getStatus().name() == "CLOSED") {
						throw new haxe.io.Eof();
					}
					if (__netOut != null) {
						// The socket took less than was made.
						break;
					}

					switch (result.getHandshakeStatus().name()) {
						case "NEED_TASK":
							__runTasks();
						case "NEED_WRAP":
						// Handshake records went ahead of the data; round
						// again for the data.
						default:
							if (result.bytesProduced() == 0) {
								// The engine is waiting on the peer.
								break;
							}
					}
				}
			}
		} catch (e:Dynamic) {
			__outbound.release();
			throw e;
		}
		__outbound.release();

		if (consumed == 0) {
			throw haxe.io.Error.Blocked;
		}
		return consumed;
	}
}

/**
	The contexts client connections are made from: one for each way of
	trusting and identifying, kept and shared.

	Each connection would otherwise build its own (key and trust managers, a
	random source, and for the JDK's default trust store, the store itself
	read and parsed), and a context is where a client's sessions are kept,
	so none could be resumed. A context is shared only between connections
	made the same way: verifying or not, trusting the same authorities,
	presenting the same certificate. A session made without verification is
	therefore never resumed by a connection that verifies, nor one made
	trusting one authority by a connection trusting another.

	Kept by identity: a certificate or key read again is a new object, and
	gets a context of its own. Only the most recent few are kept, so an
	application that reads a new certificate for every request costs a
	context per request, and no more.
**/
@:noCompletion @:access(crossbyte._internal.socket._jvm.JvmSslSocket)
private class JvmSslContexts {
	private static inline var KEEP:Int = 16;
	private static var __lock:sys.thread.Mutex = new sys.thread.Mutex();
	private static var __kept:Array<JvmSslContextEntry> = [];

	/** The context a client connection made as `socket` is should come from. **/
	public static function client(socket:JvmSslSocket):SSLContext {
		var verifies:Bool = socket.__verifies() != false;
		// The authorities trusted, or none named, for the JDK's own store.
		// Not verifying, none are consulted, so none tell contexts apart.
		var ca:Null<JvmSslCertificate> = verifies ? (socket.__ca != null ? socket.__ca : JvmSslSocket.DEFAULT_CA) : null;
		var presenting:Bool = socket.__certificate != null && socket.__key != null;
		var certificate:Null<JvmSslCertificate> = presenting ? socket.__certificate : null;
		var key:Null<JvmSslKey> = presenting ? socket.__key : null;

		__lock.acquire();
		for (i in 0...__kept.length) {
			var entry = __kept[i];
			if (entry.verifies == verifies && entry.ca == ca && entry.certificate == certificate && entry.key == key) {
				if (i > 0) {
					// Most recently used first, so the oldest is what goes.
					__kept.splice(i, 1);
					__kept.unshift(entry);
				}
				__lock.release();
				return entry.context;
			}
		}
		__lock.release();

		// Made outside the lock: reading the JDK's trust store takes a while,
		// and a connection wanting a context already made should not wait on
		// it. Two made at once for the same key both work; one is kept.
		var context:SSLContext = socket.__buildContext();

		__lock.acquire();
		__kept.unshift(new JvmSslContextEntry(verifies, ca, certificate, key, context));
		if (__kept.length > KEEP) {
			__kept.pop();
		}
		__lock.release();
		return context;
	}
}

@:noCompletion private class JvmSslContextEntry {
	public final verifies:Bool;
	public final ca:Null<JvmSslCertificate>;
	public final certificate:Null<JvmSslCertificate>;
	public final key:Null<JvmSslKey>;
	public final context:SSLContext;

	public function new(verifies:Bool, ca:Null<JvmSslCertificate>, certificate:Null<JvmSslCertificate>, key:Null<JvmSslKey>,
			context:SSLContext) {
		this.verifies = verifies;
		this.ca = ca;
		this.certificate = certificate;
		this.key = key;
		this.context = context;
	}
}

/**
	A thread's spare engine buffers.

	A connection takes one when a read or a write needs it and gives it back
	once it empties, so a connection that is idle (nearly every one, on a
	busy server) holds none. Three held for its whole life would be some
	50 KB a connection: half a gigabyte for 10,000 idle HTTPS connections.
	A runtime reads and writes all its connections on its own thread, so
	the pool is kept per thread and needs no lock; it keeps a few, as many
	as one call takes at once. Buffers of another size (grown for a record
	larger than the session said) are not kept.
**/
@:noCompletion private class JvmSslBuffers {
	private static inline var KEEP:Int = 4;
	private static var __local:JThreadLocal<JvmSslBuffers> = new JThreadLocal();

	private var __size:Int = 0;
	private var __count:Int = 0;
	private var __spare:Array<ByteBuffer> = [];

	private function new() {}

	private static function __mine():JvmSslBuffers {
		var existing:Null<JvmSslBuffers> = __local.get();
		if (existing == null) {
			existing = new JvmSslBuffers();
			__local.set(existing);
		}
		return existing;
	}

	/** An empty buffer of `size` bytes, in write mode. **/
	public static function take(size:Int):ByteBuffer {
		var mine = __mine();
		if (size == mine.__size && mine.__count > 0) {
			var buffer = mine.__spare[--mine.__count];
			mine.__spare[mine.__count] = null;
			return buffer;
		}
		return ByteBuffer.allocate(size);
	}

	/** `buffer`, finished with; kept if it is `size` bytes and there is room. **/
	public static function give(buffer:ByteBuffer, size:Int):Void {
		if (buffer.capacity() != size) {
			return;
		}

		var mine = __mine();
		if (size != mine.__size) {
			if (mine.__count > 0) {
				return;
			}
			mine.__size = size;
		}

		if (mine.__count < KEEP) {
			buffer.clear();
			mine.__spare[mine.__count++] = buffer;
		}
	}
}

/** Plaintext in; ciphertext off the wire. **/
/**
	Connections refused with an alert, held open until the peer closes, for
	`HOLD_SECONDS` at most, and read meanwhile so nothing the peer still sends
	resets them. See `JvmSslSocket.close`.

	One daemon thread serves them all, started with the first and ended with
	the last, so a process with none has none and one never waits on it.
**/
private class JvmSslLinger implements java.lang.Runnable {
	public static inline var HOLD_SECONDS:Float = 1.0;

	static var __lock:sys.thread.Mutex = new sys.thread.Mutex();
	static var __held:Array<JvmSslLingering> = [];
	static var __running:Bool = false;

	public static function hold(channel:java.nio.channels.SocketChannel):Void {
		__lock.acquire();
		__held.push(new JvmSslLingering(channel, haxe.Timer.stamp() + HOLD_SECONDS));
		var start:Bool = !__running;
		__running = true;
		__lock.release();

		if (start) {
			var thread = new java.lang.Thread(new JvmSslLinger(), "crossbyte-tls-linger");
			thread.setDaemon(true);
			thread.start();
		}
	}

	function new() {}

	public function run():Void {
		var scratch:ByteBuffer = ByteBuffer.allocate(4096);
		while (true) {
			__lock.acquire();
			if (__held.length == 0) {
				__running = false;
				__lock.release();
				return;
			}
			var batch:Array<JvmSslLingering> = __held.copy();
			__lock.release();

			var now:Float = haxe.Timer.stamp();
			for (held in batch) {
				var done:Bool = now >= held.until;
				if (!done) {
					try {
						// Whatever has arrived, dropped; -1 is the peer's close.
						var n:Int = 0;
						do {
							scratch.clear();
							n = held.channel.read(scratch);
						} while (n > 0);
						done = n < 0;
					} catch (_:Dynamic) {
						done = true;
					}
				}
				if (done) {
					try {
						held.channel.close();
					} catch (_:Dynamic) {}
					__lock.acquire();
					__held.remove(held);
					__lock.release();
				}
			}
			crossbyte._internal.system.Sleep.sleep(0.01);
		}
	}
}

private class JvmSslLingering {
	public var channel(default, null):java.nio.channels.SocketChannel;
	public var until(default, null):Float;

	public function new(channel:java.nio.channels.SocketChannel, until:Float) {
		this.channel = channel;
		this.until = until;
	}
}

private class JvmSslInput extends haxe.io.Input {
	private var socket:JvmSslSocket;
	// Kept: a reader taking a line a byte at a time, as the HTTP client
	// does, would allocate one for every byte.
	private var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);

	public function new(socket:JvmSslSocket) {
		this.socket = socket;
	}

	override public function readByte():Int {
		if (@:privateAccess socket.__readApp(one, 0, 1) < 1) {
			throw haxe.io.Error.Blocked;
		}
		return one.get(0);
	}

	override public function readBytes(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		return @:privateAccess socket.__readApp(buffer, position, length);
	}
}

/** Plaintext out; ciphertext onto the wire. **/
private class JvmSslOutput extends haxe.io.Output {
	private var socket:JvmSslSocket;
	private var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);

	public function new(socket:JvmSslSocket) {
		this.socket = socket;
	}

	override public function writeByte(value:Int):Void {
		one.set(0, value & 0xFF);
		@:privateAccess socket.__writeApp(one, 0, 1);
	}

	override public function writeBytes(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		return @:privateAccess socket.__writeApp(buffer, position, length);
	}
}

/**
	X.509 certificates, read from PEM: one, or every one a file holds.

	A PEM file is often more than one certificate. What an authority issues is
	`fullchain.pem`, the server's certificate followed by the intermediate that
	issued it, and a server has to present both: a client trusts the root, and
	the leaf alone cannot be traced to it. A trust file is often a bundle of
	several authorities. So every certificate is kept, in file order, and
	`native` is the first: the leaf of a chain.

	The JDK's `generateCertificate` reads only the first, so a server given
	`fullchain.pem` would present the leaf without its intermediate, which
	every client refuses (curl, Node, browsers, the JDK), and a bundle would
	trust its first authority alone. Native and Node read the whole file.
**/
class JvmSslCertificate {
	private static inline var BEGIN:String = "-----BEGIN CERTIFICATE-----";
	private static inline var END:String = "-----END CERTIFICATE-----";

	/** The first certificate: for a chain, the one it certifies. **/
	@:noCompletion public var native(default, null):JCertificate;

	/** Every certificate, in the order the text gave them; never empty. **/
	@:noCompletion public var chain(default, null):java.NativeArray<JCertificate>;

	public function new(native:JCertificate, ?chain:java.NativeArray<JCertificate>) {
		this.native = native;

		if (chain == null || chain.length == 0) {
			chain = new java.NativeArray(1);
			chain[0] = native;
		}
		this.chain = chain;
	}

	public static function loadFile(path:String):JvmSslCertificate {
		return fromString(sys.io.File.getContent(path));
	}

	public static function fromString(pem:String):JvmSslCertificate {
		if (pem == null || pem == "") {
			throw "A certificate needs PEM text to read from.";
		}

		var read:JCollection<JCertificate> = try {
			var factory = CertificateFactory.getInstance("X.509");
			factory.generateCertificates(new ByteArrayInputStream(haxe.io.Bytes.ofString(__certificateBlocks(pem)).getData()));
		} catch (e:Dynamic) {
			throw "The certificate could not be read: " + Std.string(e);
		}

		if (read.size() == 0) {
			throw "The certificate could not be read: the text holds no certificate.";
		}

		var chain:java.NativeArray<JCertificate> = new java.NativeArray(read.size());
		var at:Int = 0;
		var it = read.iterator();
		while (it.hasNext() && at < chain.length) {
			chain[at++] = it.next();
		}

		return new JvmSslCertificate(chain[0], chain);
	}

	/**
		The certificate blocks of `pem`, and nothing else in it.

		A PEM file can hold a key beside its certificates (a combined key and
		certificate file is a common way to ship one), and the JDK's reader
		fails on the first block that is not a certificate, where native and
		Node pass over it. Text with no certificate armour at all is handed on
		as it is, for the reader to say what it makes of it.
	**/
	private static function __certificateBlocks(pem:String):String {
		var from:Int = pem.indexOf(BEGIN);
		if (from < 0) {
			return pem;
		}

		var blocks = new StringBuf();
		while (from >= 0) {
			var to:Int = pem.indexOf(END, from);
			if (to < 0) {
				// Unterminated: handed on, so the reader reports it rather
				// than the certificate silently going missing.
				blocks.add(pem.substr(from));
				break;
			}
			blocks.add(pem.substring(from, to + END.length));
			blocks.add("\n");
			from = pem.indexOf(BEGIN, to);
		}
		return blocks.toString();
	}
}

/**
	A private key, read from PEM in whichever form it came: see `readPEM`.

	PKCS#8 (`BEGIN PRIVATE KEY`) is what `PKCS8EncodedKeySpec` reads, so
	the other forms are brought to it with the JDK alone: decrypted with its
	ciphers, and rewritten in PKCS#8's DER. A form that cannot be read is
	refused by name rather than misparsed: a key that silently fails to load
	would surface much later as a handshake that never completes.

	The algorithm is not stated in a PKCS#8 PEM's armour, so each candidate
	is tried in turn there.
**/
class JvmSslKey {
	private static var __ALGORITHMS:Array<String> = ["RSA", "EC", "DSA", "EdDSA"];

	@:noCompletion public var native(default, null):PrivateKey;

	public function new(native:PrivateKey) {
		this.native = native;
	}

	/**
		Nothing of the key. The JDK's own RSA key prints its private exponent
		among its fields, so this never hands its `native` to a printer.
	**/
	public function toString():String {
		return "[Key: redacted]";
	}

	public static function loadFile(path:String, isPublic:Bool = false, ?password:String):JvmSslKey {
		return readPEM(sys.io.File.getContent(path), isPublic, password);
	}

	/**
		Reads a private key in any of the forms a key file comes in, as
		mbedTLS and Node do: PKCS#8 (`BEGIN PRIVATE KEY`), PKCS#8 encrypted
		(`BEGIN ENCRYPTED PRIVATE KEY`), and the older PKCS#1 (`BEGIN RSA
		PRIVATE KEY`) and SEC1 (`BEGIN EC PRIVATE KEY`), plain or encrypted
		by OpenSSL (`Proc-Type: 4,ENCRYPTED`). The JDK reads only the first, so
		the older two are rewritten as PKCS#8 (the same key, with its
		algorithm stated) and an encrypted one is decrypted with `password`
		first. A `password` given for a key that is not encrypted is not
		needed, and not used.
	**/
	public static function readPEM(pem:String, isPublic:Bool = false, ?password:String):JvmSslKey {
		if (pem == null || pem == "") {
			throw "A key needs PEM text to read from.";
		}

		if (isPublic) {
			throw "Public keys are not supported by the jvm TLS backend.";
		}

		// By its armour. A file can hold more than the key (an EC key's
		// parameters before it, a certificate beside it), so the key's own
		// block is the one read.
		if (pem.indexOf("-----BEGIN ENCRYPTED PRIVATE KEY-----") >= 0) {
			var form:String = "an encrypted PKCS#8 key (BEGIN ENCRYPTED PRIVATE KEY)";
			return __fromPkcs8(__decryptPkcs8(__decode(__body(pem, "ENCRYPTED PRIVATE KEY")), __required(password, form)), null);
		}
		if (pem.indexOf("-----BEGIN PRIVATE KEY-----") >= 0) {
			return __fromPkcs8(__decode(__body(pem, "PRIVATE KEY")), null);
		}
		if (pem.indexOf("-----BEGIN RSA PRIVATE KEY-----") >= 0) {
			var pkcs1:haxe.io.Bytes = __traditional(pem, "RSA PRIVATE KEY", "a PKCS#1 RSA key (BEGIN RSA PRIVATE KEY)", password);
			return __fromPkcs8(__pkcs8(haxe.io.Bytes.ofHex(RSA_ALGORITHM), pkcs1), "RSA");
		}
		if (pem.indexOf("-----BEGIN EC PRIVATE KEY-----") >= 0) {
			var sec1:haxe.io.Bytes = __traditional(pem, "EC PRIVATE KEY", "a SEC1 EC key (BEGIN EC PRIVATE KEY)", password);
			return __fromPkcs8(__ecPkcs8(sec1), "EC");
		}

		throw "The text holds no private key: there is no BEGIN PRIVATE KEY, BEGIN ENCRYPTED PRIVATE KEY, BEGIN RSA PRIVATE KEY or "
			+ "BEGIN EC PRIVATE KEY block in it.";
	}

	/** rsaEncryption's AlgorithmIdentifier, with its NULL parameters (RFC 8017 A.1). **/
	private static inline var RSA_ALGORITHM:String = "300d06092a864886f70d0101010500";

	/** id-ecPublicKey's object identifier, 1.2.840.10045.2.1, as DER (RFC 5480 2.1.1). **/
	private static inline var EC_PUBLIC_KEY:String = "06072a8648ce3d0201";

	/** A PKCS#8 key: each algorithm in turn, or the one its form says. **/
	private static function __fromPkcs8(der:haxe.io.Bytes, algorithm:Null<String>):JvmSslKey {
		var spec = new PKCS8EncodedKeySpec(der.getData());
		var failure:String = null;
		var candidates:Array<String> = algorithm != null ? [algorithm] : __ALGORITHMS;

		for (candidate in candidates) {
			try {
				return new JvmSslKey(KeyFactory.getInstance(candidate).generatePrivate(spec));
			} catch (e:Dynamic) {
				if (failure == null) {
					failure = Std.string(e);
				}
			}
		}

		throw "The key could not be read as any of " + candidates.join(", ") + ": " + failure;
	}

	private static function __required(password:Null<String>, form:String):String {
		if (password == null || password == "") {
			throw "The key is " + form + ", and no password was given to decrypt it with.";
		}
		return password;
	}

	/**
		PKCS#8's own encryption (RFC 8018), which the JDK decrypts. PBES2
		(what `openssl pkcs8 -topk8` and `openssl req` write) names its key
		derivation and cipher inside its parameters, and the JDK spells the
		pair as one algorithm there, `PBEWithHmacSHA256AndAES_256`; the older
		schemes are named by the identifier itself.
	**/
	private static function __decryptPkcs8(der:haxe.io.Bytes, password:String):haxe.io.Bytes {
		var info:EncryptedPrivateKeyInfo = try {
			new EncryptedPrivateKeyInfo(der.getData());
		} catch (e:Dynamic) {
			throw "The encrypted key could not be read: " + Std.string(e);
		}

		var parameters:AlgorithmParameters = info.getAlgParameters();
		var name:String = info.getAlgName();
		var algorithm:String = (name == "PBES2" || name == "1.2.840.113549.1.5.13") && parameters != null ? parameters.toString() : name;

		var cipher:Cipher = try {
			var secret = SecretKeyFactory.getInstance(algorithm).generateSecret(new PBEKeySpec(__chars(password)));
			var cipher = Cipher.getInstance(algorithm);
			cipher.init(Cipher.DECRYPT_MODE, secret, parameters);
			cipher;
		} catch (e:Dynamic) {
			throw "The key is encrypted with " + algorithm + ", which this jvm cannot decrypt: " + Std.string(e);
		}

		return try {
			haxe.io.Bytes.ofData(info.getKeySpec(cipher).getEncoded());
		} catch (e:Dynamic) {
			throw "The key could not be decrypted: is the password right? " + Std.string(e);
		}
	}

	/**
		A PKCS#1 or SEC1 key: its DER, decrypted first when OpenSSL encrypted
		it (RFC 1421's headers, `Proc-Type: 4,ENCRYPTED` and `DEK-Info`, ahead
		of the base64).
	**/
	private static function __traditional(pem:String, label:String, form:String, password:Null<String>):haxe.io.Bytes {
		var body:String = __body(pem, label);
		var dekInfo:Null<String> = null;
		var encrypted:Bool = false;
		var data:StringBuf = new StringBuf();

		for (raw in body.split("\n")) {
			var line:String = StringTools.trim(raw);
			var colon:Int = line.indexOf(":");
			if (colon > 0) {
				var header:String = line.substr(0, colon);
				var value:String = StringTools.trim(line.substr(colon + 1));
				if (header == "Proc-Type") {
					encrypted = value.indexOf("ENCRYPTED") >= 0;
				} else if (header == "DEK-Info") {
					dekInfo = value;
				}
			} else {
				data.add(line);
			}
		}

		var der:haxe.io.Bytes = __decode(data.toString());
		if (!encrypted) {
			return der;
		}
		if (dekInfo == null) {
			throw "The key is " + form + " marked as encrypted, with no DEK-Info saying how.";
		}
		return __decryptTraditional(der, dekInfo, __required(password, form + ", encrypted"), form);
	}

	/**
		OpenSSL's own encryption of a PEM key: a block cipher in CBC mode,
		keyed from the password by EVP_BytesToKey (MD5, one round, salted
		with the first eight bytes of the IV `DEK-Info` names).
	**/
	private static function __decryptTraditional(data:haxe.io.Bytes, dekInfo:String, password:String, form:String):haxe.io.Bytes {
		var comma:Int = dekInfo.indexOf(",");
		var name:String = StringTools.trim(comma < 0 ? dekInfo : dekInfo.substr(0, comma)).toUpperCase();
		var iv:haxe.io.Bytes = try {
			haxe.io.Bytes.ofHex(StringTools.trim(dekInfo.substr(comma + 1)));
		} catch (_:Dynamic) {
			throw "The key is " + form + " whose DEK-Info carries no IV: " + dekInfo;
		}

		var transformation:String;
		var algorithm:String;
		var keyLength:Int;
		switch (name) {
			case "AES-128-CBC":
				transformation = "AES/CBC/PKCS5Padding";
				algorithm = "AES";
				keyLength = 16;
			case "AES-192-CBC":
				transformation = "AES/CBC/PKCS5Padding";
				algorithm = "AES";
				keyLength = 24;
			case "AES-256-CBC":
				transformation = "AES/CBC/PKCS5Padding";
				algorithm = "AES";
				keyLength = 32;
			case "DES-EDE3-CBC":
				transformation = "DESede/CBC/PKCS5Padding";
				algorithm = "DESede";
				keyLength = 24;
			case "DES-CBC":
				transformation = "DES/CBC/PKCS5Padding";
				algorithm = "DES";
				keyLength = 8;
			default:
				throw "The key is " + form + " encrypted with " + name + ", which the jvm TLS backend cannot decrypt. "
					+ "Re-encrypt it with AES: openssl pkcs8 -topk8 -v2 aes-256-cbc -in key.pem -out key-pkcs8.pem";
		}
		if (iv.length < 8) {
			throw "The key is " + form + " whose DEK-Info IV is too short: " + dekInfo;
		}

		var secret:haxe.io.Bytes = __bytesToKey(haxe.io.Bytes.ofString(password), iv.sub(0, 8), keyLength);
		return try {
			var cipher = Cipher.getInstance(transformation);
			cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(secret.getData(), algorithm), new IvParameterSpec(iv.getData()));
			haxe.io.Bytes.ofData(cipher.doFinal(data.getData()));
		} catch (e:Dynamic) {
			throw "The key could not be decrypted: is the password right? " + Std.string(e);
		}
	}

	/** OpenSSL's EVP_BytesToKey with MD5 and one round, as its PEM encryption uses it. **/
	private static function __bytesToKey(password:haxe.io.Bytes, salt:haxe.io.Bytes, length:Int):haxe.io.Bytes {
		var key = new haxe.io.BytesBuffer();
		var previous:Null<haxe.io.Bytes> = null;
		while (key.length < length) {
			var round = new haxe.io.BytesBuffer();
			if (previous != null) {
				round.add(previous);
			}
			round.add(password);
			round.add(salt);
			previous = haxe.crypto.Md5.make(round.getBytes());
			key.add(previous);
		}
		return key.getBytes().sub(0, length);
	}

	/**
		A SEC1 key as PKCS#8. The key names its curve itself, in its `[0]`
		parameters (RFC 5915 3), and that moves to the AlgorithmIdentifier,
		where PKCS#8 says it; the rest stays as it was. Written as OpenSSL
		writes the same key as PKCS#8, so it is the same key, byte for byte,
		whichever way the file had it.
	**/
	private static function __ecPkcs8(sec1:haxe.io.Bytes):haxe.io.Bytes {
		var key = __element(sec1, 0);
		var curve:Null<haxe.io.Bytes> = null;
		var rest = new haxe.io.BytesBuffer();
		var at:Int = key.start;
		while (at < key.end) {
			var field = __element(sec1, at);
			if (field.tag == 0xA0) {
				curve = sec1.sub(field.start, field.end - field.start);
			} else {
				rest.add(sec1.sub(at, field.end - at));
			}
			at = field.end;
		}
		if (curve == null) {
			throw "The key is a SEC1 EC key (BEGIN EC PRIVATE KEY) that does not name its curve, and the jvm cannot read one without. "
				+ "Convert it to PKCS#8 with: openssl pkcs8 -topk8 -nocrypt -in key.pem -out key-pkcs8.pem";
		}

		var algorithm = new haxe.io.BytesBuffer();
		algorithm.add(haxe.io.Bytes.ofHex(EC_PUBLIC_KEY));
		algorithm.add(curve);
		return __pkcs8(__tlv(0x30, algorithm.getBytes()), __tlv(0x30, rest.getBytes()));
	}

	/** A PKCS#8 PrivateKeyInfo (RFC 5208 5): version 0, the algorithm, and the key. **/
	private static function __pkcs8(algorithm:haxe.io.Bytes, key:haxe.io.Bytes):haxe.io.Bytes {
		var info = new haxe.io.BytesBuffer();
		info.add(haxe.io.Bytes.ofHex("020100"));
		info.add(algorithm);
		info.add(__tlv(0x04, key));
		return __tlv(0x30, info.getBytes());
	}

	/** One DER element: its tag, and where its contents begin and end. **/
	private static function __element(der:haxe.io.Bytes, at:Int):{tag:Int, start:Int, end:Int} {
		if (at + 2 > der.length) {
			throw "The key's DER ends inside an element.";
		}
		var tag:Int = der.get(at);
		var first:Int = der.get(at + 1);
		var start:Int = at + 2;
		var length:Int = first;
		if (first >= 0x80) {
			var count:Int = first & 0x7F;
			if (count == 0 || count > 3 || start + count > der.length) {
				throw "The key's DER has a length it cannot hold.";
			}
			length = 0;
			for (i in 0...count) {
				length = (length << 8) | der.get(start + i);
			}
			start += count;
		}
		if (start + length > der.length) {
			throw "The key's DER ends inside an element.";
		}
		return {tag: tag, start: start, end: start + length};
	}

	/** A DER element of `tag` holding `content`. **/
	private static function __tlv(tag:Int, content:haxe.io.Bytes):haxe.io.Bytes {
		var out = new haxe.io.BytesBuffer();
		var length:Int = content.length;
		out.addByte(tag);
		if (length < 0x80) {
			out.addByte(length);
		} else if (length < 0x100) {
			out.addByte(0x81);
			out.addByte(length);
		} else if (length < 0x10000) {
			out.addByte(0x82);
			out.addByte(length >> 8);
			out.addByte(length & 0xFF);
		} else {
			out.addByte(0x83);
			out.addByte(length >> 16);
			out.addByte((length >> 8) & 0xFF);
			out.addByte(length & 0xFF);
		}
		out.add(content);
		return out.getBytes();
	}

	private static function __chars(text:String):java.NativeArray<java.types.Char16> {
		var chars = new java.NativeArray<java.types.Char16>(text.length);
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			chars[i] = cast code;
		}
		return chars;
	}

	private static function __decode(base64:String):haxe.io.Bytes {
		return try {
			haxe.io.Bytes.ofData(Base64.getMimeDecoder().decode(base64));
		} catch (e:Dynamic) {
			throw "The key is not valid base64: " + Std.string(e);
		}
	}

	private static function __body(pem:String, label:String):String {
		var begin = "-----BEGIN " + label + "-----";
		var end = "-----END " + label + "-----";
		var from = pem.indexOf(begin);
		var to = pem.indexOf(end);

		if (from < 0 || to < 0) {
			throw "The key is not a PEM " + label + " block.";
		}

		return pem.substring(from + begin.length, to);
	}
}
#end
