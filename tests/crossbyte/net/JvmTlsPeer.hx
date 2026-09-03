package crossbyte.net;

#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManager;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyManagerFactory;
import crossbyte._internal.socket._jvm.JvmSslExterns.KeyStore;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLContext;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLSocket;
import crossbyte._internal.socket._jvm.JvmSslExterns.TrustManagerFactory;

/**
 * A TLS client built on the JDK's own blocking `SSLSocket`.
 *
 * Deliberately not CrossByte's backend. The jvm backend is built on `SSLEngine`
 * precisely because `SSLSocket` blocks and cannot be driven by the runtime --
 * which makes it an independent implementation, and therefore worth something
 * as a peer in a test. A handshake that two halves of the same code agree on
 * proves considerably less.
 *
 * It blocks, so callers run it on a thread of their own and pump the runtime
 * meanwhile.
 */
class JvmTlsPeer {
	/**
	 * Connects, handshakes, and reports the agreed ALPN protocol.
	 *
	 * @param trusted The certificate to trust. A self-signed certificate is not
	 *        in the default store, and trusting everything would stop this
	 *        proving the server presented a chain that validates.
	 * @param protocols ALPN names to offer, or null to offer none.
	 * @param present A certificate and key to present when the server asks for
	 *        one, or null to present nothing.
	 */
	public static function handshake(host:String, port:Int, trusted:Certificate, ?protocols:Array<String>,
			?present:{certificate:Certificate, key:Key}):Null<String> {
		var blank:java.NativeArray<java.StdTypes.Char16> = new java.NativeArray(0);

		var trust = KeyStore.getInstance(KeyStore.getDefaultType());
		trust.load(null, null);
		trust.setCertificateEntry("ca", @:privateAccess trusted.__native.native);

		var trustFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
		trustFactory.init(trust);

		var managers:Null<java.NativeArray<KeyManager>> = null;

		if (present != null) {
			var own = KeyStore.getInstance(KeyStore.getDefaultType());
			own.load(null, null);
			var chain:java.NativeArray<crossbyte._internal.socket._jvm.JvmSslExterns.Certificate> = new java.NativeArray(1);
			chain[0] = @:privateAccess present.certificate.__native.native;
			own.setKeyEntry("own", cast @:privateAccess present.key.__native.native, blank, chain);

			var keyFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
			keyFactory.init(own, blank);
			managers = keyFactory.getKeyManagers();
		}

		var context = SSLContext.getInstance("TLS");
		context.init(managers, trustFactory.getTrustManagers(), null);

		var peer:SSLSocket = cast context.getSocketFactory().createSocket(host, port);

		// Bounded so a server that never answers cannot strand this thread.
		// Haxe's jvm threads are not daemons, so one blocked here would keep
		// the test process alive long after the suite had finished reporting.
		peer.setSoTimeout(10000);

		if (protocols != null && protocols.length > 0) {
			var names:java.NativeArray<String> = new java.NativeArray(protocols.length);
			for (i in 0...protocols.length) {
				names[i] = protocols[i];
			}

			var parameters = peer.getSSLParameters();
			parameters.setApplicationProtocols(names);
			peer.setSSLParameters(parameters);
		}

		peer.startHandshake();

		var negotiated = try {
			peer.getApplicationProtocol();
		} catch (e:Dynamic) {
			null;
		}

		// TLS 1.3 sends the client's certificate after the server's Finished,
		// so a client that closes the instant startHandshake returns can pull
		// the connection down before that flight lands -- the server then sees
		// an end-of-file rather than the certificate it asked for. A real
		// client goes on to send a request; this one just waits a moment.
		Sys.sleep(0.25);
		peer.close();
		return (negotiated == null || negotiated == "") ? null : negotiated;
	}
}
#end
