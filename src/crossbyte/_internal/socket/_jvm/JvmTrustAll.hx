package crossbyte._internal.socket._jvm;

#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte._internal.socket._jvm.JvmSslExterns.JNetSocket;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLEngine;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509Certificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509ExtendedTrustManager;

/**
	A trust manager that accepts any certificate.

	This is what `verifyCert = false` asks for, and it means what it says: the
	peer is no longer authenticated, so anything able to sit between the two ends
	can present a certificate of its own and read and rewrite the traffic. TLS
	still encrypts; it no longer tells you who you are talking to. It exists
	because a self-signed development server is a real thing people need to
	reach, and the alternative is them turning TLS off altogether.

	Nothing selects this on its own. It is installed only where `verifyCert` has
	been set to `false` explicitly; unset -- the default -- verifies.

	All six overloads are implemented, not just the two-argument pair. An
	`SSLEngine` handshake calls the three-argument `SSLEngine` forms, and a
	subclass that leaves those to the abstract base fails with
	`AbstractMethodError` at the moment the certificate would have been checked
	-- which is to say, only ever in the branch this class exists for.

	Every body is empty on purpose: to a trust manager, "trusted" is the absence
	of a thrown exception.
**/
class JvmTrustAll extends X509ExtendedTrustManager {
	public function new() {
		super();
	}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String):Void {}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String, socket:JNetSocket):Void {}

	overload override public function checkClientTrusted(chain:java.NativeArray<X509Certificate>, authType:String, engine:SSLEngine):Void {}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String):Void {}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String, socket:JNetSocket):Void {}

	overload override public function checkServerTrusted(chain:java.NativeArray<X509Certificate>, authType:String, engine:SSLEngine):Void {}

	override public function getAcceptedIssuers():java.NativeArray<X509Certificate> {
		return new java.NativeArray(0);
	}
}
#end
