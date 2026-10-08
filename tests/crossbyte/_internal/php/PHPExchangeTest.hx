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
 * Mostly fed FastCGI records directly, needing no backend and no socket. The
 * cases about when the bridge connects and when it reads drive it against a
 * plain blocking backend, and run on eval as well: the bridge connects on a
 * thread of its own and reads only what the runtime's poll set reports, so a
 * socket eval cannot make non-blocking does not stall it.
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

		// PHP sends one Set-Cookie line per cookie, and each must reach the
		// client, not overwrite the one before it. Joined with a newline because
		// a cookie carries commas of its own (the Expires date here has one), and
		// a comma join could not be split apart again.
		Assert.equals("session=abc; Path=/; HttpOnly\ntheme=dark; Expires=Wed, 21 Oct 2037 07:28:00 GMT", response.headers.get("set-cookie"));
		Assert.equals("Accept, Cookie", response.headers.get("vary"));
		Assert.equals(201, response.status);
		Assert.equals("body", response.body.toString());
	}

	public function testABinaryBodyPassesThroughUntouched():Void {
		// A PNG: NULs, 0xFF, and sequences that are not UTF-8. Decoded as UTF-8
		// and re-encoded, these 23 bytes would become 8 on Node and throw from
		// inside the tick on eval.
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

	/**
		A response past its limit fails as it arrives, the bytes past the
		limit never held. Unbounded, a script (or a backend not running PHP at
		all) would choose how much of the server's memory each request took,
		and the server would hold it whole, and then twice over as the body was
		taken from it.
	**/
	public function testAResponsePastItsLimitFailsAsItArrives():Void {
		var small = __records(__cgiBytes(Bytes.ofString("Content-Type: text/plain\r\n\r\n"), Bytes.alloc(3000)));
		var limited = new PHPExchange(0, 1024);
		Assert.isFalse(limited.receive(small, small.length), "a 3 KB response completed under a 1 KB limit");
		Assert.isTrue(limited.settled, "a response past its limit did not end the exchange");
		Assert.isTrue(limited.future.error != null && limited.future.error.indexOf("exceeded 1024 bytes") >= 0, "the failure does not say why: " + limited.future.error);

		// 8 MB by default: 9 MB fails, and 1 MB is a page.
		var big = __records(__cgiBytes(Bytes.ofString("Content-Type: application/octet-stream\r\n\r\n"), Bytes.alloc(9 * 1024 * 1024)));
		var bounded = new PHPExchange(0);
		Assert.isFalse(bounded.receive(big, big.length), "a 9 MB response completed under the default limit");
		Assert.isTrue(bounded.future.error != null && bounded.future.error.indexOf("exceeded " + PHPExchange.DEFAULT_MAX_RESPONSE_SIZE) >= 0,
			"the failure does not say why: " + bounded.future.error);

		var page = __records(__cgiBytes(Bytes.ofString("Content-Type: application/octet-stream\r\n\r\n"), Bytes.alloc(1024 * 1024)));
		var taken = new PHPExchange(0);
		Assert.isTrue(taken.receive(page, page.length), "a 1 MB response failed under the default limit: " + taken.future.error);
		Assert.equals(1024 * 1024, taken.response().body.length);

		// No limit at all, when asked for.
		var unlimited = new PHPExchange(0, 0);
		Assert.isTrue(unlimited.receive(big, big.length), "a response with no limit failed: " + unlimited.future.error);
	}

	/**
		A header block past 64 KB, or of more than a hundred lines, fails as
		it arrives. Repeated lines are joined once, at the end: joining 40,000
		lines of one field each onto the whole value so far is quadratic, and
		would take seconds on the runtime's thread.
	**/
	public function testAHeaderBlockPastItsLimitsFails():Void {
		var flood = new StringBuf();
		for (_ in 0...40000) {
			flood.add("Vary: Accept\r\n");
		}
		flood.add("\r\n");
		var records = __records(__cgiBytes(Bytes.ofString(flood.toString()), Bytes.ofString("body")));
		var exchange = new PHPExchange(0);
		var started:Float = haxe.Timer.stamp();
		var finished:Bool = exchange.receive(records, records.length);
		var took:Float = haxe.Timer.stamp() - started;
		Assert.isFalse(finished, "a header block of 40,000 lines was taken");
		Assert.isTrue(exchange.future.error != null && exchange.future.error.indexOf("header block exceeded") >= 0, "the failure does not say why: " + exchange.future.error);
		Assert.isTrue(took < 1.0, 'refusing the header block took $took s');

		// One past a hundred lines, under 64 KB.
		var lines:Array<String> = [for (i in 0...101) 'X-Field-$i: $i'];
		var many = new PHPExchange(0);
		var tooMany = __cgi(lines.join("\r\n") + "\r\n\r\n", Bytes.ofString("body"));
		Assert.isFalse(many.receive(tooMany, tooMany.length), "101 header lines were taken");
		Assert.isTrue(many.future.error != null && many.future.error.indexOf("101 lines") >= 0, "the failure does not say why: " + many.future.error);

		// A hundred are a header block, repeats joined as the handler expects.
		var hundred:Array<String> = [for (i in 0...100) 'Vary: v$i'];
		var response = __respond(__cgi(hundred.join("\r\n") + "\r\n\r\n", Bytes.ofString("body")));
		Assert.equals([for (i in 0...100) 'v$i'].join(", "), response.headers.get("vary"));
		Assert.equals("body", response.body.toString());
	}

	public function testALargeRequestIsSplitIntoRecordsPhpFpmCanRead():Void {
		// A record's length field is sixteen bits, so the body is split across
		// STDIN records: in one, a 100,000-byte POST would declare 34,464 bytes
		// and php-fpm would read the rest of the body as record headers.
		var body:Bytes = Bytes.alloc(100000);

		for (i in 0...body.length) {
			body.set(i, "a".code + (i % 26));
		}

		// Three parameters too large to share one record between them, so the
		// parameter stream has to split as well, and only between pairs,
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
		// reading yet. Written in one burst on a non-blocking socket, which
		// refuses what does not fit, the upload would fail at once as "Could not
		// reach the PHP backend", a 502.
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

			crossbyte.sys.System.sleep(0.001);
		}

		var request:FpmRequest = Require.notNull(parsed, "the request never arrived whole");
		Assert.same([], request.errors);
		Assert.equals(body.length, request.stdin.length);
		Assert.equals(0, request.stdin.compare(body));

		// Answer, and the exchange completes.
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
			crossbyte.sys.System.sleep(0.001);
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

	#if (cpp || jvm || eval)
	public function testAReplyIsReadWhenItArrivesRatherThanAtTheNextTick():Void {
		// Answered at once, and then the runtime's sockets polled without a
		// single tick, which is how a server's loop spends the time between
		// ticks. Read from a tick listener, the reply would wait there for the
		// next tick: up to 84ms, 42ms on average, at the default twelve a
		// second, however quickly PHP had answered.
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", backend.port), "", ["index.php"], 10);
		var future = bridge.execute(__request());

		var request:FpmRequest = __readRequest(backend.accept());
		Assert.isTrue(request.stdinEnded, "the request never arrived whole");
		backend.reply(__cgi("Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n", Bytes.ofString("from php")));

		__pollWithoutTicking(() -> future.completed, 5.0);
		backend.close();
		bridge.stop();

		Assert.isTrue(future.completed, "the reply sat unread until a tick came round");
		Assert.isTrue(future.succeeded, "the exchange failed: " + future.error);

		if (future.succeeded) {
			Assert.equals("from php", future.result.body.toString());
		}
	}

	public function testABackendThatHangsUpMidResponseIsHeardWhenItHangsUp():Void {
		// Part of a response and no END_REQUEST, and then the connection gone.
		// The hang-up is readiness too, so it is heard as it happens rather
		// than at a tick, and the half a page is not served as a page.
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", backend.port), "", ["index.php"], 10);
		var future = bridge.execute(__request());

		__readRequest(backend.accept());
		var partial = new BytesBuffer();
		var cgi:Bytes = Bytes.ofString("Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nhalf a pa");
		__header(partial, 6, cgi.length);
		partial.add(cgi);
		backend.reply(partial.getBytes());
		backend.close();

		__pollWithoutTicking(() -> future.completed, 5.0);
		bridge.stop();

		Assert.isTrue(future.completed, "the hang-up was not heard until a tick came round");
		Assert.isFalse(future.succeeded, "half a response was served as a whole one");
		Assert.isTrue(future.error != null && future.error.indexOf("closed the connection before finishing") >= 0, "not reported as a hang-up: " + future.error);
	}

	public function testABackendNameThatDoesNotResolveDoesNotHoldExecute():Void {
		// The backend's name is looked up, and connected to, on the bridge's
		// connector thread, not inside execute() on the runtime's thread, where
		// a name that does not resolve would hold it for as long as the resolver
		// took, a second being ordinary, and the exchange would fail from inside
		// the call. The failure arrives afterwards. Under `.invalid`, which never
		// resolves (RFC 6761), and fresh each run, so no resolver has the answer
		// cached.
		var name:String = "crossbyte-php-" + Std.random(0x3FFFFFFF) + ".invalid";
		var bridge = new PHPBridge(PHPMode.Connect(name, 9000), "", ["index.php"], 30);

		var started:Float = haxe.Timer.stamp();
		var future = bridge.execute(__request());
		var spent:Float = haxe.Timer.stamp() - started;

		Assert.isFalse(future.completed, "the name was looked up, and failed, inside execute(): " + future.error);
		Assert.isTrue(spent < 0.5, 'execute() spent $spent s on the backend\'s name');

		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 20;

		while (!future.completed && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			crossbyte.sys.System.sleep(0.005);
		}

		bridge.stop();

		Assert.isTrue(future.completed, "a backend name that does not resolve was never reported");
		Assert.isFalse(future.succeeded, "an exchange with a backend that does not exist succeeded");
		Assert.isTrue(future.error != null && future.error.indexOf(name) >= 0, "the failure does not name the backend: " + future.error);
	}

	public function testABackendGivenByNameIsLookedUpOnceRatherThanPerRequest():Void {
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("localhost", backend.port), "", ["index.php"], 10);
		var runtime = crossbyte.core.CrossByte.current();

		for (round in 0...3) {
			var future = bridge.execute(__request());
			__readRequest(backend.accept());
			backend.reply(__cgi("Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n", Bytes.ofString("round " + round)));

			var deadline:Float = haxe.Timer.stamp() + 5;

			while (!future.completed && haxe.Timer.stamp() < deadline) {
				runtime.pump(1 / 60, 0.0);
			}

			Assert.isTrue(future.succeeded, "round " + round + " failed: " + future.error);
		}

		backend.close();
		bridge.stop();

		Assert.equals(1, bridge.__lookups, "the backend's name was looked up for every request");
	}

	/**
		Exchanges with the backend are bounded: past `maxExchanges` a request
		waits for one to end, and only then connects, rather than opening a
		connection of its own however many are already waiting on a backend
		that answers one at a time.
	**/
	public function testExchangesWithTheBackendAreBounded():Void {
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", backend.port), "", ["index.php"], 20, PHPExchange.DEFAULT_MAX_RESPONSE_SIZE, 2);
		var futures = [for (_ in 0...3) bridge.execute(__request())];

		var first = backend.accept();
		__readRequest(first);
		var second = backend.accept();
		__readRequest(second);
		Assert.isFalse(backend.pending(0.5), "a third exchange connected past a limit of two");

		backend.replyOn(first, __cgi("Status: 200 OK\r\n\r\n", Bytes.ofString("one")));
		var third = backend.accept();
		Assert.isTrue(__readRequest(third).stdinEnded, "the waiting exchange never reached the backend once one ended");
		backend.replyOn(second, __cgi("Status: 200 OK\r\n\r\n", Bytes.ofString("two")));
		backend.replyOn(third, __cgi("Status: 200 OK\r\n\r\n", Bytes.ofString("three")));

		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 10;
		while (!(futures[0].completed && futures[1].completed && futures[2].completed) && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			crossbyte.sys.System.sleep(0.001);
		}
		backend.close();
		bridge.stop();

		Assert.same(["one", "two", "three"], [for (future in futures) future.succeeded ? future.result.body.toString() : "failed: " + future.error]);
	}

	/**
		Past `MAX_WAITING` behind the exchanges with the backend, a request is
		refused at once, as busy: a `PHPBusy` the handler can tell from a
		backend that answered badly.
	**/
	public function testARequestPastAFullQueueIsRefusedAsBusy():Void {
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", backend.port), "", ["index.php"], 2, PHPExchange.DEFAULT_MAX_RESPONSE_SIZE, 1);
		var queued = [for (_ in 0...PHPBridge.MAX_WAITING + 1) bridge.execute(__request())];
		var refused = bridge.execute(__request());

		Assert.isTrue(refused.completed, "a request past a full queue was not refused at once");
		Assert.isFalse(refused.succeeded);
		Assert.isTrue(Std.isOfType(refused.cause, PHPBusy), "the refusal is not a PHPBusy: " + refused.error);
		Assert.isTrue(refused.error != null && refused.error.indexOf("busy") >= 0, refused.error);
		Assert.equals(0, [for (future in queued) if (future.completed) future].length, "a queued request was refused");

		// They wait within their deadlines, and are failed by them.
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 10;
		while ([for (future in queued) if (!future.completed) future].length > 0 && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			crossbyte.sys.System.sleep(0.001);
		}
		backend.close();
		bridge.stop();
		Assert.equals(0, [for (future in queued) if (!future.completed) future].length, "queued requests outlived their deadline");
		Assert.isTrue(Std.isOfType(queued[queued.length - 1].cause, PHPTimeout), "the last queued request did not time out: " + queued[queued.length - 1].error);
	}

	/**
		A pass reads its budget of a response at most, and tells the loop
		there is more, rather than reading a backend sending fast for as long as
		it sends, the whole runtime waiting.
	**/
	public function testAPassReadsTheBudgetAndLeavesTheRest():Void {
		var backend = new BlockingBackend();
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", backend.port), "", ["index.php"], 20);
		// A budget small enough that what the system's buffers hold at once
		// is more than it, wherever this runs: Linux's loopback can take the
		// answer a little at a time, so that no pass meets a budget of a
		// megabyte. The bytes are the same four megabytes.
		@:privateAccess bridge.__readBudget = 16 * 1024;
		var future = bridge.execute(__request());
		var peer = backend.accept();
		__readRequest(peer);

		// Four times the budget, written from a thread of its own, since it
		// does not fit in the socket's buffers.
		var answer = __records(__cgiBytes(Bytes.ofString("Content-Type: application/octet-stream\r\n\r\n"), Bytes.alloc(4 * PHPBridge.READ_BUDGET)));
		sys.thread.Thread.create(() -> {
			try {
				peer.output.write(answer);
				peer.output.flush();
			} catch (_:Dynamic) {}
		});

		var runtime = crossbyte.core.CrossByte.current();
		var stopped:Int = 0;
		var deadline:Float = haxe.Timer.stamp() + 20;
		while (!future.completed && haxe.Timer.stamp() < deadline) {
			@:privateAccess runtime.__socketRegistry.update(0.01);
			if (@:privateAccess runtime.__socketRegistry.__moreToRead) {
				stopped++;
			}
		}
		backend.close();
		bridge.stop();

		Assert.isTrue(future.succeeded, "the response did not arrive whole: " + future.error);
		Assert.isTrue(stopped > 0, "no pass stopped at the read budget, with four budgets' worth to read");
		if (future.succeeded) {
			Assert.equals(4 * PHPBridge.READ_BUDGET, future.result.body.length);
		}
	}

	/**
		Polls the runtime's sockets the way its loop does between ticks, and
		never ticks: what arrives here is read on readiness or not at all.
	**/
	private static function __pollWithoutTicking(done:Void->Bool, seconds:Float):Void {
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (!done() && haxe.Timer.stamp() < deadline) {
			@:privateAccess runtime.__socketRegistry.update(0.1);

			if (!done()) {
				crossbyte.sys.System.sleep(0.001);
			}
		}
	}

	/**
		Reads what the bridge sends until its request has ended, as php-fpm
		would. The runtime is pumped meanwhile: the bridge connects on a thread
		of its own and writes the request once the runtime has the connection
		back. Read only when select says there is something, since eval cannot
		make a socket non-blocking.
	**/
	private static function __readRequest(peer:sys.net.Socket):FpmRequest {
		var runtime = crossbyte.core.CrossByte.current();
		var received = new BytesBuffer();
		var chunk:Bytes = Bytes.alloc(65536);
		var deadline:Float = haxe.Timer.stamp() + 10;
		var parsed:FpmRequest = __parseAsPhpFpm(Bytes.alloc(0));

		while (haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);

			if (sys.net.Socket.select([peer], [], [], 0.01).read.length == 0) {
				continue;
			}

			var n:Int = peer.input.readBytes(chunk, 0, chunk.length);
			received.addBytes(chunk, 0, n);

			var snapshot:Bytes = received.getBytes();
			parsed = __parseAsPhpFpm(snapshot);

			if (parsed.stdinEnded || parsed.errors.length > 0) {
				return parsed;
			}

			received = new BytesBuffer();
			received.add(snapshot);
		}

		return parsed;
	}

	private static function __request():PHPRequest {
		return {
			requestMethod: "GET",
			scriptFilename: "/srv/index.php",
			scriptName: "/index.php",
			requestUri: "/index.php",
			extraHeaders: new haxe.ds.StringMap<String>(),
			body: Bytes.alloc(0)
		};
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

	/** `cgi` as FCGI_STDOUT records of 60,000 bytes at most, then FCGI_END_REQUEST. **/
	private static function __records(cgi:Bytes):Bytes {
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

#if (cpp || jvm || eval)
/**
	A FastCGI backend on a plain blocking socket, driven step by step by the
	test: it takes the bridge's connection, and answers when told to.
**/
private class BlockingBackend {
	public var port(default, null):Int;

	private var listener:sys.net.Socket;
	private var peer:sys.net.Socket;
	private var peers:Array<sys.net.Socket> = [];

	public function new() {
		listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(4);
		port = listener.host().port;
	}

	/**
		The bridge's next connection. It is made on the bridge's connector
		thread, so it can arrive after `execute` returns; the runtime is pumped
		while it does.
	**/
	public function accept():sys.net.Socket {
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 10;

		while (sys.net.Socket.select([listener], [], [], 0.01).read.length == 0 && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
		}

		peer = listener.accept();
		peers.push(peer);
		return peer;
	}

	public function reply(bytes:Bytes):Void {
		peer.output.write(bytes);
		peer.output.flush();
	}

	/** Answers on a connection taken earlier. **/
	public function replyOn(socket:sys.net.Socket, bytes:Bytes):Void {
		socket.output.write(bytes);
		socket.output.flush();
	}

	/** Whether a connection waits to be taken within `seconds`, the runtime pumped meanwhile. **/
	public function pending(seconds:Float):Bool {
		var runtime = crossbyte.core.CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + seconds;
		while (haxe.Timer.stamp() < deadline) {
			if (sys.net.Socket.select([listener], [], [], 0.01).read.length > 0) {
				return true;
			}
			runtime.pump(1 / 60, 0.0);
		}
		return false;
	}

	public function close():Void {
		for (socket in peers.concat([listener])) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
	}
}
#end
