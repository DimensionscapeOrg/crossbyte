package crossbyte.net;

#if !(js && !nodejs)
#if (cpp || hl || neko || java || jvm || nodejs)
import crossbyte.net.TlsRefusalSupport.TlsCase;
import crossbyte.net.TlsRefusalSupport.TlsClient;
import utest.Assert;
#end
import utest.Async;

/**
	A certificate nothing vouches for is refused, by each of CrossByte's own
	clients (`Socket`, `WebSocket`, `NetConnection` and `URLLoader`) on every
	target with TLS, and by a server that requires a client's certificate:

	- one issued by an authority other than the one the client trusts;
	- a self-signed one the client was not told to trust;
	- a trusted one naming another host;
	- a trusted one naming the address a name resolves to, but not the
	  name dialled. The name is what is checked: a client that checked the
	  address it reached instead would take a certificate for whichever
	  machine answered there.

	Beside them, the same servers and clients with a certificate that is
	vouched for, which have to be let in: a client that cannot connect at
	all refuses too. Natively and on the jvm, for a `URLLoader`, the name
	reaches TLS only on the `Host` the resolver hands back, which is why a
	load by name is among these.

	Not on eval, which cannot run a TLS server. The cases that need a
	certificate made at run time warn and are left out without `openssl`.
**/
class CertificateTrustTest extends utest.Test {
	#if (cpp || hl || neko || java || jvm || nodejs)
	/** A secure `Socket` refuses each. **/
	@:timeout(90000)
	public function testASocketRefusesACertificateNothingVouchesFor(async:Async):Void {
		TlsRefusalSupport.through(SocketClient, __cases(), () -> async.done());
	}

	#if !(hl || neko)
	/**
		A `wss://` `WebSocket` refuses each. Not on neko and HashLink, where a
		`WebSocket` client cannot connect: its handshake key needs secure
		random bytes, which neither has.
	**/
	@:timeout(90000)
	public function testAWebSocketRefusesACertificateNothingVouchesFor(async:Async):Void {
		TlsRefusalSupport.through(WebSocketClient, __cases(), () -> async.done());
	}
	#end

	/** A `tls://` or `wss://` `NetConnection` refuses each; only `tls://` on neko and HashLink. **/
	@:timeout(120000)
	public function testANetConnectionRefusesACertificateNothingVouchesFor(async:Async):Void {
		TlsRefusalSupport.throughEach(TlsRefusalSupport.netConnections(), __cases(), () -> async.done());
	}

	/**
		An `https` `URLLoader` refuses each: over HTTP/1.1, over HTTP/2 where
		TLS can negotiate it, and with the server's own key pinned, which a
		pin lets through and the certificate's check still has to refuse.
	**/
	@:timeout(180000)
	public function testAnHttpsLoadRefusesACertificateNothingVouchesFor(async:Async):Void {
		TlsRefusalSupport.throughEach(TlsRefusalSupport.loaders(), __cases(), () -> async.done());
	}

	/**
		A server requiring a client certificate its authority issued refuses
		one another authority issued, and a self-signed one.
	**/
	@:timeout(90000)
	public function testAServerRefusesAClientCertificateItsAuthorityDidNotIssue(async:Async):Void {
		var authority:Certificate = Certificate.fromPem(CertificateExpiryTest.AUTHORITY);
		var cases:Array<TlsCase> = [
			TlsRefusalSupport.tlsCase("a certificate the authority issued", CertificateExpiryTest.ISSUED, CertificateExpiryTest.DATED_KEY, authority, true)
		];
		var chain = TLSChainFixture.get();
		var selfSigned = TLSTestFixture.trusted(["crossbyte-client"]);
		if (chain == null || selfSigned == null) {
			Assert.warn("no certificate toolchain on this machine; only the certificate the authority issued was presented");
		} else {
			cases.push(TlsRefusalSupport.fixtureCase("a certificate another authority issued", haxe.io.Path.join([chain.directory, "client.pem"]),
				haxe.io.Path.join([chain.directory, "client.key"]), authority, false));
			cases.push(TlsRefusalSupport.fixtureCase("a self-signed certificate", selfSigned.certificatePath, selfSigned.keyPath, authority, false));
		}
		TlsRefusalSupport.presentEach({certificate: Certificate.fromPem(CertificateExpiryTest.ISSUED), key: Key.fromPem(CertificateExpiryTest.DATED_KEY)},
			authority, authority, cases, () -> async.done());
	}

	/**
		A server's certificate, what the client trusts and what it dials:
		vouched for, then not.
	**/
	private static function __cases():Array<TlsCase> {
		var authority:Certificate = Certificate.fromPem(CertificateExpiryTest.AUTHORITY);
		var cases:Array<TlsCase> = [
			TlsRefusalSupport.tlsCase("a certificate its authority issued", CertificateExpiryTest.ISSUED, CertificateExpiryTest.DATED_KEY, authority, true),
			TlsRefusalSupport.tlsCase("a self-signed certificate it was not told to trust", CertificateExpiryTest.AUTHORITY,
				CertificateExpiryTest.AUTHORITY_KEY, null, false)
		];

		var chain = TLSChainFixture.get();
		var elsewhere = TLSTestFixture.trusted(["elsewhere.example"]);
		var byName = TLSTestFixture.trusted(["localhost"]);
		var byAddress = TLSTestFixture.trusted(["127.0.0.1"]);
		if (chain == null || elsewhere == null || byName == null || byAddress == null) {
			Assert.warn("no certificate toolchain on this machine; the cases for another authority and another name did not run");
			return cases;
		}
		cases.push(TlsRefusalSupport.tlsCase("a certificate an authority it does not trust issued", CertificateExpiryTest.ISSUED,
			CertificateExpiryTest.DATED_KEY, chain.other, false));
		cases.push(TlsRefusalSupport.fixtureCase("a trusted certificate naming another host", elsewhere.certificatePath, elsewhere.keyPath,
			elsewhere.certificate, false));
		cases.push(TlsRefusalSupport.fixtureCase("a trusted certificate naming the name dialled", byName.certificatePath, byName.keyPath,
			byName.certificate, true, "localhost"));
		cases.push(TlsRefusalSupport.fixtureCase("a trusted certificate naming the address the name dialled resolves to, and not the name",
			byAddress.certificatePath, byAddress.keyPath, byAddress.certificate, false, "localhost"));
		return cases;
	}
	#end
}
#end
