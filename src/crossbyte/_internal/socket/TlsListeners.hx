package crossbyte._internal.socket;

#if !js
/**
	What a server's TLS listener needs, on each target, to take certificates
	once it is bound: the handshakes it starts from then on present them, and
	a connection already accepted keeps what it began with.
**/
@:noCompletion
class TlsListeners {
	/** Drops the certificates `addSNICertificate` gave `listener`. **/
	public static function clearSni(listener:sys.net.Socket):Void {
		#if (java || jvm)
		(cast listener : crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket).clearSNICertificates();
		#elseif (cpp || neko || hl)
		@:privateAccess (cast listener : sys.ssl.Socket).altSNIContexts = null;
		#end
	}

	/**
		Makes what is set on `listener` now what its next accept uses. Only
		natively is there anything to do: there the configuration is built
		once, at `bind()`. On the jvm a setting drops the listener's context,
		made again at its next accept, and neko and HashLink build one for
		each connection they accept.
	**/
	public static function refresh(listener:sys.net.Socket):Void {
		#if cpp
		(cast listener : AlpnSocket).rebuildConfig();
		#end
	}
}
#end
