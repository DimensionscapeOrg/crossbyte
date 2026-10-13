package crossbyte.net;

import crossbyte.net.Endpoint.parseUrl;
import utest.Assert;

class EndpointTest extends utest.Test {
	public function testParsesWebSocketResourceAndSecureFlag():Void {
		var endpoint = parseUrl("wss://example.com/chat/room?token=1#ignored");

		Assert.equals(Protocol.WEBSOCKET, endpoint.protocol);
		Assert.equals("example.com", endpoint.address);
		Assert.equals(443, endpoint.port);
		Assert.isTrue(endpoint.secure);
		Assert.equals("/chat/room?token=1", endpoint.resource);
	}

	public function testParsesWebSocketQueryOnlyAsRootResource():Void {
		var endpoint = parseUrl("ws://example.com?token=1");

		Assert.equals(Protocol.WEBSOCKET, endpoint.protocol);
		Assert.equals(80, endpoint.port);
		Assert.isFalse(endpoint.secure);
		Assert.equals("/?token=1", endpoint.resource);
	}

	public function testRejectsTcpUdpAndRudpPaths():Void {
		Assert.isTrue(throwsParseError(() -> parseUrl("tcp://127.0.0.1:9000/path")));
		Assert.isTrue(throwsParseError(() -> parseUrl("udp://127.0.0.1:9000?mode=test")));
		Assert.isTrue(throwsParseError(() -> parseUrl("rudp://127.0.0.1:9000/stream")));
	}

	public function testRejectsUnbracketedIpv6Literal():Void {
		Assert.isTrue(throwsParseError(() -> parseUrl("tcp://::1:9000")));
		Assert.isTrue(throwsParseError(() -> parseUrl("ws://::1")));
	}

	public function testParsesBracketedIpv6Literal():Void {
		var endpoint = parseUrl("tcp://[::1]:9000");

		Assert.equals(Protocol.TCP, endpoint.protocol);
		Assert.equals("::1", endpoint.address);
		Assert.equals(9000, endpoint.port);
		Assert.equals("", endpoint.resource);
	}

	public function testParsesReliableDatagramEndpoint():Void {
		var endpoint = parseUrl("rudp://127.0.0.1:9000");

		Assert.equals(Protocol.RUDP, endpoint.protocol);
		Assert.equals("127.0.0.1", endpoint.address);
		Assert.equals(9000, endpoint.port);
		Assert.equals("", endpoint.resource);
	}

	public function testParsesLocalEndpoint():Void {
		var endpoint = parseUrl("local://crossbyte_ipc_demo");

		Assert.equals(Protocol.LOCAL, endpoint.protocol);
		Assert.equals("crossbyte_ipc_demo", endpoint.address);
		Assert.equals(0, endpoint.port);
		Assert.equals("", endpoint.resource);
	}

	/**
		A port too big for an `Int` is refused on every target, as any port
		past 65535 is, not read with `Std.parseInt`, which answers one
		differently on each: its low 32 bits on Linux native, so 4294967296
		would be port 0; an exception of its own on the jvm, which is not the
		parse error the caller is told to expect.
	**/
	public function testRejectsAPortTooBigForAnInt():Void {
		Assert.isTrue(throwsParseError(() -> parseUrl("tcp://127.0.0.1:4294967296")));
		Assert.isTrue(throwsParseError(() -> parseUrl("ws://example.com:4294967376/chat")));
		Assert.isTrue(throwsParseError(() -> parseUrl("tcp://127.0.0.1:99999999999999999999")));
		Assert.isTrue(throwsParseError(() -> parseUrl("tcp://127.0.0.1:65536")));
		Assert.equals(65535, parseUrl("tcp://127.0.0.1:65535").port);
	}

	private static function throwsParseError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (error:crossbyte.errors.ArgumentError) {
			// Said with the URI it was given.
			return StringTools.startsWith(error.message, 'Cannot use "');
		} catch (_:Dynamic) {
			return false;
		}
	}
}
