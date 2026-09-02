package crossbyte._internal.socket._jvm;

// Only built for java/jvm: everything here is javax.net.ssl and java.security,
// and no other target references this module.
#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte._internal.socket._jvm.JvmSslExterns.Certificate as JCertificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManager;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManagerFactory;
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

	// Configured on the listener before bind(); copied to each connection.
	@:noCompletion private var __certificate:JvmSslCertificate;
	@:noCompletion private var __key:JvmSslKey;
	@:noCompletion private var __ca:JvmSslCertificate;
	@:noCompletion private var __hostname:String;
	@:noCompletion private var __alpn:Array<String>;

	// Per-connection engine state.
	@:noCompletion private var __engine:SSLEngine;
	@:noCompletion private var __netIn:ByteBuffer;
	@:noCompletion private var __netOut:ByteBuffer;
	@:noCompletion private var __appIn:ByteBuffer;
	@:noCompletion private var __handshaken:Bool = false;
	@:noCompletion private var __pendingOut:Bool = false;

	@:noCompletion private static var __EMPTY:ByteBuffer = ByteBuffer.allocate(0);

	public function new() {
		super();
	}

	// -------------------------------------------------------- configuration

	public function setCertificate(cert:JvmSslCertificate, key:JvmSslKey):Void {
		__certificate = cert;
		__key = key;
	}

	public function setCA(cert:JvmSslCertificate):Void {
		__ca = cert;
	}

	public function setHostname(name:String):Void {
		__hostname = name;
	}

	/**
		Offers these protocol names during the handshake.

		Built into the JDK, unlike the cpp path, which needed a native extension
		to reach mbedTLS's ALPN at all. `null` or an empty list disables it.
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

	public function addSNICertificate(cbServernameMatch:String->Bool, cert:JvmSslCertificate, key:JvmSslKey):Void {
		throw "Server Name Indication is not supported by the jvm TLS backend yet.";
	}

	public function peerCertificate():JvmSslCertificate {
		if (__engine == null) {
			return null;
		}

		return try {
			var chain = __engine.getSession().getPeerCertificates();
			chain.length > 0 ? new JvmSslCertificate(chain[0]) : null;
		} catch (e:Dynamic) {
			null;
		}
	}

	// ------------------------------------------------------------ lifecycle

	/**
		Accepts a connection and gives it a server-mode engine.

		The certificate lives on the listener, so each accepted socket is handed
		the same material and builds its own engine from it. Nothing is
		negotiated here; the handshake is driven later, by the pump.
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
		accepted.verifyCert = verifyCert;
		accepted.__startEngine(false);
		return accepted;
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

		// Anything a previous pass wrapped but could not send goes first. The
		// peer is waiting on it, and wrapping more before it lands would put
		// the records on the wire out of order.
		if (__pendingOut && !__drain()) {
			throw haxe.io.Error.Blocked;
		}

		while (true) {
			switch (__engine.getHandshakeStatus().name()) {
				case "NEED_TASK":
					var task = __engine.getDelegatedTask();
					while (task != null) {
						task.run();
						task = __engine.getDelegatedTask();
					}

				case "NEED_WRAP":
					__wrap();
					if (__pendingOut) {
						throw haxe.io.Error.Blocked;
					}

				case "NEED_UNWRAP", "NEED_UNWRAP_AGAIN":
					__unwrap();

				case "FINISHED", "NOT_HANDSHAKING":
					__handshaken = true;
					return;

				case other:
					throw "Unexpected TLS handshake status: " + other;
			}
		}
	}

	// --------------------------------------------------------------- engine

	@:noCompletion private function __startEngine(clientMode:Bool):Void {
		__engine = __buildContext().createSSLEngine();
		__engine.setUseClientMode(clientMode);

		if (__alpn != null) {
			var names:java.NativeArray<String> = new java.NativeArray(__alpn.length);
			for (i in 0...__alpn.length) {
				names[i] = __alpn[i];
			}

			var parameters = __engine.getSSLParameters();
			parameters.setApplicationProtocols(names);
			__engine.setSSLParameters(parameters);
		}

		var session = __engine.getSession();
		__netIn = ByteBuffer.allocate(session.getPacketBufferSize());
		__netOut = ByteBuffer.allocate(session.getPacketBufferSize());
		__appIn = ByteBuffer.allocate(session.getApplicationBufferSize());
		__appIn.flip();

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

			var chain:java.NativeArray<JCertificate> = new java.NativeArray(1);
			chain[0] = __certificate.native;
			store.setKeyEntry("crossbyte", cast __key.native, blank, chain);

			var factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
			factory.init(store, blank);
			managers = factory.getKeyManagers();
		}

		var trust:Null<java.NativeArray<TrustManager>> = null;
		var ca = __ca != null ? __ca : DEFAULT_CA;

		if (ca != null) {
			var store = KeyStore.getInstance(KeyStore.getDefaultType());
			store.load(null, null);
			store.setCertificateEntry("ca", ca.native);
			var factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
			factory.init(store);
			trust = factory.getTrustManagers();
		}

		var context = SSLContext.getInstance("TLS");
		context.init(managers, trust, null);
		return context;
	}

	/** Wraps whatever the engine wants to send and tries to put it on the wire. **/
	@:noCompletion private function __wrap():Void {
		__netOut.clear();
		var result = __engine.wrap(__EMPTY, __netOut);

		switch (result.getStatus().name()) {
			case "BUFFER_OVERFLOW":
				// A record larger than the size the session advertised.
				__netOut = ByteBuffer.allocate(__netOut.capacity() * 2);
				return;
			case "CLOSED":
				throw new haxe.io.Eof();
			default:
		}

		__netOut.flip();
		__pendingOut = true;
		__drain();
	}

	/** @return Whether everything pending reached the wire. **/
	@:noCompletion private function __drain():Bool {
		var socket:java.nio.channels.SocketChannel = cast this.channel;

		while (__netOut.hasRemaining()) {
			var written = try {
				socket.write(__netOut);
			} catch (e:Dynamic) {
				throw haxe.io.Error.Custom(e);
			}

			if (written <= 0) {
				return false;
			}
		}

		__pendingOut = false;
		return true;
	}

	/** Reads from the wire and decrypts whatever arrived complete. **/
	@:noCompletion private function __unwrap():Void {
		var socket:java.nio.channels.SocketChannel = cast this.channel;

		var read = try {
			socket.read(__netIn);
		} catch (e:Dynamic) {
			throw haxe.io.Error.Custom(e);
		}

		if (read < 0) {
			throw new haxe.io.Eof();
		}

		__netIn.flip();
		__appIn.compact();
		var result = __engine.unwrap(__netIn, __appIn);
		__appIn.flip();
		__netIn.compact();

		switch (result.getStatus().name()) {
			case "BUFFER_UNDERFLOW":
				// Half a record. Nothing to do until the peer sends the rest,
				// and nothing to gain from spinning if this pass read nothing.
				if (read == 0) {
					throw haxe.io.Error.Blocked;
				}
			case "BUFFER_OVERFLOW":
				var grown = ByteBuffer.allocate(__appIn.capacity() * 2);
				grown.put(__appIn);
				grown.flip();
				__appIn = grown;
			case "CLOSED":
				throw new haxe.io.Eof();
			default:
				if (read == 0 && result.bytesProduced() == 0 && result.bytesConsumed() == 0) {
					throw haxe.io.Error.Blocked;
				}
		}
	}

	/** Hands back decrypted bytes, filling from the wire when none are held. **/
	@:noCompletion private function __readApp(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		if (!__handshaken) {
			handshake();
		}

		if (!__appIn.hasRemaining()) {
			__unwrap();
		}

		if (!__appIn.hasRemaining()) {
			throw haxe.io.Error.Blocked;
		}

		var take = __appIn.remaining();
		if (take > length) {
			take = length;
		}

		__appIn.get(buffer.getData(), position, take);
		return take;
	}

	/** Encrypts application bytes and sends them. **/
	@:noCompletion private function __writeApp(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		if (!__handshaken) {
			handshake();
		}

		if (__pendingOut && !__drain()) {
			throw haxe.io.Error.Blocked;
		}

		var source = ByteBuffer.wrap(buffer.getData(), position, length);
		__netOut.clear();
		var result = __engine.wrap(source, __netOut);

		switch (result.getStatus().name()) {
			case "BUFFER_OVERFLOW":
				__netOut = ByteBuffer.allocate(__netOut.capacity() * 2);
				throw haxe.io.Error.Blocked;
			case "CLOSED":
				throw new haxe.io.Eof();
			default:
		}

		__netOut.flip();
		__pendingOut = true;

		if (!__drain() && result.bytesConsumed() == 0) {
			throw haxe.io.Error.Blocked;
		}

		return result.bytesConsumed();
	}
}

