package crossbyte._internal.php;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;
import crossbyte.test.Require;

/** A request as php-fpm would have read it. **/
private typedef FpmRequest = {
	errors:Array<String>,
	params:Map<String, String>,
	paramRecords:Int,
	stdin:Bytes,
	stdinEnded:Bool
}

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

	public function testABinaryBodyPassesThroughUntouched():Void {
		// A PNG: NULs, 0xFF, and sequences that are not UTF-8. The body used to
		// be decoded as UTF-8 and re-encoded, which on Node turned these 23
		// bytes into 8 and on eval threw from inside the tick.
		var body:Bytes = Bytes.ofHex("89504e470d0a1a0a0000000d49484452ff00fe80c3289f");
		var response = __respond(__cgi("Status: 200 OK\r\nContent-Type: image/png\r\n\r\n", body));

		Assert.equals(200, response.status);
		Assert.equals("image/png", response.headers.get("content-type"));
		Assert.equals(body.toHex(), response.body.toHex());
	}

	public function testALatin1PageAndHeaderSurvive():Void {
		// 0xE9 is "é" in Latin-1 and not valid UTF-8 on its own. The header
		// block is read a byte per character when it is not UTF-8, so it
		// cannot throw; the body is not read as text at all.
		var head = new BytesBuffer();
		head.add(Bytes.ofString("Content-Disposition: attachment; filename=\"caf"));
		head.addByte(0xE9);
		head.add(Bytes.ofString(".txt\"\r\n\r\n"));

		var body:Bytes = Bytes.ofHex("636166e90a");
		var response = __respond(__cgi(null, body, head.getBytes()));

		Assert.equals("attachment; filename=\"caf" + String.fromCharCode(0xE9) + ".txt\"", response.headers.get("content-disposition"));
		Assert.equals(body.toHex(), response.body.toHex());
	}

	public function testAUtf8HeaderIsReadAsUtf8():Void {
		var response = __respond(__cgi("Content-Disposition: attachment; filename=\"café.txt\"\r\n\r\n", Bytes.ofString("ok")));

		Assert.equals("attachment; filename=\"café.txt\"", response.headers.get("content-disposition"));
	}

	public function testABodyAcrossSeveralRecordsArrivesWhole():Void {
		// Larger than one record and full of NULs, arriving a few bytes at a
		// time: the parser has to carry partial records, and the split has to
		// survive a zero byte anywhere.
		var body:Bytes = Bytes.alloc(150000);

		for (i in 0...body.length) {
			body.set(i, (i * 7) & 0xFF);
		}

		var cgi:Bytes = __cgiBytes(Bytes.ofString("Content-Type: application/octet-stream\r\n\r\n"), body);
		var out = new BytesBuffer();
		var offset:Int = 0;

		while (offset < cgi.length) {
			var length:Int = cgi.length - offset < 60000 ? cgi.length - offset : 60000;
			__header(out, 6, length);
			out.addBytes(cgi, offset, length);
			offset += length;
		}

		__header(out, 3, 8);
		out.add(Bytes.alloc(8));

		var records:Bytes = out.getBytes();
		var exchange = new PHPExchange(0);
		var finished:Bool = false;
		var at:Int = 0;

		while (at < records.length) {
			var length:Int = records.length - at < 997 ? records.length - at : 997;
			finished = exchange.receive(records.sub(at, length), length);
			at += length;
		}

		Assert.isTrue(finished);
		var response = exchange.response();
		Assert.equals(body.length, response.body.length);
		Assert.equals(0, response.body.compare(body));
	}

	public function testAStatusThatIsNotAStatusIsIgnored():Void {
		Assert.equals(200, __respond(__cgi("Status: 99999999999 Nonsense\r\n\r\n", Bytes.ofString("x"))).status);
		Assert.equals(200, __respond(__cgi("Status: abc\r\n\r\n", Bytes.ofString("x"))).status);
		Assert.equals(404, __respond(__cgi("Status: 404 Not Found\r\n\r\n", Bytes.ofString("x"))).status);
	}

	public function testALargeRequestIsSplitIntoRecordsPhpFpmCanRead():Void {
		// A record's length field is sixteen bits. The whole body went in one
		// STDIN record, so a 100,000-byte POST declared 34,464 bytes and
		// php-fpm read the rest of the body as record headers.
		var body:Bytes = Bytes.alloc(100000);

		for (i in 0...body.length) {
			body.set(i, "a".code + (i % 26));
		}

		// Three parameters too large to share one record between them, so the
		// parameter stream has to split as well -- and only between pairs,
		// because php-fpm parses each PARAMS record on its own.
		var env:Map<String, String> = new Map();
		env.set("REQUEST_METHOD", "POST");
		env.set("HTTP_X_ONE", StringTools.lpad("", "1", 30000));
		env.set("HTTP_X_TWO", StringTools.lpad("", "2", 30000));
		env.set("HTTP_X_THREE", StringTools.lpad("", "3", 30000));

		var wire:Bytes = @:privateAccess PHPBridge.encodeRequest(env, body);
		var parsed = __parseAsPhpFpm(wire);

		Assert.same([], parsed.errors);
		Assert.isTrue(parsed.paramRecords > 1, "the parameters all went in one record");
		Assert.equals(4, Lambda.count(parsed.params));
		Assert.equals(env.get("HTTP_X_TWO"), parsed.params.get("HTTP_X_TWO"));
		Assert.equals(body.length, parsed.stdin.length);
		Assert.equals(0, parsed.stdin.compare(body));
		Assert.isTrue(parsed.stdinEnded, "the STDIN stream was never closed");
	}

	public function testAParameterTooLargeForARecordIsRefused():Void {
		// It cannot be split, and sent whole it would be malformed.
		var headers = new haxe.ds.StringMap<String>();
		headers.set("X-Huge", StringTools.lpad("", "h", 70000));

		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", 1), "", ["index.php"], 5);
		var future = bridge.execute({
			requestMethod: "GET",
			scriptFilename: "/srv/index.php",
			scriptName: "/index.php",
			requestUri: "/index.php",
			extraHeaders: headers,
			body: Bytes.alloc(0)
		});

		Assert.isTrue(future.completed);
		Assert.isFalse(future.succeeded);
		Assert.isTrue(future.error.indexOf("HTTP_X_HUGE") >= 0, future.error);
	}

	#if (cpp || jvm)
	public function testALargeUploadIsWrittenAsTheBackendReadsIt():Void {
		// Bigger than any socket send buffer, to a backend that has not started
		// reading yet. The request used to be written in one burst on a
		// non-blocking socket, which refuses what does not fit: the upload
		// failed at once as "Could not reach the PHP backend", a 502.
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);

		var body:Bytes = Bytes.alloc(8 * 1024 * 1024);

		for (i in 0...body.length) {
			body.set(i, (i * 31) & 0xFF);
		}

		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", listener.host().port), "", ["index.php"], 60);
		var future = bridge.execute({
			requestMethod: "POST",
			scriptFilename: "/srv/upload.php",
			scriptName: "/upload.php",
			requestUri: "/upload.php",
			contentType: "application/octet-stream",
			extraHeaders: new haxe.ds.StringMap<String>(),
			body: body
		});

		Assert.isFalse(future.completed, "the upload failed before the backend read a byte: " + future.error);

		var peer = listener.accept();
		peer.setBlocking(false);

		var runtime = crossbyte.core.CrossByte.current();
		var received = new BytesBuffer();
		var chunk:Bytes = Bytes.alloc(65536);
		var deadline:Float = haxe.Timer.stamp() + 60;
		var parsed:FpmRequest = null;

		// Reads as a backend would, while the runtime ticks: the bridge writes
		// the rest of the request only as this side makes room for it.
		while (haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);

			while (true) {
				var n:Int = 0;

				try {
					n = peer.input.readBytes(chunk, 0, chunk.length);
				} catch (_:Dynamic) {
					break;
				}

				if (n <= 0) {
					break;
				}

				received.addBytes(chunk, 0, n);
			}

			if (received.length >= body.length) {
				var snapshot:Bytes = received.getBytes();
				parsed = __parseAsPhpFpm(snapshot);

				if (parsed.stdinEnded) {
					break;
				}

				received = new BytesBuffer();
				received.add(snapshot);
				parsed = null;
			}

			Sys.sleep(0.001);
		}

		var request:FpmRequest = Require.notNull(parsed, "the request never arrived whole");
		Assert.same([], request.errors);
		Assert.equals(body.length, request.stdin.length);
		Assert.equals(0, request.stdin.compare(body));

		// Answer, and the exchange completes as it always did.
		var answer = new BytesBuffer();
		var cgi:Bytes = Bytes.ofString("Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nstored");
		__header(answer, 6, cgi.length);
		answer.add(cgi);
		__header(answer, 3, 8);
		answer.add(Bytes.alloc(8));
		peer.setBlocking(true);
		peer.output.write(answer.getBytes());

		while (!future.completed && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			Sys.sleep(0.001);
		}

		try {
			peer.close();
		} catch (_:Dynamic) {}

		try {
			listener.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(future.succeeded, "the exchange did not complete: " + future.error);

		if (future.succeeded) {
			Assert.equals("stored", future.result.body.toString());
		}
	}
	#end

	private static function __respond(records:Bytes):PHPResponse {
		var exchange = new PHPExchange(0);
		Assert.isTrue(exchange.receive(records, records.length), "END_REQUEST was not recognised");
		return exchange.response();
	}

	/** STDOUT records carrying a header block and a body, then END_REQUEST. **/
	private static function __cgi(head:String, body:Bytes, ?rawHead:Bytes):Bytes {
		var cgi:Bytes = __cgiBytes(rawHead != null ? rawHead : Bytes.ofString(head), body);
		var out = new BytesBuffer();
		__header(out, 6, cgi.length);
		out.add(cgi);
		__header(out, 3, 8);
		out.add(Bytes.alloc(8));
		return out.getBytes();
	}

	private static function __cgiBytes(head:Bytes, body:Bytes):Bytes {
		var out = new BytesBuffer();
		out.add(head);
		out.add(body);
		return out.getBytes();
	}

	/**
	 * Reads a request the way php-fpm's fcgi_read_request does: record by
	 * record, refusing a PARAMS record whose content and padding pass 65,535,
	 * and parsing each PARAMS record's pairs on their own.
	 */
	private static function __parseAsPhpFpm(wire:Bytes):FpmRequest {
		var errors:Array<String> = [];
		var params:Map<String, String> = new Map();
		var paramRecords:Int = 0;
		var stdin = new BytesBuffer();
		var stdinEnded:Bool = false;
		var at:Int = 0;

		while (at + 8 <= wire.length && errors.length == 0) {
			var version:Int = wire.get(at);
			var type:Int = wire.get(at + 1);
			var length:Int = (wire.get(at + 4) << 8) | wire.get(at + 5);
			var padding:Int = wire.get(at + 6);

			if (version != 1) {
				errors.push('record at $at has version $version: body bytes read as a header');
				break;
			}

			if (at + 8 + length + padding > wire.length) {
				// Incomplete: more to come.
				break;
			}

			var content:Bytes = wire.sub(at + 8, length);

			switch (type) {
				case 1:
				case 4:
					if (length + padding > 65535) {
						errors.push('PARAMS record at $at is $length + $padding bytes, which php-fpm refuses');
					} else if (length > 0) {
						paramRecords++;
						__parsePairs(content, params, errors);
					}
				case 5:
					if (length == 0) {
						stdinEnded = true;
					} else {
						stdin.add(content);
					}
				default:
					errors.push('unexpected record type $type at $at');
			}

			at += 8 + length + padding;
		}

		return {
			errors: errors,
			params: params,
			paramRecords: paramRecords,
			stdin: stdin.getBytes(),
			stdinEnded: stdinEnded
		};
	}

	/** The pairs in one PARAMS record, which must hold whole pairs only. **/
	private static function __parsePairs(content:Bytes, into:Map<String, String>, errors:Array<String>):Void {
		var cursor:Array<Int> = [0];

		while (cursor[0] < content.length) {
			var nameLength:Int = __pairLength(content, cursor);
			var valueLength:Int = nameLength < 0 ? -1 : __pairLength(content, cursor);
			var at:Int = cursor[0];

			if (valueLength < 0 || nameLength > content.length - at || valueLength > content.length - at - nameLength) {
				errors.push("a parameter pair runs past the end of its record");
				return;
			}

			into.set(content.getString(at, nameLength), content.getString(at + nameLength, valueLength));
			cursor[0] = at + nameLength + valueLength;
		}
	}

	/** A pair length, one byte or four, advancing `cursor[0]` past it; `-1` if it runs out. **/
	private static function __pairLength(content:Bytes, cursor:Array<Int>):Int {
		var at:Int = cursor[0];

		if (at >= content.length) {
			return -1;
		}

		var first:Int = content.get(at);

		if (first < 0x80) {
			cursor[0] = at + 1;
			return first;
		}

		if (at + 4 > content.length) {
			return -1;
		}

		cursor[0] = at + 4;
		return ((first & 0x7F) << 24) | (content.get(at + 1) << 16) | (content.get(at + 2) << 8) | content.get(at + 3);
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
