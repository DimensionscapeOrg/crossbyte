import LoadMain.Args;
import LoadStats.Histogram;
import LoadStats.ProcessStats;
import LoadStats.Report;
import crossbyte._internal.http.h2.H2Flags;
import crossbyte._internal.http.h2.H2Frame;
import crossbyte._internal.http.h2.H2FrameDecoder;
import crossbyte._internal.http.h2.H2FrameType;
import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import crossbyte.net.WebSocket;
import haxe.Timer;
import haxe.io.Bytes;

/**
	Churn clients for scenario S, written with CrossByte's own sockets: what
	`ChurnServer` runs where there is no Node, as on a Linux box without it.
	One process of `--procs`, by `--worker`; each reports its own windows.

	```
	LoadMain churn-bots --http P --https P --ws P --wss P --worker 0
	                    [--plan ...] [--procs 4] [--think 10] [--tls-share 0.5]
	```

	The same sessions as `churn-client.js`, with two differences that follow
	from the client rather than the server: a TLS connection here is a full
	handshake every time, since CrossByte's native client keeps no session to
	offer back, and HTTP/2 goes in clear only (`h2c`, prior knowledge), the
	native client having no ALPN to ask for `h2` with -- so the TLS share is
	taken from HTTP/1.1 and WebSocket.
**/
class ChurnBots {
	public static inline var TIMEOUT:Float = 15.0;

	public var http:Int;
	public var https:Int;
	public var ws:Int;
	public var wss:Int;
	public var think:Float;

	var runtime:CrossByte;
	var args:Args;
	var plan:Array<{concurrency:Int, seconds:Float}> = [];
	var procs:Int;
	var index:Int;
	var tlsShare:Float;
	var kinds:Array<String>;
	var reportEvery:Float;
	var opsMin:Int;
	var opsMax:Int;

	public var open:Int = 0;

	var target:Int = 0;
	var counts:Map<String, Float> = new Map();
	var errors:Map<String, Float> = new Map();
	var latency:Map<String, Histogram> = new Map();
	var lastSample:ProcessStats;
	var errorLines:Int = 0;

	public function new(runtime:CrossByte, args:Args) {
		this.runtime = runtime;
		this.args = args;
		http = args.int("http", 0);
		https = args.int("https", 0);
		ws = args.int("ws", 0);
		wss = args.int("wss", 0);
		think = args.float("think", 10) / 1000;
		procs = args.int("procs", 1);
		index = args.int("worker", 0);
		tlsShare = args.float("tls-share", 0.5);
		kinds = args.string("kinds", "h1,h2,ws").split(",");
		reportEvery = args.float("report", 10);
		var ops = args.string("ops", "5:50").split(":");
		opsMin = Std.parseInt(ops[0]);
		opsMax = ops.length > 1 ? Std.parseInt(ops[1]) : opsMin;
		if (opsMax < opsMin) {
			opsMax = opsMin;
		}
		for (part in args.string("plan", "50:60").split(",")) {
			var pair = part.split(":");
			plan.push({concurrency: Std.parseInt(pair[0]), seconds: Std.parseFloat(pair[1])});
		}
	}

	public function start():Void {
		runtime.tps = 100;
		lastSample = ProcessStats.sample();
		crossbyte.Timer.setInterval(reportEvery, reportEvery, __report);
		__phase(0);
	}

	function __phase(i:Int):Void {
		if (i >= plan.length) {
			target = 0;
			var giveUpAt:Float = Timer.stamp() + 20;
			var watch:Int = -1;
			watch = crossbyte.Timer.setInterval(0.1, 0.1, () -> {
				if (open > 0 && Timer.stamp() < giveUpAt) {
					return;
				}
				crossbyte.Timer.clear(watch);
				crossbyte.Timer.setTimeout(1.0, () -> {
					__report();
					Sys.exit(0);
				});
			});
			return;
		}
		var c:Int = plan[i].concurrency;
		target = Std.int(c / procs) + (index < c % procs ? 1 : 0);
		pump();
		crossbyte.Timer.setTimeout(plan[i].seconds, () -> __phase(i + 1));
	}

