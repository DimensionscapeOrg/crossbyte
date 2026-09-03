package crossbyte._internal.socket._jvm;

#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSslExterns;
import crossbyte._internal.socket._jvm.JvmSslExterns.Certificate as JCertificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.ExtendedSSLSession;
import crossbyte._internal.socket._jvm.JvmSslExterns.PrivateKey;
import crossbyte._internal.socket._jvm.JvmSslExterns.Principal;
import crossbyte._internal.socket._jvm.JvmSslExterns.SNIHostName;
import crossbyte._internal.socket._jvm.JvmSslExterns.SSLEngine;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509Certificate;
import crossbyte._internal.socket._jvm.JvmSslExterns.X509ExtendedKeyManager;

/** One certificate and the test that decides whether it is the right one. **/
typedef SniEntry = {
	var matches:String->Bool;
	var certificate:JCertificate;
	var key:PrivateKey;
}

/**
	Chooses which certificate to present from the hostname the client asked for.

	`SSLParameters.setSNIMatchers` is the obvious-looking API and the wrong one:
	it decides which names a server will *accept*, not which certificate it
	answers them with. Presenting different material per name is the key
	manager's job, so this is one.

	Only the `Engine` overloads matter here. A handshake running on an
	`SSLEngine` never calls `chooseServerAlias`, and a key manager that
	implements only the `Socket` ones silently presents the default certificate
	to every name -- which looks like SNI working right up until someone checks
	which certificate came back.

	The requested names are read from the *handshake* session. The ordinary
	session is not populated until the handshake finishes, by which point the
	certificate has already been chosen.
**/
class JvmSniKeyManager extends X509ExtendedKeyManager {
	private static inline var DEFAULT_ALIAS:String = "default";
	private static inline var SNI_PREFIX:String = "sni";

	private var __default:SniEntry;
	private var __entries:Array<SniEntry>;

	public function new(fallback:SniEntry, entries:Array<SniEntry>) {
		super();
		__default = fallback;
		__entries = entries;
	}

	/**
		The alias for whichever certificate answers this handshake.

		@return An alias naming the entry to present, or the default when the
		client asked for nothing or for a name none of the entries claims.
	**/
	override public function chooseEngineServerAlias(keyType:String, issuers:java.NativeArray<Principal>,
			engine:SSLEngine):String {
		var requested = __requestedName(engine);

		if (requested != null) {
			for (i in 0...__entries.length) {
				var entry = __entries[i];

				if (entry.matches(requested) && __suits(entry, keyType)) {
					return SNI_PREFIX + i;
				}
			}
		}

		return __suits(__default, keyType) ? DEFAULT_ALIAS : null;
	}

	override public function getCertificateChain(alias:String):java.NativeArray<X509Certificate> {
		var entry = __entryFor(alias);

		if (entry == null) {
			return null;
		}

		var chain:java.NativeArray<X509Certificate> = new java.NativeArray(1);
		chain[0] = cast entry.certificate;
		return chain;
	}

	override public function getPrivateKey(alias:String):PrivateKey {
		var entry = __entryFor(alias);
		return entry == null ? null : entry.key;
	}

	// A server key manager, so the client half answers nothing.
	override public function getClientAliases(keyType:String, issuers:java.NativeArray<Principal>):java.NativeArray<String> {
		return null;
	}

	override public function chooseClientAlias(keyType:java.NativeArray<String>, issuers:java.NativeArray<Principal>,
			socket:JvmSslExterns.JNetSocket):String {
		return null;
	}

	override public function getServerAliases(keyType:String, issuers:java.NativeArray<Principal>):java.NativeArray<String> {
		var aliases:java.NativeArray<String> = new java.NativeArray(__entries.length + 1);
		aliases[0] = DEFAULT_ALIAS;

		for (i in 0...__entries.length) {
			aliases[i + 1] = SNI_PREFIX + i;
		}

		return aliases;
	}

	/**
		Never reached on an SSLEngine handshake, and answered anyway.

		Returning the default rather than null keeps a socket-driven handshake
		working if one ever arrives here, instead of failing with no certificate.
	**/
	override public function chooseServerAlias(keyType:String, issuers:java.NativeArray<Principal>,
			socket:JvmSslExterns.JNetSocket):String {
		return __suits(__default, keyType) ? DEFAULT_ALIAS : null;
	}

	@:noCompletion private function __entryFor(alias:String):SniEntry {
		if (alias == DEFAULT_ALIAS) {
			return __default;
		}

		if (alias != null && StringTools.startsWith(alias, SNI_PREFIX)) {
			var index = Std.parseInt(alias.substr(SNI_PREFIX.length));

			if (index != null && index >= 0 && index < __entries.length) {
				return __entries[index];
			}
		}

		return null;
	}

	/**
		Whether this entry's key is of the kind the handshake is asking for.

		The method is called once per key type the negotiated cipher suite could
		use, so answering for a type the key cannot serve offers material the
		peer then rejects.
	**/
	@:noCompletion private function __suits(entry:SniEntry, keyType:String):Bool {
		if (entry == null || entry.key == null || entry.certificate == null) {
			return false;
		}

		if (keyType == null) {
			return true;
		}

		var algorithm = try {
			entry.key.getAlgorithm();
		} catch (e:Dynamic) {
			null;
		}

		if (algorithm == null) {
			return true;
		}

		// keyType arrives as "RSA", "EC", or a signature-qualified form such as
		// "RSASSA-PSS"; matching on the prefix covers both.
		return StringTools.startsWith(keyType, algorithm);
	}

	/** The first hostname the client asked for, or null if it asked for none. **/
	@:noCompletion private function __requestedName(engine:SSLEngine):Null<String> {
		if (engine == null) {
			return null;
		}

		return try {
			var session:ExtendedSSLSession = cast engine.getHandshakeSession();

			if (session == null) {
				return null;
			}

			var names = session.getRequestedServerNames();

			if (names == null || names.size() == 0) {
				return null;
			}

			var first:SNIHostName = cast names.get(0);
			first == null ? null : first.getAsciiName();
		} catch (e:Dynamic) {
			// A peer that sent no SNI, or a JDK that answers differently: not a
			// failure, just nothing to match on.
			null;
		}
	}
}
#end
