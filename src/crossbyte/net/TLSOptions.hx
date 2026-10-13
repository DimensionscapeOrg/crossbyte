package crossbyte.net;

// Not built for the browser, which does its own TLS and takes no settings
// for it, and has no Certificate or Key.
#if !(js && !nodejs)

/**
	The TLS a `tls://` or `wss://` `NetHost` or `NetConnection` runs with,
	given to either one's constructor. The fields are named as `Socket` and
	`HTTPTLSOptions` name them, and each is read by the end it means
	something to:

	- `certificate` and `key`: what this end presents. A host needs both; a
	  connection presents them to a server that asks for a client
	  certificate (mutual TLS), as `Socket.setCertificate` does.
	- `certAuthority`: what a connection trusts, in place of the system's
	  authorities: a private CA, or a development server's own certificate.
	- `verifyCert`: whether a connection checks the server at all; `true`
	  unless `false`. Off, the traffic is still encrypted, but anyone able
	  to sit between the two ends can read it.
	- `clientAuthority`: for a host, the authority a client's certificate
	  must be issued by; a client presenting none, or one it did not issue,
	  is dropped in the handshake (`ServerSocket.requireClientCertificate`).

	A host ignores `certAuthority` and `verifyCert`, and a connection
	`clientAuthority`, so one set of options can describe both ends of a
	link between hosts of one's own:

	```haxe
	// Given hostCertificate:crossbyte.net.Certificate, hostKey:crossbyte.net.Key, clusterAuthority:crossbyte.net.Certificate.
	var tls:crossbyte.net.TLSOptions = {
		certificate: hostCertificate,
		key: hostKey,
		certAuthority: clusterAuthority,
		clientAuthority: clusterAuthority
	};
	var host = new crossbyte.net.NetHost("tls://0.0.0.0:7000", null, null, null, true, tls);
	var link = new crossbyte.net.NetConnection("tls://hub.internal:7000", null, null, null, null, false, tls);
	```
**/
typedef TLSOptions = {
	/** The certificate this end presents: a host's, or a client's to a server that asks. **/
	var ?certificate:Certificate;

	/** The private key belonging to `certificate`. **/
	var ?key:Key;

	/** For a connection: the authority trusted in place of the system's. **/
	var ?certAuthority:Certificate;

	/** For a connection: whether the server's certificate is checked; `true` unless `false`. **/
	var ?verifyCert:Bool;

	/** For a host: the authority every client's certificate must be issued by, requiring one. **/
	var ?clientAuthority:Certificate;
}
#end