	/** Starts sessions while below this phase's share. **/
	public function pump():Void {
		while (open < target) {
			open++;
			var kind:String = kinds[Std.random(kinds.length)];
			var secure:Bool = kind != "h2" && Math.random() < tlsShare;
			var ops:Int = opsMin + Std.random(opsMax - opsMin + 1);
			switch (kind) {
				case "h1":
					new H1Session(this, secure, ops);
				case "h2":
					new H2cSession(this, ops);
				default:
					new WsSession(this, secure, ops);
			}
		}
	}

	public function ended():Void {
		open--;
		// Not from inside the ending session's own handler.
		crossbyte.Timer.setTimeout(0.0, pump);
	}

	public function count(name:String, n:Float = 1):Void {
		counts.set(name, (counts.exists(name) ? counts.get(name) : 0) + n);
	}

	public function fail(kind:String, reason:String):Void {
		var key:String = kind + ":" + (reason.length > 60 ? reason.substr(0, 60) : reason);
		errors.set(key, (errors.exists(key) ? errors.get(key) : 0) + 1);
		if (errorLines++ < 5) {
			Report.say("churn " + key);
		}
	}

	public function time(name:String, ms:Float):Void {
		var h:Histogram = latency.get(name);
		if (h == null) {
			h = new Histogram();
			latency.set(name, h);
		}
		h.add(ms);
	}

	public function thinkThen(next:Void->Void):Void {
		if (think <= 0) {
			next();
		} else {
			crossbyte.Timer.setTimeout(Math.random() * think, next);
		}
	}

	function __report():Void {
		var sample:ProcessStats = ProcessStats.sample();
		var c:Dynamic = {};
		for (name => n in counts) {
			Reflect.setField(c, name, n);
		}
		var e:Dynamic = {};
		for (name => n in errors) {
			Reflect.setField(e, name, n);
		}
		var l:Dynamic = {};
		for (name => h in latency) {
			Reflect.setField(l, name, h.encode());
		}
		Report.emit({
			kind: "churn-clients",
			concurrency: open,
			cpu: (sample.cpu - lastSample.cpu),
			counts: c,
			errors: e,
			latency: l
		});
		lastSample = sample;
		counts = new Map();
		errors = new Map();
		latency = new Map();
	}
}

/** What every session kind shares: its deadline, and ending once. **/
class ChurnSession {
	var bots:ChurnBots;
	var name:String;
	var ops:Int;
	var done:Int = 0;
	var started:Float;
	var sentAt:Float = 0;
	var deadline:Int = -1;
	var finished:Bool = false;

	public function new(bots:ChurnBots, name:String, ops:Int) {
		this.bots = bots;
		this.name = name;
		this.ops = ops;
		started = Timer.stamp();
	}

	function arm(what:String):Void {
		disarm();
		deadline = crossbyte.Timer.setTimeout(ChurnBots.TIMEOUT, () -> {
			deadline = -1;
			fail(what);
		});
	}

	function disarm():Void {
		if (deadline != -1) {
			crossbyte.Timer.clear(deadline);
			deadline = -1;
		}
	}

	function fail(reason:String):Void {
		if (finished) {
			return;
		}
		bots.fail(name, reason);
		abandon();
		finish();
	}

	function abandon():Void {}

	function finish():Void {
		if (finished) {
			return;
		}
		finished = true;
		disarm();
		bots.ended();
	}

	static function path(i:Int):String {
		return i % 7 == 3 ? "/page" : "/item/" + Std.random(100000);
	}

	static function body():ByteArray {
		var n:Int = 256 + Std.random(1024);
		var b = new ByteArray();
		b.length = n;
		for (i in 0...n) {
			b[i] = (i * 31 + n) & 0xFF;
		}
		return b;
	}
}

/** HTTP/1.1, one keep-alive connection, `Connection: close` on the last. **/
class H1Session extends ChurnSession {
	var socket:Socket;
	var buffer:ByteArray = new ByteArray();
	var expectLength:Int = -1;
	var bodyLength:Int = -1;
	var closing:Bool = false;
	// The server said Connection: close -- keepAliveMaxRequests -- before
	// this session's last request.
	var retiring:Bool = false;

