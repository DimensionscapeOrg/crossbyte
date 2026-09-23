package crossbyte._internal.php;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;

/**
 * The CGI header block, as `PHPExchange` hands it to the handler.
 *
 * Fed FastCGI records directly, so it needs no backend and no socket. That is
 * what lets it run on eval, where `HTTPPhpTest` cannot: a socket there cannot
 * be made non-blocking, so the bridge's read would stall the tick it runs in.
 */
class PHPExchangeTest extends utest.Test {
	#if !(js && !nodejs)
	public function testARepeatedFieldIsJoinedRatherThanOverwritten():Void {
		var records:Bytes = stdoutThenEnd("Status: 201 Created\r\n"
			+ "Set-Cookie: session=abc; Path=/; HttpOnly\r\n"
			+ "Set-Cookie: theme=dark; Expires=Wed, 21 Oct 2037 07:28:00 GMT\r\n"
			+ "Vary: Accept\r\n"
			+ "Vary: Cookie\r\n"
			+ "\r\n"
			+ "body");

		var exchange = new PHPExchange(0);
		Assert.isTrue(exchange.receive(records, records.length), "END_REQUEST was not recognised");
		var response = exchange.response();

		// PHP sends one Set-Cookie line per cookie, and each one used to
		// overwrite the one before it, so only the last reached the client.
		// Joined with a newline because a cookie carries commas of its own --
		// the Expires date here has one -- and a comma join could not be split
		// apart again.
		Assert.equals("session=abc; Path=/; HttpOnly\ntheme=dark; Expires=Wed, 21 Oct 2037 07:28:00 GMT", response.headers.get("set-cookie"));
		Assert.equals("Accept, Cookie", response.headers.get("vary"));
		Assert.equals(201, response.status);
		Assert.equals("body", response.body.toString());
	}

	/** One FCGI_STDOUT record carrying `cgi`, then FCGI_END_REQUEST. */
	private static function stdoutThenEnd(cgi:String):Bytes {
		var content:Bytes = Bytes.ofString(cgi);
		var out = new BytesBuffer();
		__header(out, 6, content.length);
		out.add(content);
		__header(out, 3, 8);
		out.add(Bytes.alloc(8));
		return out.getBytes();
	}

	private static function __header(out:BytesBuffer, type:Int, length:Int):Void {
		out.addByte(1);
		out.addByte(type);
		out.addByte(0);
		out.addByte(1);
		out.addByte((length >> 8) & 0xFF);
		out.addByte(length & 0xFF);
		out.addByte(0);
		out.addByte(0);
	}
	#end
}
