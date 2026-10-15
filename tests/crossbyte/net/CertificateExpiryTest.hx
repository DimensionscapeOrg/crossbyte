#if (cpp || hl || neko || java || jvm || nodejs || eval)
package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.TlsRefusalSupport.TlsCase;
import crossbyte.net.TlsRefusalSupport.TlsClient;
#end
import utest.Assert;
import utest.Async;

/**
	A certificate outside its dates is refused, on every target with TLS:
	one that has expired, and one not valid yet. By each of CrossByte's own
	clients (`Socket`, `WebSocket`, `NetConnection` and `URLLoader`), and by
	a server that requires a client's certificate. Both when an authority
	the other end trusts issued it and when it is self-signed and pinned as
	its own authority.

	The jvm let a pinned one through: PKIX checks no trust anchor's dates,
	and a pinned self-signed certificate is the anchor. Natively mbedTLS and
	on Node OpenSSL refused it; the jvm now holds every certificate a peer
	presents to its dates as well (`JvmDatedTrust`).

	Each set of cases runs beside the same certificates in date, presented
	the same way, which have to be let in: a client that cannot connect at
	all refuses too, and would pass the rest for the wrong reason.

	The certificates below are kept here rather than made by a test: one
	already expired stays as it is, one dated 2099 is not valid yet for as
	long as anyone will run this, and nothing has to have `openssl` to run
	these. Each names `localhost` and `127.0.0.1`, the address written as a
	DNS name too, since mbedTLS compares the name it was given as text; so
	its dates are all that is wrong with it.
**/
class CertificateExpiryTest extends utest.Test {
	#if (cpp || hl || neko || java || jvm || nodejs)
	@:timeout(30000)
	public function testAnExpiredCertificateIsRefusedEvenPinned(async:Async):Void {
		__probe(Certificate.fromPem(EXPIRED_CERTIFICATE), "a certificate that expired in 2020 was let in", async);
	}

	@:timeout(30000)
	public function testACertificateNotYetValidIsRefusedEvenPinned(async:Async):Void {
		__probe(Certificate.fromPem(NOT_YET_VALID_CERTIFICATE), "a certificate not valid until 2099 was let in", async);
	}

	/** A secure `Socket` refuses a server presenting a certificate outside its dates. **/
	@:timeout(90000)
	public function testASocketRefusesACertificateOutsideItsDates(async:Async):Void {
		TlsRefusalSupport.through(SocketClient, __cases(), () -> async.done());
	}

	#if !(hl || neko)
	/**
		A `wss://` `WebSocket` refuses one. Not on neko and HashLink, where a
		`WebSocket` client cannot connect: its handshake key needs secure
		random bytes, which neither has.
	**/
	@:timeout(90000)
	public function testAWebSocketRefusesACertificateOutsideItsDates(async:Async):Void {
		TlsRefusalSupport.through(WebSocketClient, __cases(), () -> async.done());
	}
	#end

	/**
		A `tls://` or `wss://` `NetConnection` given an authority to trust
		refuses a `NetHost` presenting one. Only `tls://` on neko and
		HashLink, for the reason above.
	**/
	@:timeout(120000)
	public function testANetConnectionRefusesACertificateOutsideItsDates(async:Async):Void {
		TlsRefusalSupport.throughEach(TlsRefusalSupport.netConnections(), __cases(), () -> async.done());
	}

	/**
		An `https` `URLLoader` refuses one: over HTTP/1.1, over HTTP/2 where
		TLS can negotiate it, and with the server's key pinned as well where a
		pin can be checked.
	**/
	@:timeout(180000)
	public function testAnHttpsLoadRefusesACertificateOutsideItsDates(async:Async):Void {
		TlsRefusalSupport.throughEach(TlsRefusalSupport.loaders(), __cases(), () -> async.done());
	}