	public function new(bots:ChurnBots, secure:Bool, ops:Int) {
		super(bots, secure ? "h1s" : "h1", ops);
		socket = new Socket();
		socket.secure = secure;
		socket.verifyCert = false;
		socket.timeout = Std.int(ChurnBots.TIMEOUT * 1000);
		socket.addEventListener(Event.CONNECT, _ -> {
			bots.time(name + ".setup", (Timer.stamp() - started) * 1000);
			if (secure) {
				bots.count("tls.full");
			}
			bots.count(name + ".sessions");
			send();
		});
		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			socket.readBytes(buffer, buffer.length, socket.bytesAvailable);
			parse();
		});
		socket.addEventListener(Event.CLOSE, _ -> {
			if (closing) {
				finish();
			} else {
				fail("closed");
			}
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> fail("io " + e.text));
		arm("connect timeout");
		try {
			socket.connect("127.0.0.1", secure ? bots.https : bots.http);
		} catch (error:Dynamic) {
			fail("connect " + Std.string(error));
		}
	}

	function send():Void {
		var last:Bool = done == ops - 1;
		var post:Bool = done % 3 == 1;
		var head = new StringBuf();
		var payload:ByteArray = post ? ChurnSession.body() : null;
		head.add(post ? "POST /echo" : "GET " + ChurnSession.path(done));
		head.add(" HTTP/1.1\r\nHost: localhost\r\n");
		if (post) {
			head.add("Content-Type: application/octet-stream\r\nContent-Length: " + payload.length + "\r\n");
		}
		if (last) {
			head.add("Connection: close\r\n");
		}
		head.add("\r\n");
		bodyLength = post ? payload.length : -1;
		sentAt = Timer.stamp();
		try {
			socket.writeUTFBytes(head.toString());
			if (post) {
				socket.writeBytes(payload);
			}
			socket.flush();
		} catch (error:Dynamic) {
			fail("write " + Std.string(error));
			return;
		}
		arm("response timeout");
	}

	function parse():Void {
		if (expectLength < 0) {
			var end:Int = find(buffer);
			if (end < 0) {
				return;
			}
			buffer.position = 0;
			var head:String = buffer.readUTFBytes(end);
			var status:Null<Int> = Std.parseInt(head.split(" ")[1]);
			var lengthMatch = ~/content-length:\s*([0-9]+)/i;
			if (status != 200 || !lengthMatch.match(head)) {
				fail("status " + status);
				return;
			}
			expectLength = Std.parseInt(lengthMatch.matched(1));
			if (~/connection:\s*close/i.match(head)) {
				retiring = true;
			}
			if (bodyLength >= 0 && expectLength != bodyLength) {
				fail("echo length");
				return;
			}
			// Drop the head.
			var rest = new ByteArray();
			if (buffer.length > end + 4) {
				rest.writeBytes(buffer, end + 4, buffer.length - end - 4);
			}
			buffer = rest;
		}
		if (buffer.length < expectLength) {
			return;
		}
		var rest = new ByteArray();
		if (buffer.length > expectLength) {
			rest.writeBytes(buffer, expectLength, buffer.length - expectLength);
		}
		buffer = rest;
		expectLength = -1;
		bots.time(name, (Timer.stamp() - sentAt) * 1000);
		bots.count(name + ".ops");
		done++;
		if (retiring && done < ops) {
			// A browser would go on over a new connection.
			bots.count(name + ".retired");
			done = ops;
		}
		if (done >= ops) {
			// The server closes after the last: wait for it, so the TIME_WAIT
			// is the server's, as with a browser's last request.
			closing = true;
			arm("server did not close");
			return;
		}
		disarm();
		bots.thinkThen(() -> {
			if (!finished) {
				send();
			}
		});
	}

	static function find(b:ByteArray):Int {
		var n:Int = b.length - 3;
		for (i in 0...(n > 0 ? n : 0)) {
			if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
				return i;
			}
		}
		return -1;
	}

	override function abandon():Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	override function finish():Void {
		if (!finished) {
			try {
				if (socket.connected) {
					socket.close();
				}
			} catch (_:Dynamic) {}
		}
		super.finish();
	}
}

/** CrossByte's `WebSocket` client: messages echoed, then a closing handshake. **/
class WsSession extends ChurnSession {
	var socket:WebSocket;
	var expected:Int = 0;
	var closing:Bool = false;

