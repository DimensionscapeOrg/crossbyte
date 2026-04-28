package crossbyte.net;

import crossbyte.net.Endpoint.parseURL;
import utest.Assert;

class EndpointTest extends utest.Test {
	public function testParsesWebSocketResourceAndSecureFlag():Void {
		var endpoint = parseURL("wss://example.com/chat/room?token=1#ignored");

		Assert.equals(Protocol.WEBSOCKET, endpoint.protocol);
		Assert.equals("example.com", endpoint.address);
		Assert.equals(443, endpoint.port);
		Assert.isTrue(endpoint.secure);
		Assert.equals("/chat/room?token=1", endpoint.resource);
	}

	public function testParsesWebSocketQueryOnlyAsRootResource():Void {
		var endpoint = parseURL("ws://example.com?token=1");

		Assert.equals(Protocol.WEBSOCKET, endpoint.protocol);
		Assert.equals(80, endpoint.port);
		Assert.isFalse(endpoint.secure);
		Assert.equals("/?token=1", endpoint.resource);
	}

	public function testRejectsTcpAndUdpPaths():Void {
		Assert.isTrue(throwsParseError(() -> parseURL("tcp://127.0.0.1:9000/path")));
		Assert.isTrue(throwsParseError(() -> parseURL("udp://127.0.0.1:9000?mode=test")));
	}

	public function testRejectsUnbracketedIpv6Literal():Void {
		Assert.isTrue(throwsParseError(() -> parseURL("tcp://::1:9000")));
		Assert.isTrue(throwsParseError(() -> parseURL("ws://::1")));
	}

	public function testParsesBracketedIpv6Literal():Void {
		var endpoint = parseURL("tcp://[::1]:9000");

		Assert.equals(Protocol.TCP, endpoint.protocol);
		Assert.equals("::1", endpoint.address);
		Assert.equals(9000, endpoint.port);
		Assert.equals("", endpoint.resource);
	}

	private static function throwsParseError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:String) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
