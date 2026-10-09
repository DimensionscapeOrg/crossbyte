package crossbyte.net;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	What a `NetConnection` or `NetHost` says about a URI it cannot use, and a
	page dialling `ws://`.

	A scheme a target does not take was a bare `"Protocol error"` string, and
	a URI that did not parse a short string such as `"missing host"`, neither
	naming the URI nor what would have worked. And in a browser `ws://` and
	`wss://` threw that string, though a page's `Socket` is a WebSocket: RPC
	from a page over the documented `ws://` URI could not be made at all.
**/
class NetConnectionSchemeTest extends utest.Test {
	public function testAnUnknownSchemeNamesTheUriAndTheSchemesKnown():Void {
		var message = refusal(() -> new NetConnection("ftp://127.0.0.1:21"));
		Assert.notNull(message, "an unknown scheme was not refused with an ArgumentError");
		if (message != null) {
			Assert.isTrue(message.indexOf("ftp://127.0.0.1:21") >= 0, 'the URI is not named: $message');
			Assert.isTrue(message.indexOf("tcp") >= 0 && message.indexOf("ws") >= 0, 'the schemes known are not named: $message');
		}
	}

	public function testAUriThatDoesNotReadSaysWhy():Void {
		var message = refusal(() -> new NetConnection("tcp://127.0.0.1"));
		Assert.notNull(message, "a URI without a port was not refused with an ArgumentError");
		if (message != null) {
			Assert.isTrue(message.indexOf("tcp://127.0.0.1") >= 0, 'the URI is not named: $message');
			Assert.isTrue(message.indexOf("port") >= 0, 'what is missing is not said: $message');
		}
	}

	public function testASchemeThisTargetCannotDialNamesTheOnesItCan():Void {
		var message = refusal(() -> new NetConnection("udp://127.0.0.1:5000"));
		Assert.notNull(message, "udp:// was not refused with an ArgumentError");
		if (message != null) {
			Assert.isTrue(message.indexOf("udp://127.0.0.1:5000") >= 0, 'the URI is not named: $message');
			Assert.isTrue(message.indexOf("ws://") >= 0, 'the schemes taken are not named: $message');
		}
	}

	#if !(js && !nodejs)
	public function testAHostOnASchemeItCannotListenOnSaysWhatTo():Void {
		var message = refusal(() -> new NetHost("local://some-name"));
		Assert.notNull(message, "a local:// host was not refused with an ArgumentError");
		if (message != null) {
			Assert.isTrue(message.indexOf("LocalConnection") >= 0, 'the way to listen locally is not named: $message');
		}
	}
	#end

	#if (js && !nodejs)
	public function testAPageDialsWsAsAWebSocket():Void {
		var connection:NetConnection = null;
		try {
			connection = new NetConnection("ws://127.0.0.1:9/rpc");
		} catch (error:Dynamic) {
			Assert.fail("a page could not make a ws:// connection: " + Std.string(error));
			return;
		}
		Assert.notNull(NetConnection.toSocket(connection), "ws:// in a page is not the page's Socket");
		Assert.isFalse(NetConnection.toSocket(connection).secure, "ws:// was dialled as wss://");
		try connection.close() catch (_:Dynamic) {}

		var secure:NetConnection = new NetConnection("wss://127.0.0.1:9/rpc");
		Assert.isTrue(NetConnection.toSocket(secure).secure, "wss:// was not dialled secure");
		try secure.close() catch (_:Dynamic) {}
	}
	#end

	static function refusal(make:Void->Dynamic):Null<String> {
		try {
			make();
		} catch (error:ArgumentError) {
			return error.message;
		} catch (_:Dynamic) {}
		return null;
	}
}
