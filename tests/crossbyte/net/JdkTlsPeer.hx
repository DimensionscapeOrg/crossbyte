package crossbyte.net;

#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte._internal.socket._jvm.JvmSslExterns.Certificate as JCertificate;

/**
	What the JDK's own blocking TLS peer is told to do.

	`trust` and `present` name PEM files, read here with the JDK's parser, so
	the peer's view of a chain or a bundle never goes through the CrossByte
	code a test is checking.
**/
typedef JdkPeerOptions = {
	/** PEM files whose every certificate is trusted. Empty or null trusts nothing. **/
	var ?trust:Array<String>;

	/** A PEM chain to present, leaf first, and its key. **/
	var ?present:{chain:String, key:crossbyte.net.Key};

	/** Protocols to allow, such as `["TLSv1.2"]`; null leaves the JDK's. **/
	var ?protocols:Array<String>;

	/** The name sent as SNI; an IP literal sends none on its own. **/
	var ?serverName:String;

	/** A context to reuse, which is what a session is resumed from. **/
	var ?context:SSLContext;

	/** Milliseconds a read waits; 10 s unless given. **/
	var ?timeout:Int;
}

/**
	The JDK's blocking `SSLSocket` and `SSLServerSocket`, as a peer for the
	jvm TLS backend: an independent implementation, so a case passing proves
	interoperation rather than two halves of one codebase agreeing.

	Everything here blocks. Callers run it on a thread of their own and pump
	the runtime meanwhile.
**/
class JdkTlsPeer {
	/** A context trusting `trust` and presenting `present`, as `options` say. **/
	public static function context(options:JdkPeerOptions):SSLContext {
		var blank:java.NativeArray<java.StdTypes.Char16> = new java.NativeArray(0);
		var trustManagers:Null<java.NativeArray<TrustManager>> = null;

		if (options.trust != null && options.trust.length > 0) {
			var store = KeyStore.getInstance(KeyStore.getDefaultType());
			store.load(null, null);
			var n:Int = 0;
			for (path in options.trust) {
				for (certificate in certificates(path)) {
					store.setCertificateEntry("trusted" + (n++), certificate);
				}
			}
			var factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
			factory.init(store);
			trustManagers = factory.getTrustManagers();
		}

		var keyManagers:Null<java.NativeArray<KeyManager>> = null;

		if (options.present != null) {
			var chain = certificates(options.present.chain);
			var array:java.NativeArray<JCertificate> = new java.NativeArray(chain.length);
			for (i in 0...chain.length) {
				array[i] = chain[i];
			}
			var own = KeyStore.getInstance(KeyStore.getDefaultType());
			own.load(null, null);
			own.setKeyEntry("own", cast @:privateAccess options.present.key.__native.native, blank, array);
			var factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
			factory.init(own, blank);
			keyManagers = factory.getKeyManagers();
		}

		var context = SSLContext.getInstance("TLS");
		context.init(keyManagers, trustManagers, null);
		return context;
	}

	/** Connects to 127.0.0.1:`port` and completes the handshake. **/
	public static function connect(port:Int, options:JdkPeerOptions):SSLSocket {
		var context:SSLContext = options.context != null ? options.context : context(options);
		var peer:SSLSocket = cast context.getSocketFactory().createSocket("127.0.0.1", port);

		// Bounded: jvm threads are not daemons, and one blocked here for good
		// would hold the test process open after the suite had reported.
		peer.setSoTimeout(options.timeout != null ? options.timeout : 10000);

		if (options.protocols != null) {
			peer.setEnabledProtocols(__array(options.protocols));
		}

		if (options.serverName != null) {
			var names = new JArrayList<SNIServerName>();
			names.add(cast new SNIHostName(options.serverName));
			var parameters = peer.getSSLParameters();
			parameters.setServerNames(cast names);
			peer.setSSLParameters(parameters);
		}

		try {
			peer.startHandshake();
		} catch (e:Dynamic) {
			try {
				peer.close();
			} catch (_:Dynamic) {}
			throw e;
		}
		return peer;
	}

	/** A listener on 127.0.0.1, port chosen by the system. **/
	public static function listen(options:JdkPeerOptions):SSLServerSocket {
		var context:SSLContext = options.context != null ? options.context : context(options);
		var server:SSLServerSocket = cast context.getServerSocketFactory().createServerSocket(0, 16, java.net.InetAddress.getByName("127.0.0.1"));
		server.setSoTimeout(options.timeout != null ? options.timeout : 10000);

		if (options.protocols != null) {
			server.setEnabledProtocols(__array(options.protocols));
		}

		return server;
	}

	/** Every certificate in a PEM file, in order. **/
	public static function certificates(path:String):Array<JCertificate> {
		var bytes = sys.io.File.getBytes(path);
		var all = CertificateFactory.getInstance("X.509").generateCertificates(new ByteArrayInputStream(bytes.getData()));
		var out:Array<JCertificate> = [];
		var it = all.iterator();
		while (it.hasNext()) {
			out.push(it.next());
		}
		return out;
	}

	public static function send(peer:SSLSocket, text:String):Void {
		var out = peer.getOutputStream();
		out.write(haxe.io.Bytes.ofString(text).getData());
		out.flush();
	}

	/** Reads until `length` bytes have come, or the peer stops sending. **/
	public static function receive(peer:SSLSocket, length:Int):String {
		var buffer:java.NativeArray<java.types.Int8> = new java.NativeArray(length);
		var input = peer.getInputStream();
		var got:Int = 0;

		while (got < length) {
			var chunk:java.NativeArray<java.types.Int8> = new java.NativeArray(length - got);
			var n:Int = input.read(chunk);
			if (n <= 0) {
				break;
			}
			for (i in 0...n) {
				buffer[got + i] = chunk[i];
			}
			got += n;
		}

		return haxe.io.Bytes.ofData(buffer).sub(0, got).toString();
	}

	public static function hex(bytes:java.NativeArray<java.types.Int8>):String {
		return haxe.io.Bytes.ofData(bytes).toHex();
	}

	private static function __array(values:Array<String>):java.NativeArray<String> {
		var out:java.NativeArray<String> = new java.NativeArray(values.length);
		for (i in 0...values.length) {
			out[i] = values[i];
		}
		return out;
	}
}
#end