	/**
		And a server requiring a client certificate refuses one outside its
		dates, issued by the authority it requires or pinned as that
		authority itself.
	**/
	@:timeout(90000)
	public function testAServerRefusesAClientCertificateOutsideItsDates(async:Async):Void {
		TlsRefusalSupport.presentEach({certificate: Certificate.fromPem(ISSUED), key: Key.fromPem(DATED_KEY)}, Certificate.fromPem(AUTHORITY), null,
			__cases(), () -> async.done());
	}

	/** `pinned`, presented and pinned as its own authority, through `TlsProbe`: refused. **/
	private static function __probe(pinned:Certificate, message:String, async:Async):Void {
		var server = new ServerSocket(true);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> try e.socket.close() catch (_:Dynamic) {});
		server.setCertificate(pinned, Key.fromPem(DATED_KEY));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			TlsProbe.run(server.localPort, {serverName: "localhost", trust: pinned}, function(outcome) {
				Assert.notNull(outcome.error, message);
				server.close();
				async.done();
			});
		});
	}

	#end

	// The cases, on eval too, where OpenSslPeerTest holds a Socket to them.
	#if (cpp || hl || neko || java || jvm || nodejs || eval)
	/**
		Each certificate, beside what the other end trusts: issued by
		`AUTHORITY`, then self-signed and pinned. Only those in their dates
		are let in.
	**/
	private static function __cases():Array<TlsCase> {
		var authority:Certificate = Certificate.fromPem(AUTHORITY);
		var expired:Certificate = Certificate.fromPem(EXPIRED_CERTIFICATE);
		var future:Certificate = Certificate.fromPem(NOT_YET_VALID_CERTIFICATE);
		return [
			TlsRefusalSupport.tlsCase("a certificate its authority issued, in its dates", ISSUED, DATED_KEY, authority, true),
			TlsRefusalSupport.tlsCase("a certificate its authority issued that expired in 2020", ISSUED_EXPIRED, DATED_KEY, authority, false),
			TlsRefusalSupport.tlsCase("a certificate its authority issued that is not valid until 2099", ISSUED_NOT_YET_VALID, DATED_KEY, authority, false),
			TlsRefusalSupport.tlsCase("a self-signed certificate pinned as its own authority, in its dates", AUTHORITY, AUTHORITY_KEY, authority, true),
			TlsRefusalSupport.tlsCase("a self-signed certificate pinned as its own authority that expired in 2020", EXPIRED_CERTIFICATE, DATED_KEY,
				expired, false),
			TlsRefusalSupport.tlsCase("a self-signed certificate pinned as its own authority that is not valid until 2099", NOT_YET_VALID_CERTIFICATE,
				DATED_KEY, future, false)
		];
	}
	#end

	/** Self-signed for `localhost` and `127.0.0.1`, valid for 1 January 2020 alone. **/
	public static final EXPIRED_CERTIFICATE:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDMDCCAhigAwIBAgIUUtdpcCqwCP2B2guOa6yO5R3HAIMwDQYJKoZIhvcNAQEL",
		"BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIwMDEwMTAwMDAwMFoXDTIwMDEw",
		"MjAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF",
		"AAOCAQ8AMIIBCgKCAQEAlJSZil++936YOc7990bxDgKOMWWhsYcUBSE51+Nixw3q",
		"hFoAQkgbC9Pz7Laz71NZd8jl5vryfKbOIAd2yLsF5qbUzAlBwZW5Qf/JM1eLFsKH",
		"l6tGfQnu/MEJtBbf61DOWBIQqAMe3o9S8s6CFIRRbpqMf+dqAF88EV7OW3C2Th1O",
		"Lc9qttkFgV3OdshKtPKI2XqvxMy+cRzm3F7yIED6m2sFZif7gaXd/jUvkOk14txO",
		"1Vb28itrAyFHylGjFWU2QrjEsVGmxUjnY93XdIAIbL+XMmkreNQFmdRcCyC4FnQA",
		"mZTKs8D7KKrxC2NqAr8XeBFFS12nxXCmbc4Y3NMlMQIDAQABo3oweDAdBgNVHQ4E",
		"FgQU3X22eL33Xl8o+2G6dkb0cebyOU4wHwYDVR0jBBgwFoAU3X22eL33Xl8o+2G6",
		"dkb0cebyOU4wDwYDVR0TAQH/BAUwAwEB/zAlBgNVHREEHjAcgglsb2NhbGhvc3SC",
		"CTEyNy4wLjAuMYcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAdOg4H+RCPtiDOf/p",
		"bNU95nMaNK4fITg8po2HvXelWAeWkHVSL3BP0XJ057aPZRJv4Ol79rWhibudtlM3",
		"uEkZtx54DZbpoPjl5NgIWw9XbZwzdey1nH81KrIA5tvG4g+fICxmi0zfPVY7ZKah",
		"6uKG+WF3E1mPQXUa5QzpeTcjGGI2CailuCS5+7jgqNBCHZ3DIvv3wofgRK+BZVrb",
		"XmulJoqbrq9X7y0nXE0OYSpvEwYLx0QIdNNnZEJAReQpejn22ifMJPQhV62LoPUv",
		"AqWIPbOLTufEqppSWmjxDP8JBCOTTdP6u5/1NRspdPoY9uaAMW3nERyFnDqwyf1Y",
		"JsyQqQ==",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** Self-signed for `localhost` and `127.0.0.1`, valid for 1 January 2099 alone. **/
	public static final NOT_YET_VALID_CERTIFICATE:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDNDCCAhygAwIBAgIUO/vHc9rGGCf1/N6Yg2fhPYm4srIwDQYJKoZIhvcNAQEL",
		"BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCIYDzIwOTkwMTAxMDAwMDAwWhgPMjA5",
		"OTAxMDIwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcN",
		"AQEBBQADggEPADCCAQoCggEBAJSUmYpfvvd+mDnO/fdG8Q4CjjFlobGHFAUhOdfj",
		"YscN6oRaAEJIGwvT8+y2s+9TWXfI5eb68nymziAHdsi7Beam1MwJQcGVuUH/yTNX",
		"ixbCh5erRn0J7vzBCbQW3+tQzlgSEKgDHt6PUvLOghSEUW6ajH/nagBfPBFezltw",
		"tk4dTi3ParbZBYFdznbISrTyiNl6r8TMvnEc5txe8iBA+ptrBWYn+4Gl3f41L5Dp",
		"NeLcTtVW9vIrawMhR8pRoxVlNkK4xLFRpsVI52Pd13SACGy/lzJpK3jUBZnUXAsg",
		"uBZ0AJmUyrPA+yiq8QtjagK/F3gRRUtdp8Vwpm3OGNzTJTECAwEAAaN6MHgwHQYD",
		"VR0OBBYEFN19tni9915fKPthunZG9HHm8jlOMB8GA1UdIwQYMBaAFN19tni9915f",
		"KPthunZG9HHm8jlOMA8GA1UdEwEB/wQFMAMBAf8wJQYDVR0RBB4wHIIJbG9jYWxo",
		"b3N0ggkxMjcuMC4wLjGHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBAFkbi9IzpfmR",
		"yCWWJ8gd3ol+ShDpD7122cV0RWq36vBOabCld5FfNwQj7s5HI55DsRYw5lckUtcY",
		"M2GlCEuxW+j6UKCsE1nTa/tR5rxFia0k8O1jLwibFPkNbtEo4bALFfTfOBsDsuxY",
		"x83oWT+xgupZBtWgcPO1PxpJzHrX948GneDOcUDxBKXPb2DneIgrNWuV4OIs/pQH",
		"AaPAdj7BQqT8cVG+1jkF6LL778ci0yNTLfBSIgwM5cx7wn14K7d4BVydJmfrp/Iy",
		"/I9fca0lUmtFGmVFEOPIX/FoM1UZ+hSz8OoXTQjf7xA/IKYOTD9/11uAKsYrF0bY",
		"QFFyC6Ov4sI=",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** An authority, valid from 2020 to 2120, which issued the three below; it names `localhost` and `127.0.0.1` too, so it can be presented itself. **/
	public static final AUTHORITY:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDXDCCAkSgAwIBAgIUcXrh98nPH6is+AA0Cc9pHqX7WzMwDQYJKoZIhvcNAQEL",
		"BQAwKTEnMCUGA1UEAwweQ3Jvc3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCAX",
		"DTIwMDEwMTAwMDAwMFoYDzIxMjAwMTAxMDAwMDAwWjApMScwJQYDVQQDDB5Dcm9z",
		"c0J5dGUgRGF0ZWQgVGVzdCBBdXRob3JpdHkwggEiMA0GCSqGSIb3DQEBAQUAA4IB",
		"DwAwggEKAoIBAQDEJrNFc1qQr11afuhClF+bq2DOsUgosihqAXj+L6vr6O+nM1/2",
		"dHgGQuOftsbqcEsLv770yqG9OUL+BtwvQT6OWTAONuPq+zbmp/M5O7lC4fof6RZl",
		"VVfdaaWW1+omCIdTQHqknRU6lvnGVhWI5AxX6mnfC2QK/xToax/3cjk0azBwSS1g",
		"H2cEL1QcYv28URSCPKpGwYvf6kRxWJCdjnQeYsjSD3Qxoej9dZTn1FVNQ7/wKP6+",
		"S8g6P50eD068ScFWLx8FA0uj49xjxwgqQ8lpbdTfAYNqLWH68GZLii04BOCqBLhh",
		"xVEVRb6Z62Z5USn/TMoN5d86QPtAUDp5MdsFAgMBAAGjejB4MB0GA1UdDgQWBBSJ",
		"4FHT2mpmgj9GnVa3ybpx0fOErjAfBgNVHSMEGDAWgBSJ4FHT2mpmgj9GnVa3ybpx",
		"0fOErjAPBgNVHRMBAf8EBTADAQH/MCUGA1UdEQQeMByCCWxvY2FsaG9zdIIJMTI3",
		"LjAuMC4xhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQCmtNsHLyVZC3H20LtDjnSI",
		"GphMM2eb4jQqDRdKuPIWGNElI4AoUBB5L7q5xUyi+UWNQdlFlbQRWjqy1lE1B2qy",
		"Egyqs/WPEjkil2c9QT4iPQcb1IRd/C4gSUbtYXRfHacAy5t/VddhNXzyljOd6mN1",
		"zaJFNHGNnWFw28luJrzK/Bja6RdhlNkOmN/vQcRNwrvyuAM798pd2X9qlr09zmtX",
		"G+tRrxdzBAtwKMKBP15EuqNp68z2Y5PASaYYSQtl1SU5wSQB25zLzopDLx0CUU7E",
		"1DyDMEEsY3gH/dS36M7twr/YnYxXsYex3AKGjdD7HyPHe3Cp9BTNTk+JkwqXPqQa",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** The key of `AUTHORITY`. **/
	public static final AUTHORITY_KEY:String = [
		"-----BEGIN PRIVATE KEY-----",
		"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDEJrNFc1qQr11a",
		"fuhClF+bq2DOsUgosihqAXj+L6vr6O+nM1/2dHgGQuOftsbqcEsLv770yqG9OUL+",
		"BtwvQT6OWTAONuPq+zbmp/M5O7lC4fof6RZlVVfdaaWW1+omCIdTQHqknRU6lvnG",
		"VhWI5AxX6mnfC2QK/xToax/3cjk0azBwSS1gH2cEL1QcYv28URSCPKpGwYvf6kRx",
		"WJCdjnQeYsjSD3Qxoej9dZTn1FVNQ7/wKP6+S8g6P50eD068ScFWLx8FA0uj49xj",
		"xwgqQ8lpbdTfAYNqLWH68GZLii04BOCqBLhhxVEVRb6Z62Z5USn/TMoN5d86QPtA",
		"UDp5MdsFAgMBAAECggEABSfJPXGPN09MolTEkP9qVeKWvEf/kAZCtqqMPg4NtDke",
		"l2PryUP9ZZi7d9arerzx1AC5qaBryNfo8VlHzzwlQ0OH1k/OBL6OjlhqtZ3ivCXJ",
		"V65eJtKr6QdeUU0ie9ZsjB0dPBde1/fg37wie8MWqfbgynp3qixTJdqu7+eCJmUB",
		"CZ6P4wD+QVaDfJ9HhIk0AZP4GY6XlE/lnST8AmUcuN4dsQFcjjjgHb8dGrQpl03+",
		"EkdHfJI+vuvS23lFIObR6V+XvzUdPIMB1ueWoIyLGjJ/rcJca0apVnI4gCQKsNDj",
		"9LV4UCHjQdSKedP/75VO+035AQ38lVDVXLIKcPEizwKBgQDqv//5mq2x6DFGmWNV",
		"IWIZTsCn+gtLqYltYFUBomFvH+lcFVXR1O6MOw4hwRCIKGaLM66l15uNdHeyFGXi",
		"aQnNWU79pxgD9mgrlACjx2SZaGl3onz7dJBDgZTkPdTZ2HJyGfjHPtNFiS2NwZZ0",
		"2/GhLoOiWFFD9Vs5sJ0VVUaKFwKBgQDV6Dodw/nOU2NdOg93SlkXLKbJE5zkAdge",
		"nxTGlVou1Xqa3bYO6t33YbEdIHutHvsr7WWAO9Bb4/DSZZCpmx2mOuyYvUe7EDSr",
		"/pnzHc/bZxrTDf5Mtqkj9QBpQR/8hn+qSyv3cAzQNwnztPatwb/By4Q5KxEhbdrh",
		"XKmv9H9hQwKBgBfR561yLpHQ178sLVIkEwoyXYYt7xt8Vn+MuNNzoKNf/5PiblTe",
		"YF5GV8bBCmZmgxE4603UtOoDmWmufDAfLGlz2HoQjHVKeYOCfxYfU2vlll4XVMtH",
		"JqRS78LBK2n3dpVxYTcGfvWdV8v8isHM15XdXGoKwCQ/L0SJUUcq4f99AoGASCHr",
		"lyYDE0SjeUie9ocny9zO0Xe/rFPC4XCbvOuYYbqzgY3KWvVwrH9RDpVpn1OXN5Ty",
		"aW/CL3qKNyjww4D/WpL8PfV2PuqUGHvexlEDSuVV8l4BpzThjLKN1PCVLL7eRjrb",
		"NLGgYIZu4LPhi26Oj3dluzF+sVsuOFjbD+7PFakCgYEAxExHq4PYI8jR1ebSNwW0",
		"Alntij1KZGg7Ns8IdMzPHniN5p36Tw5uTKlHGWoQ2t5PrRRa97z05rW1BSOlcyVV",
		"uPE3KXb2O1ysj/i2GWqlnxNHdN9yn+TcUDDrOAZRG3/F65Qclxtttbe08M7Fei2h",
		"mn2Q8d6o3tnhKVFW5WKI3EI=",
		"-----END PRIVATE KEY-----"
	].join("\n");

	/** For `localhost` and `127.0.0.1`, issued by `AUTHORITY` for a server or a client, valid from 2020 to 2120. **/
	public static final ISSUED:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDYzCCAkugAwIBAgICA+kwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCAXDTIwMDEwMTAwMDAwMFoYDzIx",
		"MjAwMTAxMDAwMDAwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3",
		"DQEBAQUAA4IBDwAwggEKAoIBAQCUlJmKX773fpg5zv33RvEOAo4xZaGxhxQFITnX",
		"42LHDeqEWgBCSBsL0/PstrPvU1l3yOXm+vJ8ps4gB3bIuwXmptTMCUHBlblB/8kz",
		"V4sWwoeXq0Z9Ce78wQm0Ft/rUM5YEhCoAx7ej1LyzoIUhFFumox/52oAXzwRXs5b",
		"cLZOHU4tz2q22QWBXc52yEq08ojZeq/EzL5xHObcXvIgQPqbawVmJ/uBpd3+NS+Q",
		"6TXi3E7VVvbyK2sDIUfKUaMVZTZCuMSxUabFSOdj3dd0gAhsv5cyaSt41AWZ1FwL",
		"ILgWdACZlMqzwPsoqvELY2oCvxd4EUVLXafFcKZtzhjc0yUxAgMBAAGjgacwgaQw",
		"HQYDVR0OBBYEFN19tni9915fKPthunZG9HHm8jlOMB8GA1UdIwQYMBaAFIngUdPa",
		"amaCP0adVrfJunHR84SuMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMB0G",
		"A1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjAlBgNVHREEHjAcgglsb2NhbGhv",
		"c3SCCTEyNy4wLjAuMYcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAOEBuJXXWxaf9",
		"rMiehPw3X4fAKO91b58uk8tjjl10hHCMGkr090040lA3qIuXg1+mLZs5vbe+1kOe",
		"J1CrwVTp7ijIxaHa2ZyILwEfcJZhdS3M7MYBV/Y0DZktEJCN51e4YEM8d7rG+qeW",
		"wYtIImXnF0tHI5Y169f5UHJLwr+iFcaZ8oBMy14TXwwV7/o/D6eMN1qO+kiVgST+",
		"AjnZdy7FvPVnP4z7yDymONLPAP0Y/7JNzTFbSk/7g0Vt85lC6w9wCbZixkWNNUyE",
		"+DPHY+RmfowDHhT5Y2qxWlWekSrBxc9wv77Rw3asHNmBmNeTBusnrPgrVGIH9Ksf",
		"5HHjXfFaSQ==",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** As `ISSUED`, valid for 1 January 2020 alone. **/
	public static final ISSUED_EXPIRED:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDYTCCAkmgAwIBAgICA+owDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MB4XDTIwMDEwMTAwMDAwMFoXDTIw",
		"MDEwMjAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0B",
		"AQEFAAOCAQ8AMIIBCgKCAQEAlJSZil++936YOc7990bxDgKOMWWhsYcUBSE51+Ni",
		"xw3qhFoAQkgbC9Pz7Laz71NZd8jl5vryfKbOIAd2yLsF5qbUzAlBwZW5Qf/JM1eL",
		"FsKHl6tGfQnu/MEJtBbf61DOWBIQqAMe3o9S8s6CFIRRbpqMf+dqAF88EV7OW3C2",
		"Th1OLc9qttkFgV3OdshKtPKI2XqvxMy+cRzm3F7yIED6m2sFZif7gaXd/jUvkOk1",
		"4txO1Vb28itrAyFHylGjFWU2QrjEsVGmxUjnY93XdIAIbL+XMmkreNQFmdRcCyC4",
		"FnQAmZTKs8D7KKrxC2NqAr8XeBFFS12nxXCmbc4Y3NMlMQIDAQABo4GnMIGkMB0G",
		"A1UdDgQWBBTdfbZ4vfdeXyj7Ybp2RvRx5vI5TjAfBgNVHSMEGDAWgBSJ4FHT2mpm",
		"gj9GnVa3ybpx0fOErjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDAdBgNV",
		"HSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwJQYDVR0RBB4wHIIJbG9jYWxob3N0",
		"ggkxMjcuMC4wLjGHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBABN8E/v4E70HTXIW",
		"wrYD+nm5Jdfgn2+AvuTO+z7s1He33I18lkmErV014iotT4Wy9mRK6fivB/xvEC/6",
		"nR+q/dAfThH9PXc6mLkiG5EO6wNyBMXm2lnn4m1w9QEmRLGbKXFgGYVmsz7SMZIH",
		"5QWaucrD968Nwpj0jsRmEXxJV/reWkE/K3GqxF0gLclcZ/oabyoPYb/t4yOn9imB",
		"MWw0gOk5hUPX7mf5kxsoc+XONQ2iy9riAtWIG0kw4pV8LAne4IxkeGompdCt2/Ye",
		"EJoOOKAf7AiQsgKU7ovdiadO5T65EolVONU3vU0gP9OkolUzb0XKI54Lq2vL2Iic",
		"811JIKc=",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** As `ISSUED`, valid for 1 January 2099 alone. **/
	public static final ISSUED_NOT_YET_VALID:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDZTCCAk2gAwIBAgICA+swDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweQ3Jv",
		"c3NCeXRlIERhdGVkIFRlc3QgQXV0aG9yaXR5MCIYDzIwOTkwMTAxMDAwMDAwWhgP",
		"MjA5OTAxMDIwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZI",
		"hvcNAQEBBQADggEPADCCAQoCggEBAJSUmYpfvvd+mDnO/fdG8Q4CjjFlobGHFAUh",
		"OdfjYscN6oRaAEJIGwvT8+y2s+9TWXfI5eb68nymziAHdsi7Beam1MwJQcGVuUH/",
		"yTNXixbCh5erRn0J7vzBCbQW3+tQzlgSEKgDHt6PUvLOghSEUW6ajH/nagBfPBFe",
		"zltwtk4dTi3ParbZBYFdznbISrTyiNl6r8TMvnEc5txe8iBA+ptrBWYn+4Gl3f41",
		"L5DpNeLcTtVW9vIrawMhR8pRoxVlNkK4xLFRpsVI52Pd13SACGy/lzJpK3jUBZnU",
		"XAsguBZ0AJmUyrPA+yiq8QtjagK/F3gRRUtdp8Vwpm3OGNzTJTECAwEAAaOBpzCB",
		"pDAdBgNVHQ4EFgQU3X22eL33Xl8o+2G6dkb0cebyOU4wHwYDVR0jBBgwFoAUieBR",
		"09pqZoI/Rp1Wt8m6cdHzhK4wDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAw",
		"HQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMCUGA1UdEQQeMByCCWxvY2Fs",
		"aG9zdIIJMTI3LjAuMC4xhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQALHiO7iTn0",
		"8EB7rscDJaAvtmdro8mA6Lzx8UVxj8obVE1rxwl8go3g8v0pylEbFdfnRAz9SROD",
		"mimbVk86enjJRDZr0vP5UrpS7BXxSC4auIgX5DEFBAr5Q0gnvDxqsz5lWn7+S01N",
		"0amTyC8us5kQa4j1W3zYxNT2vzpzJ2EuuYWnthkNv6HGP39oDl360KxDl2BDPw7J",
		"cU4CI9izPH3zGVPezJowNEFLBXRcf4a/lmqyQKhBFIcuyPo40MNm4KWf/m1IgUF2",
		"//r7xiQwBXP9hkXbrqp41c2K58zVC3v51DEabsIRuwgePFHLcii1RBFTx4HMUjP+",
		"lyHzCLx20W+L",
		"-----END CERTIFICATE-----"
	].join("\n");

	/** The key of every certificate here but `AUTHORITY`. **/
	public static final DATED_KEY:String = [
		"-----BEGIN PRIVATE KEY-----",
		"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCUlJmKX773fpg5",
		"zv33RvEOAo4xZaGxhxQFITnX42LHDeqEWgBCSBsL0/PstrPvU1l3yOXm+vJ8ps4g",
		"B3bIuwXmptTMCUHBlblB/8kzV4sWwoeXq0Z9Ce78wQm0Ft/rUM5YEhCoAx7ej1Ly",
		"zoIUhFFumox/52oAXzwRXs5bcLZOHU4tz2q22QWBXc52yEq08ojZeq/EzL5xHObc",
		"XvIgQPqbawVmJ/uBpd3+NS+Q6TXi3E7VVvbyK2sDIUfKUaMVZTZCuMSxUabFSOdj",
		"3dd0gAhsv5cyaSt41AWZ1FwLILgWdACZlMqzwPsoqvELY2oCvxd4EUVLXafFcKZt",
		"zhjc0yUxAgMBAAECggEABaeMmtinOb/Ifw22ulgJsTrtaqmXoFwXydSwgPvzPMhV",
		"rB0JPLyGA/qYYkI3QZTKVz3O6w4Sl6YY+tzR21SLxlIDz/KLvThrnRyFDZZHsbFs",
		"S9w9seFEhju5+O+0bJ4OBknEtsIspPNvKJStnGaHO1Z4IZ9+2B4HuRECuTXmSD10",
		"LYClGXK1IuMaTKqcVYH2KpKifbbqrKFmVOgRkqZoQJI5nGcVqbWMwIqgoG8kPo3p",
		"rdUb7NjWYGeBtdtMSprjRNkHdNNiiDz1/x3ZCxzSpnmz2zxF9adToR/Re4UpInOU",
		"CweVSCGBoDf0qymNofQ7SD6NJ1F163ZzpwB5rZuIiQKBgQDEkie02uYrqIU77zSM",
		"XLLotvGMFeM4WxbRClN8QFKxG+nb5bE5p68aok94wmlkB9kkznRCoEpI2Hrdn3zp",
		"u14r7tgu9t+j6bP/Q+SM7F8VBHSNn6n0Y+pzN6tHOu8sAKtxLyAFplCBVjeXF48M",
		"GJDkDkarxfzrIANcKBoC8O1yOQKBgQDBgCpct/RHfyOByMa+S0kQQQpiPubQsEKf",
		"LJ9/MVCDDmwDHRzgEyOOoWkdtgExiRaq7pGKQRim+OtnS2fldXczndaSYbcq3MND",
		"fkdOxQ9b/mvFhAEuPIPtjzz4S6tG0QE7RwgujvtCSG2kBYm9+S4WNtwmI9gcH4tt",
		"3i08L3BquQKBgGt2S2a/1N1BP7VITD3/338BpIOk45dHlO2q64Ed2Rch33Nr2rte",
		"RIgW+8NU5TDeaYOJql1SK8ovLtxB+JP+7rit1lm2dQSzGsgOYb/46PIggWd7Rfpp",
		"NR7P7D8ApQg1RYSW8raj+Zb7f2CGbJl8RJmohFIb5uzTj4KuGapJ9EVhAoGAE91c",
		"e/hGk7BxrLk37gE8lvaWYk+i0nnF3SFvnlcptMqePBOZC0frtpDLgclVhghU02d6",
		"eX8FUN7tC8Wp/Nx6SEpD5PMzIqtXQG6OU3/Xe9I6riRHGsALqy+xSqw6ASMjxTod",
		"lOoI0V0uJFCNO3uBR7aKE0BKx1hVsAnHCw6zs8ECgYEAv6OnzQFC8sEBX2F1mUyQ",
		"LR6B8Th0T/h1ZqmITcHUaGheDSctcODHes1mvHg5Uic5SBnwSEQ94WGJQbkn6RJQ",
		"rpVdj5voiowQX3AelAKGsFUAwFj411bUx/SGz1Dye8uQX4HAdDJaBUS5RzsSGNKp",
		"8mkjGWimgwo2SQK/5e8vopE=",
		"-----END PRIVATE KEY-----"
	].join("\n");
}
#end