	public function new(bots:ChurnBots, secure:Bool, ops:Int) {
		super(bots, secure ? "wss" : "ws", ops);
		socket = new WebSocket();
		socket.secure = secure;
		socket.verifyCert = false;
		socket.timeout = Std.int(ChurnBots.TIMEOUT * 1000);
		socket.addEventListener(Event.CONNECT, _ -> {
			bots.time(name + ".upgrade", (Timer.stamp() - started) * 1000);
			if (secure) {
				bots.count("tls.full");
			}
			bots.count(name + ".sessions");
			send();
		});
		socket.addEventListener(WebSocketMessageEvent.MESSAGE, (e:WebSocketMessageEvent) -> {
			if (e.data.length != expected) {
				fail("bad echo");
				return;
			}
			bots.time(name, (Timer.stamp() - sentAt) * 1000);
			bots.count(name + ".ops");
			done++;
			if (done >= ops) {
				closing = true;
				arm("close timeout");
				try {
					socket.closeWith(1000);
				} catch (error:Dynamic) {
					fail("close " + Std.string(error));
				}
				return;
			}
			disarm();
			bots.thinkThen(() -> {
				if (!finished) {
					send();
				}
			});
		});
		socket.addEventListener(Event.CLOSE, _ -> {
			if (closing) {
				finish();
			} else {
				fail("closed");
			}
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> fail("io " + e.text));
		arm("connect timeout");
		try {
			socket.connect("127.0.0.1/chat", secure ? bots.wss : bots.ws);
		} catch (error:Dynamic) {
			fail("connect " + Std.string(error));
		}
	}

	function send():Void {
		var n:Int = 32 + Std.random(480);
		var payload = new ByteArray();
		payload.length = n;
		expected = n;
		sentAt = Timer.stamp();
		try {
			socket.sendBinary(payload, 0, n);
		} catch (error:Dynamic) {
			fail("send " + Std.string(error));
			return;
		}
		arm("echo timeout");
	}

	override function abandon():Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}

/**
	HTTP/2 in clear with prior knowledge, requests one after another on one
	connection, then a GOAWAY: CrossByte's frame and HPACK codecs, driven
	over a plain `Socket`.
**/
class H2cSession extends ChurnSession {
	static var PREFACE:Bytes = Bytes.ofString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");

	var socket:Socket;
	var decoder:H2FrameDecoder = new H2FrameDecoder();
	var encoder:HpackEncoder = new HpackEncoder();
	var hpack:HpackDecoder = new HpackDecoder();
	var stream:Int = -1;
	var status:Int = 0;
	var received:Int = 0;
	var bodyLength:Int = -1;
	var closing:Bool = false;
	// The server's GOAWAY -- keepAliveMaxRequests -- before this session's
	// last request: the stream in flight is answered, and the session ends.
	var retiring:Bool = false;
	var scratch:ByteArray = new ByteArray();

	public function new(bots:ChurnBots, ops:Int) {
		super(bots, "h2", ops);
		socket = new Socket();
		socket.timeout = Std.int(ChurnBots.TIMEOUT * 1000);
		socket.addEventListener(Event.CONNECT, _ -> {
			bots.time(name + ".setup", (Timer.stamp() - started) * 1000);
			bots.count(name + ".sessions");
			write(PREFACE);
			write(H2Frame.encode(H2FrameType.SETTINGS, 0, 0, null));
			send();
		});
		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			scratch.length = 0;
			socket.readBytes(scratch, 0, socket.bytesAvailable);
			decoder.feed(scratch, 0, scratch.length);
			var frame:Null<H2Frame> = null;
			while (!finished && (frame = decoder.next()) != null) {
				onFrame(frame);
			}
		});
		socket.addEventListener(Event.CLOSE, _ -> {
			if (closing) {
				finish();
			} else {
				fail("closed");
			}
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> fail("io " + e.text));
		arm("connect timeout");
		try {
			socket.connect("127.0.0.1", bots.http);
		} catch (error:Dynamic) {
			fail("connect " + Std.string(error));
		}
	}

	function write(bytes:Bytes):Void {
		socket.writeBytes(ByteArray.fromBytes(bytes));
	}

