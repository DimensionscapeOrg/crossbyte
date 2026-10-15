package crossbyte._internal.socket._jvm;

#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns.JNetSocket;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLEngine;
import crossbyte._internal.socket._jvm.JvmSslExterns.TrustManager;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509Certificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509ExtendedTrustManager;

/**
	A trust manager the JDK built, with every certificate the peer presented
	held to its validity period as well.

	PKIX path validation does not check a trust anchor's dates, and a
	certificate pinned as its own authority (`certAuthority` set to a
	self-signed certificate, as a private cluster's often is) is the anchor:
	the jvm took one long after it expired, where natively mbedTLS and on
	Node OpenSSL refuse it. Checking each certificate the peer sent, as
	OpenSSL does, makes the jvm refuse it too; a certificate issued by an
	authority was checked already, and is again for nothing.

	All six overloads, as `JvmTrustAll` explains: an `SSLEngine` handshake
	asks the `SSLEngine` forms.
**/
class JvmDatedTrust extends X509ExtendedTrustManager {
	final __inner:X509ExtendedTrustManager;

	/** `managers`, each X.509 one wrapped. **/
	public static function around(managers:java.NativeArray<TrustManager>):java.NativeArray<TrustManager> {
		for (i in 0...managers.length) {
			if (Std.isOfType(managers[i], X509ExtendedTrustManager)) {
				managers[i] = cast new JvmDatedTrust(cast managers[i]);
			}
		}
		return managers;
	}

	public function new(inner:X509ExtendedTrustManager) {
		super();
		__inner = inner;
	}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String):Void {
		__inner.checkClientTrusted(chain, authType);
		__dated(chain);
	}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String, socket:JNetSocket):Void {
		__inner.checkClientTrusted(chain, authType, socket);
		__dated(chain);
	}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String, engine:SSLEngine):Void {
		__inner.checkClientTrusted(chain, authType, engine);
		__dated(chain);
	}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String):Void {
		__inner.checkServerTrusted(chain, authType);
		__dated(chain);
	}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String, socket:JNetSocket):Void {
		__inner.checkServerTrusted(chain, authType, socket);
		__dated(chain);
	}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String, engine:SSLEngine):Void {
		__inner.checkServerTrusted(chain, authType, engine);
		__dated(chain);
	}

	override public function getAcceptedIssuers():java.NativeArray<X509Certificate> {
		return __inner.getAcceptedIssuers();
	}

	/** Throws, as the JDK's own checks do, for a certificate expired or not yet valid. **/
	static function __dated(chain:java.NativeArray<X509Certificate>):Void {
		for (i in 0...chain.length) {
			chain[i].checkValidity();
		}
	}
}
#end
