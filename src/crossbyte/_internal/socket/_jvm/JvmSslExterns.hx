package crossbyte._internal.socket._jvm;

#if (java || jvm)
/**
	Externs for the JDK types the jvm TLS backend needs.

	They are declared here because Haxe ships none. `hxjava` carries externs for
	`java.io`, `java.lang`, `java.net` and part of `java.security`, but nothing
	for `javax.*` -- and the `java.security` it does carry has broken nested
	references (`KeyStore.SecretKeyEntry` resolves to `java.javax.crypto.SecretKey`,
	a package that does not exist), so a bare `import java.security.KeyStore`
	fails to compile. Everything the backend touches is therefore declared here
	rather than taken from the library.

	Two details cost a compile each and are worth stating:

	- Nested Java classes are named with `$`, not `.`. `SSLEngineResult.Status`
	  is `javax.net.ssl.SSLEngineResult$Status`; written with a dot it compiles
	  and then throws `NoSuchMethodError` at runtime against a type whose
	  descriptor names a package.
	- An extern's kind has to match Java's. `SSLSession`, `List`, `KeyManager`
	  and `TrustManager` are interfaces; any of them declared as a class compiles
	  and then throws `IncompatibleClassChangeError` the first time it is used.
	  This one has been made three times here. If something fails with "Found
	  interface X, but class was expected", the extern for X says `extern class`
	  and Java says `interface`.

	Both failures are invisible until the code runs, which is why the backend
	has an end-to-end case rather than only unit ones.
**/
@:native("java.security.SecureRandom")
extern class SecureRandom {}

@:native("java.security.Key")
extern interface Key {}

@:native("java.security.PrivateKey")
extern interface PrivateKey extends Key {
	function getAlgorithm():String;
}

@:native("java.security.cert.Certificate")
extern class Certificate {
	function getEncoded():java.NativeArray<java.types.Int8>;
}

@:native("java.security.cert.X509Certificate")
extern class X509Certificate extends Certificate {}

@:native("java.security.Principal")
extern interface Principal {}

/** An interface in Java, like SSLSession. **/
@:native("java.util.List")
extern interface JList<T> {
	function size():Int;
	function get(index:Int):T;
}

@:native("javax.net.ssl.SNIServerName")
extern class SNIServerName {}

@:native("javax.net.ssl.SNIHostName")
extern class SNIHostName extends SNIServerName {
	function new(name:String);
	function getAsciiName():String;
}

@:native("java.util.ArrayList")
extern class JArrayList<T> implements JList<T> {
	function new();
	function add(item:T):Bool;
	function size():Int;
	function get(index:Int):T;
}

/** The session mid-handshake, which is where the requested names live. **/
@:native("javax.net.ssl.ExtendedSSLSession")
extern class ExtendedSSLSession {
	function getRequestedServerNames():JList<SNIServerName>;
}

/**
	Extended so a certificate can be chosen per requested hostname.

	`SSLParameters.setSNIMatchers` only filters which names are acceptable; it
	cannot present a different certificate for each. Selecting one is the key
	manager's job, and only the "Engine" overloads are consulted when the
	handshake runs on an `SSLEngine` rather than an `SSLSocket`.
**/
@:native("javax.net.ssl.X509ExtendedKeyManager")
extern class X509ExtendedKeyManager implements KeyManager {
	function new();
	function chooseEngineServerAlias(keyType:String, issuers:java.NativeArray<Principal>, engine:SSLEngine):String;
	function chooseEngineClientAlias(keyType:java.NativeArray<String>, issuers:java.NativeArray<Principal>, engine:SSLEngine):String;
	function chooseServerAlias(keyType:String, issuers:java.NativeArray<Principal>, socket:JNetSocket):String;
	function chooseClientAlias(keyType:java.NativeArray<String>, issuers:java.NativeArray<Principal>, socket:JNetSocket):String;
	function getServerAliases(keyType:String, issuers:java.NativeArray<Principal>):java.NativeArray<String>;
	function getClientAliases(keyType:String, issuers:java.NativeArray<Principal>):java.NativeArray<String>;
	function getCertificateChain(alias:String):java.NativeArray<X509Certificate>;
	function getPrivateKey(alias:String):PrivateKey;
}

@:native("java.security.spec.KeySpec")
extern interface KeySpec {}

@:native("java.security.spec.PKCS8EncodedKeySpec")
extern class PKCS8EncodedKeySpec implements KeySpec {
	function new(encoded:java.NativeArray<java.types.Int8>);
}

@:native("java.security.KeyFactory")
extern class KeyFactory {
	static function getInstance(algorithm:String):KeyFactory;
	function generatePrivate(spec:KeySpec):PrivateKey;
}

@:native("java.io.InputStream")
extern class JInputStream {}

@:native("java.io.ByteArrayInputStream")
extern class ByteArrayInputStream extends JInputStream {
	function new(buf:java.NativeArray<java.types.Int8>);
}

@:native("java.security.cert.CertificateFactory")
extern class CertificateFactory {
	static function getInstance(type:String):CertificateFactory;
	function generateCertificate(stream:JInputStream):Certificate;
}