	function send():Void {
		stream = stream < 0 ? 1 : stream + 2;
		status = 0;
		received = 0;
		var post:Bool = done % 3 == 1;
		var headers:Array<HpackHeader> = [
			new HpackHeader(":method", post ? "POST" : "GET"),
			new HpackHeader(":scheme", "http"),
			new HpackHeader(":authority", "localhost"),
			new HpackHeader(":path", post ? "/echo" : ChurnSession.path(done))
		];
		sentAt = Timer.stamp();
		try {
			if (post) {
				var payload:ByteArray = ChurnSession.body();
				bodyLength = payload.length;
				headers.push(new HpackHeader("content-type", "application/octet-stream"));
				headers.push(new HpackHeader("content-length", Std.string(payload.length)));
				write(H2Frame.encode(H2FrameType.HEADERS, H2Flags.END_HEADERS, stream, encoder.encode(headers)));
				write(H2Frame.encode(H2FrameType.DATA, H2Flags.END_STREAM, stream, (payload : Bytes), 0, payload.length));
			} else {
				bodyLength = -1;
				write(H2Frame.encode(H2FrameType.HEADERS, H2Flags.END_HEADERS | H2Flags.END_STREAM, stream, encoder.encode(headers)));
			}
			socket.flush();
		} catch (error:Dynamic) {
			fail("write " + Std.string(error));
			return;
		}
		arm("response timeout");
	}

	function onFrame(frame:H2Frame):Void {
		switch (frame.type) {
			case H2FrameType.SETTINGS:
				if (!frame.has(H2Flags.ACK)) {
					write(H2Frame.encode(H2FrameType.SETTINGS, H2Flags.ACK, 0, null));
					socket.flush();
				}
			case H2FrameType.PING:
				if (!frame.has(H2Flags.ACK)) {
					write(H2Frame.encode(H2FrameType.PING, H2Flags.ACK, 0, frame.payload));
					socket.flush();
				}
			case H2FrameType.HEADERS:
				// Every block is decoded, ours or not, to keep the table in step.
				for (header in hpack.decode(frame.payload)) {
					if (header.name == ":status") {
						status = Std.parseInt(header.value);
					}
				}
				if (frame.streamId == stream && frame.has(H2Flags.END_STREAM)) {
					complete();
				}
			case H2FrameType.DATA:
				if (frame.streamId == stream) {
					received += frame.payload.length;
					// The connection's window, given back as it is read; the
					// stream's is new with each request.
					if (frame.payload.length > 0) {
						var increment = Bytes.alloc(4);
						increment.set(0, (frame.payload.length >> 24) & 0x7F);
						increment.set(1, (frame.payload.length >> 16) & 0xFF);
						increment.set(2, (frame.payload.length >> 8) & 0xFF);
						increment.set(3, frame.payload.length & 0xFF);
						write(H2Frame.encode(H2FrameType.WINDOW_UPDATE, 0, 0, increment));
						socket.flush();
					}
					if (frame.has(H2Flags.END_STREAM)) {
						complete();
					}
				}
			case H2FrameType.GOAWAY:
				retiring = true;
			case H2FrameType.RST_STREAM:
				if (frame.streamId == stream) {
					fail("rst_stream");
				}
			default:
		}
	}

	function complete():Void {
		if (status != 200 || (bodyLength >= 0 && received != bodyLength)) {
			fail("status " + status);
			return;
		}
		bots.time(name, (Timer.stamp() - sentAt) * 1000);
		bots.count(name + ".ops");
		done++;
		if (retiring && done < ops) {
			bots.count(name + ".retired");
			done = ops;
		}
		if (done >= ops) {
			closing = true;
			var goaway = Bytes.alloc(8);
			goaway.set(0, (stream >> 24) & 0x7F);
			goaway.set(1, (stream >> 16) & 0xFF);
			goaway.set(2, (stream >> 8) & 0xFF);
			goaway.set(3, stream & 0xFF);
			try {
				write(H2Frame.encode(H2FrameType.GOAWAY, 0, 0, goaway));
				socket.flush();
				socket.close();
			} catch (_:Dynamic) {}
			finish();
			return;
		}
		disarm();
		bots.thinkThen(() -> {
			if (!finished) {
				send();
			}
		});
	}

	override function abandon():Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}