/** Plaintext in; ciphertext off the wire. **/
private class JvmSslInput extends haxe.io.Input {
	private var socket:JvmSslSocket;

	public function new(socket:JvmSslSocket) {
		this.socket = socket;
	}

	override public function readByte():Int {
		var one = haxe.io.Bytes.alloc(1);
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

	public function new(socket:JvmSslSocket) {
		this.socket = socket;
	}

	override public function writeByte(value:Int):Void {
		var one = haxe.io.Bytes.alloc(1);
		one.set(0, value & 0xFF);
		@:privateAccess socket.__writeApp(one, 0, 1);
	}

	override public function writeBytes(buffer:haxe.io.Bytes, position:Int, length:Int):Int {
		return @:privateAccess socket.__writeApp(buffer, position, length);
	}
}

/**
	An X.509 certificate, read from PEM.

	`CertificateFactory` reads PEM armour directly, so this is a thin wrapper
	over the parsed certificate plus the text it came from -- the text is kept
	because a trust store is built from it later and re-parsing is cheaper than
	holding a second representation.
**/
class JvmSslCertificate {
	@:noCompletion public var native(default, null):JCertificate;

	public function new(native:JCertificate) {
		this.native = native;
	}

	public static function loadFile(path:String):JvmSslCertificate {
		return fromString(sys.io.File.getContent(path));
	}

