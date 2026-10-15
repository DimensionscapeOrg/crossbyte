package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A server presenting an expired certificate is refused, on every target
	with TLS, even by a client that pins that very certificate as its
	authority. The jvm let it through: PKIX checks no trust anchor's dates,
	and a pinned self-signed certificate is the anchor. Natively mbedTLS and
	on Node OpenSSL refused it; the jvm now holds every certificate a peer
	presents to its dates as well (`JvmDatedTrust`).

	The certificate below names `localhost` and `127.0.0.1`, and was valid
	for one day, 1 January 2020. Kept here rather than made by a test: one
	already expired stays as it is.
**/
class CertificateExpiryTest extends utest.Test {
	#if (cpp || hl || neko || java || jvm || nodejs)
	@:timeout(30000)
	public function testAnExpiredCertificateIsRefusedEvenPinned(async:Async):Void {
		var expired = Certificate.fromPem(EXPIRED_CERTIFICATE);
		var server = new ServerSocket(true);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> try e.socket.close() catch (_:Dynamic) {});
		server.setCertificate(expired, Key.fromPem(EXPIRED_KEY));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			TlsProbe.run(server.localPort, {serverName: "localhost", trust: expired}, function(outcome) {
				Assert.notNull(outcome.error, "a certificate that expired in 2020 was let in");
				server.close();
				async.done();
			});
		});
	}
	#end

	static final EXPIRED_CERTIFICATE:String = [
		"-----BEGIN CERTIFICATE-----",
		"MIIDJTCCAg2gAwIBAgIUNthWyNQKMcBNcwvJUW+2uD88fUQwDQYJKoZIhvcNAQEL",
		"BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTIwMDEwMTAwMDAwMFoXDTIwMDEw",
		"MjAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF",
		"AAOCAQ8AMIIBCgKCAQEAlJSZil++936YOc7990bxDgKOMWWhsYcUBSE51+Nixw3q",
		"hFoAQkgbC9Pz7Laz71NZd8jl5vryfKbOIAd2yLsF5qbUzAlBwZW5Qf/JM1eLFsKH",
		"l6tGfQnu/MEJtBbf61DOWBIQqAMe3o9S8s6CFIRRbpqMf+dqAF88EV7OW3C2Th1O",
		"Lc9qttkFgV3OdshKtPKI2XqvxMy+cRzm3F7yIED6m2sFZif7gaXd/jUvkOk14txO",
		"1Vb28itrAyFHylGjFWU2QrjEsVGmxUjnY93XdIAIbL+XMmkreNQFmdRcCyC4FnQA",
		"mZTKs8D7KKrxC2NqAr8XeBFFS12nxXCmbc4Y3NMlMQIDAQABo28wbTAdBgNVHQ4E",
		"FgQU3X22eL33Xl8o+2G6dkb0cebyOU4wHwYDVR0jBBgwFoAU3X22eL33Xl8o+2G6",
		"dkb0cebyOU4wDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH",
		"BH8AAAEwDQYJKoZIhvcNAQELBQADggEBAI0ObhAw91yCtPeq0f7EGdCf3nQSZQvE",
		"3YoPfCHw7wP1pBcIlERkCwRPWSzlRmm0+E2m51pMgmGh95J2QrPG7CtMrer0Vzk6",
		"oECC3rcIdTYVCbPTQ/J8IrnjPGXruKD9mTuFQmluin6vbzXYKDbzgDcS8MaQVjv6",
		"5cW30BRrOQwr1DVMgb7ejRIKJKVCYlmoAtdkbMmWsfdDI+Rg0C+Bu5GYj1G5+I1p",
		"MShvLVcDHOqDDgYdx22byan7RnvOetwfj+BgGQbdPLN0TdczWcFIwB33FU6/U4TP",
		"Gu4tp2MT2NjD/0edPEyec+9kyqWDAcd09KW3TZuEGGk2V+PeDvQGhbM=",
		"-----END CERTIFICATE-----"
	].join("\n");

	static final EXPIRED_KEY:String = [
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