@:native("java.security.KeyStore")
extern class KeyStore {
	static function getInstance(type:String):KeyStore;
	static function getDefaultType():String;
	function load(stream:Null<JInputStream>, password:Null<java.NativeArray<java.StdTypes.Char16>>):Void;
	function setCertificateEntry(alias:String, cert:Certificate):Void;
	function setKeyEntry(alias:String, key:Key, password:Null<java.NativeArray<java.StdTypes.Char16>>, chain:java.NativeArray<Certificate>):Void;
}

@:native("javax.net.ssl.KeyManager")
extern interface KeyManager {}

@:native("javax.net.ssl.TrustManager")
extern interface TrustManager {}

@:native("javax.net.ssl.KeyManagerFactory")
extern class KeyManagerFactory {
	static function getInstance(algorithm:String):KeyManagerFactory;
	static function getDefaultAlgorithm():String;
	function init(ks:KeyStore, password:Null<java.NativeArray<java.StdTypes.Char16>>):Void;
	function getKeyManagers():java.NativeArray<KeyManager>;
}

@:native("javax.net.ssl.TrustManagerFactory")
extern class TrustManagerFactory {
	static function getInstance(algorithm:String):TrustManagerFactory;
	static function getDefaultAlgorithm():String;
	function init(ks:Null<KeyStore>):Void;
	function getTrustManagers():java.NativeArray<TrustManager>;
}

/** An interface in Java. Declaring it a class throws IncompatibleClassChangeError. **/
@:native("javax.net.ssl.SSLSession")
extern interface SSLSession {
	function getApplicationBufferSize():Int;
	function getPacketBufferSize():Int;
	function getPeerCertificates():java.NativeArray<Certificate>;
}

/** Nested: the `$` is required. **/
@:native("javax.net.ssl.SSLEngineResult$Status")
extern class SSLEngineResultStatus {
	function name():String;
}

/** Nested: the `$` is required. **/
@:native("javax.net.ssl.SSLEngineResult$HandshakeStatus")
extern class SSLEngineResultHandshakeStatus {
	function name():String;
}

@:native("javax.net.ssl.SSLEngineResult")
extern class SSLEngineResult {
	function getStatus():SSLEngineResultStatus;
	function getHandshakeStatus():SSLEngineResultHandshakeStatus;
	function bytesProduced():Int;
	function bytesConsumed():Int;
}

@:native("javax.net.ssl.SSLParameters")
extern class SSLParameters {
	function new();
	function setApplicationProtocols(protocols:java.NativeArray<String>):Void;
	function getApplicationProtocols():java.NativeArray<String>;
	function setServerNames(names:JList<SNIServerName>):Void;
	function setEndpointIdentificationAlgorithm(algorithm:String):Void;
}

@:native("javax.net.ssl.SSLEngine")
extern class SSLEngine {
	function setUseClientMode(mode:Bool):Void;
	function getUseClientMode():Bool;
	function setNeedClientAuth(need:Bool):Void;
	function beginHandshake():Void;
	function getHandshakeStatus():SSLEngineResultHandshakeStatus;
	function getSession():SSLSession;
	function getHandshakeSession():Null<SSLSession>;
	function getDelegatedTask():Null<java.lang.Runnable>;
	function wrap(src:java.nio.ByteBuffer, dst:java.nio.ByteBuffer):SSLEngineResult;
	function unwrap(src:java.nio.ByteBuffer, dst:java.nio.ByteBuffer):SSLEngineResult;
	function closeOutbound():Void;
	function closeInbound():Void;
	function isOutboundDone():Bool;
	function isInboundDone():Bool;
	function getSSLParameters():SSLParameters;
	function setSSLParameters(params:SSLParameters):Void;
	function getApplicationProtocol():Null<String>;
}

@:native("javax.net.ssl.SSLContext")
extern class SSLContext {
	static function getInstance(protocol:String):SSLContext;
	function init(km:Null<java.NativeArray<KeyManager>>, tm:Null<java.NativeArray<TrustManager>>, sr:Null<SecureRandom>):Void;
	function createSSLEngine():SSLEngine;
	function getSocketFactory():SSLSocketFactory;
}

/**
	The blocking client socket. Unusable by the runtime itself -- that is why
	the backend is built on SSLEngine -- but exactly right as an independent
	peer in a test, where it exercises the server against the JDK's own TLS
	stack rather than against more of CrossByte.
**/
@:native("java.net.Socket")
extern class JNetSocket {
	function setSoTimeout(milliseconds:Int):Void;
}

@:native("javax.net.ssl.SSLSocketFactory")
extern class SSLSocketFactory {
	// Returns java.net.Socket, not SSLSocket. Declaring the narrower type
	// compiles and then fails to link: the descriptor is part of the name.
	@:overload function createSocket(host:String, port:Int):JNetSocket;
}

@:native("javax.net.ssl.SSLSocket")
extern class SSLSocket extends JNetSocket {
	function startHandshake():Void;
	function getSSLParameters():SSLParameters;
	function setSSLParameters(params:SSLParameters):Void;
	function getApplicationProtocol():String;
	function getSession():SSLSession;
	function close():Void;
}

@:native("java.util.Base64")
extern class Base64 {
	static function getMimeDecoder():Base64Decoder;
}

/** Nested: the `$` is required. **/
@:native("java.util.Base64$Decoder")
extern class Base64Decoder {
	@:overload function decode(src:String):java.NativeArray<java.types.Int8>;
}
#end