	public static function fromString(pem:String):JvmSslCertificate {
		if (pem == null || pem == "") {
			throw "A certificate needs PEM text to read from.";
		}

		try {
			var factory = CertificateFactory.getInstance("X.509");
			var stream = new ByteArrayInputStream(haxe.io.Bytes.ofString(pem).getData());
			return new JvmSslCertificate(factory.generateCertificate(stream));
		} catch (e:Dynamic) {
			throw "The certificate could not be read: " + Std.string(e);
		}
	}
}

/**
	A private key, read from an unencrypted PKCS#8 PEM.

	PKCS#8 -- `BEGIN PRIVATE KEY` -- is what `openssl req -newkey ... -nodes`
	writes and what `PKCS8EncodedKeySpec` reads, so the common case needs no
	dependency. PKCS#1 (`BEGIN RSA PRIVATE KEY`) and encrypted keys are refused
	by name rather than misparsed: the JDK cannot read either without a
	conversion step, and a key that silently fails to load would surface much
	later as a handshake that never completes.

	The algorithm is not stated in the PEM, so each candidate is tried in turn.
**/
class JvmSslKey {
	private static var __ALGORITHMS:Array<String> = ["RSA", "EC", "DSA", "EdDSA"];

	@:noCompletion public var native(default, null):PrivateKey;

	public function new(native:PrivateKey) {
		this.native = native;
	}

	public static function loadFile(path:String, isPublic:Bool = false, ?password:String):JvmSslKey {
		return readPEM(sys.io.File.getContent(path), isPublic, password);
	}

	public static function readPEM(pem:String, isPublic:Bool = false, ?password:String):JvmSslKey {
		if (pem == null || pem == "") {
			throw "A key needs PEM text to read from.";
		}

		if (isPublic) {
			throw "Public keys are not supported by the jvm TLS backend.";
		}

		if (password != null && password != "") {
			throw "Encrypted private keys are not supported by the jvm TLS backend yet. "
				+ "Convert the key to an unencrypted PKCS#8 with: "
				+ "openssl pkcs8 -topk8 -nocrypt -in key.pem -out key-pkcs8.pem";
		}

		if (pem.indexOf("BEGIN RSA PRIVATE KEY") >= 0 || pem.indexOf("BEGIN EC PRIVATE KEY") >= 0) {
			throw "PKCS#1 keys are not supported by the jvm TLS backend. "
				+ "Convert the key to PKCS#8 with: "
				+ "openssl pkcs8 -topk8 -nocrypt -in key.pem -out key-pkcs8.pem";
		}

		var body = __body(pem, "PRIVATE KEY");
		var der = try {
			Base64.getMimeDecoder().decode(body);
		} catch (e:Dynamic) {
			throw "The key is not valid base64: " + Std.string(e);
		}

		var spec = new PKCS8EncodedKeySpec(der);
		var failure:String = null;

		for (algorithm in __ALGORITHMS) {
			try {
				return new JvmSslKey(KeyFactory.getInstance(algorithm).generatePrivate(spec));
			} catch (e:Dynamic) {
				if (failure == null) {
					failure = Std.string(e);
				}
			}
		}

		throw "The key could not be read as any of " + __ALGORITHMS.join(", ") + ": " + failure;
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
