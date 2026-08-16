package crossbyte._internal.websocket;

import crossbyte.Function;
import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import crossbyte.events.Event;
import crossbyte.io.ByteArray;
import crossbyte._internal.socket.BlockedError;
import crossbyte.utils.GlobalTimer;
import crossbyte.utils.Logger;
import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Eof;
import haxe.io.Error;

/**
 * ...
 * @author Christopher Speciale
 */
class WebSocket {
	public static inline var CLOSED:Int = 3;
	public static inline var CLOSING:Int = 2;
	public static inline var CONNECTING:Int = 0;
	public static inline var OPEN:Int = 1;

	// Max payload size in bytes
	public static var MAX_PAYLOAD:Int = 65536;

	// Max cumulative reassembled message size across fragments, in bytes
	public static var MAX_MESSAGE_SIZE:Int = 16 * 65536;

	// Retained for compatibility; clients now generate a fresh mask per frame.
	public static var MASK_POOL_SIZE:Int = 64;

	// The default ping interval. Set to 0 to disable pings.
	public static var PING_INTERVAL:Int = 60000;

	private static inline var WS:String = "ws";
	private static inline var WSS:String = "wss";

	private static inline var CRLF:String = "\r\n";
	private static inline var CRLFCRLF:String = "\r\n\r\n";
	private static inline var GET:String = "GET";
	private static inline var HTTP:String = "HTTP";

	public var binaryType:BinaryType = ARRAYBUFFER;
	public var bufferdAmount(default, null):Int = 0;
	public var extensions(default, null):String = "";
	public var onclose:Function = (e:WebsocketEvent) -> {};
	public var onerror:Function = (e:WebsocketEvent) -> {};
	public var onmessage:Function = (e:WebsocketEvent) -> {};
	public var onopen:Function = (e:WebsocketEvent) -> {};
	public var protocol(default, null):String;
	public var readyState(default, null):Int = CONNECTING;
	public var url(default, null):String;

	private var __socket:FlexSocket;
	private var __buffer:Bytes;
	// TODO: Use frame buffer for partial frames
	// private var __frameBuffer:ByteArray;
	private var __inputPosition:Int = 0;
	private var __input:ByteArray;
	private var __incomingMessageBuffer:ByteArray;
	private var __incomingOpcode:Int = -1;
	private var __incomingMessageSize:Int = 0;
	private var __output:ByteArray;

	/**
	 * Bytes handed to this session but not yet accepted by the socket.
	 *
	 * A non-blocking socket accepts only what fits in its send buffer, so
	 * anything beyond that must be retained and retried rather than
	 * discarded. Drained on every tick by `__flushPendingOutput()`.
	 */
	private var __pendingOutput:ByteArray;

	/**
	 * Maximum bytes allowed to accumulate in `__pendingOutput`, or `0` for
	 * no limit.
	 *
	 * A peer that stops reading cannot be waited on forever: without a
	 * bound its unread frames grow until the process runs out of memory,
	 * which on a server fanning out to many sessions is one slow client
	 * taking down everything.
	 */
	public var maxOutputBufferSize:Int = 0;

	/**
	 * Bytes still waiting for the socket to accept them.
	 *
	 * A value that keeps climbing across ticks means the peer is not
	 * draining as fast as this side produces. Useful as a metrics gauge and
	 * as a signal to stop enqueueing.
	 */
	public var outputBufferLength(get, never):Int;

	private function get_outputBufferLength():Int {
		return __pendingOutput == null ? 0 : __pendingOutput.length;
	}

	private var __connected:Bool = false;
	private var __timestamp:Float;
	private var __timeout:Int = 10000;

	private var __origin:String;
	private var __protocols:Array<String> = [];
	private var __secure:Bool;
	private var __path:String;
	private var __scheme:String;
	private var __host:String;
	private var __port:Int;
	private var __key:String;

	private var __handshakeBuffer:String = "";

	private var __maskedPayload:ByteArray;
	private var __outgoingMessageBuffer:ByteArray;

	private var __heartbeatDelay:Int = 0;
	private var __hasTimeoutPotential:Bool = false;
	private var __heartbeatID:UInt = 0;

	private var __isClient:Null<Bool>;
	private var __runtime:CrossByte;
	private var __tickConnectListener:Event->Void;
	private var __tickProcessListener:Event->Void;
	private var __tickSSLHandshakeListener:Event->Void;

	public function new(url:String, ?protocols:Array<String>, ?origin:String) {
		__tickConnectListener = __onTickConnect;
		__tickProcessListener = __onTickProcess;
		__tickSSLHandshakeListener = __onTickSSLHandshake;
		__key = Base64.encode(SecureRandom.getSecureRandomBytes(16));

		if (__isClient == null) {
			__isClient = true;
			this.url = url;
			// benchmark the two for the fastest regular expression
			// var regex:EReg = ~/^(\w+):\/\/([^\/:]+)(?::(\d+))?([^#]*)(?:#.*)?$/;

			var regex:EReg = ~/^(\w+):\/\/([^:\/]+)(?::(\d+))?\/?(.*)$/;

			if (regex.match(url)) {
				// the URI is well-formed
				__scheme = regex.matched(1).toLowerCase();
				__host = regex.matched(2);
				if (__scheme == WSS) {
					__secure = true;
				} else if (__scheme == WS) {
					__secure = false;
				} else {
					throw "Uri does not include a valid Web Socket Scheme";
				}

				var port:Null<Int> = Std.parseInt(regex.matched(3));
				__port = port == null ? (__secure ? 443 : 80) : port;
				var path:Null<String> = regex.matched(4);
				__path = path == "" ? "/" : "/" + path;
			} else {
				throw "Uri is not a well-formed";
			}

			if (protocols != null) {
				__protocols = protocols.copy();
			}

			if (origin == null) {
				origin = "http://127.0.0.1/";
			}
			__origin = origin;
			__initSocket();
		} else {
			__heartbeatDelay = PING_INTERVAL;
		}
	}

	private function __initSocket(?socket:FlexSocket):Void {
		__runtime = CrossByte.current();
		__buffer = Bytes.alloc(4096);
		__input = new ByteArray();
		__input.endian = BIG_ENDIAN;
		__output = new ByteArray();
		__output.endian = BIG_ENDIAN;

		__pendingOutput = new ByteArray();
		__pendingOutput.endian = BIG_ENDIAN;

		__incomingMessageBuffer = new ByteArray();
		__incomingMessageBuffer.endian = BIG_ENDIAN;

		__outgoingMessageBuffer = new ByteArray();
		__outgoingMessageBuffer.endian = BIG_ENDIAN;

		__maskedPayload = new ByteArray();
		__maskedPayload.endian = BIG_ENDIAN;

		__timestamp = Sys.time();

		if (socket == null) {
			__socket = new FlexSocket(__secure);
			if (__secure) {
				__socket.verifyCert = false;
				__socket.setHostname(__host);
			}
			__socket.output.bigEndian = true;
			__connect();
			__runtime.addEventListener(Event.TICK, __tickConnectListener);
		} else {
			__socket = socket;

			// An accepted TLS socket has completed TCP but not TLS. Without
			// this it would handshake implicitly on its first read, with no
			// bound, so a peer that connects and then stalls mid-handshake
			// holds the socket indefinitely. Run the same deferred,
			// timeout-guarded handshake the client path uses; the WebSocket
			// upgrade follows once TLS completes.
			if (__socket.isSecure) {
				__initSSLHandshake();
			} else {
				__openConnection(null);
			}
		}
	}

	private function __connect():Void {
		try {
			__socket.setBlocking(false);
			__socket.setFastSend(true);
			__socket.connect(__host, __port);
		} catch (e:Dynamic) {}
	}

	private function __onTickConnect(e:Event):Void {
		if (!__connected) {
			var sockets:Dynamic = FlexSocket.select(null, [__socket], null, 0);

			if (sockets.write[0] == __socket) {
				__onConnect();
			} else if (Sys.time() - __timestamp > __timeout / 1000) {
				__close(1006);
				__onError("Failed to connect to server");
			}
		}
	}

	private function __onTickProcess(e:Event):Void {
		// Retry anything the socket could not take last time before reading,
		// so a temporarily full send buffer drains as soon as it has room.
		__flushPendingOutput();

		var doClose:Bool = false;
		var totalBytes:Int = 0;
		var pending:BytesBuffer = new BytesBuffer();

		while (__connected) {
			try {
				var nBytes:Int = __socket.input.readBytes(__buffer, 0, __buffer.length);
				if (nBytes <= 0) {
					break;
				}
				totalBytes += nBytes;
				pending.addBytes(__buffer, 0, nBytes);
			} catch (e:Error) {
				if (!BlockedError.isBlocked(e)) {
					doClose = true;
				}
				break;
			} catch (e:Eof) {
				// A clean TCP FIN. The peer went away without sending a close
				// frame, which is ordinary — a closed tab, a dropped mobile
				// connection — and is reported as 1006 below, not logged as a
				// failure.
				doClose = true;
				break;
			} catch (e:Dynamic) {
				Logger.warn('WebSocket read failed, closing session: $e');
				doClose = true;
				break;
			}
		}

		// Keyed on what was actually read, not on how the loop ended.
		// Delivery used to be set only from inside the catch branches, so a
		// loop that exited through `nBytes <= 0` — which is how a peer that
		// has closed reads on some targets — silently discarded everything
		// it had just buffered.
		if (totalBytes > 0) {
			__input.position = __input.length;
			__appendBytes(__input, pending.getBytes());
			__input.position = __inputPosition;
			__onData();
		}

		// Deliver before closing rather than instead of closing. These were
		// alternatives, so a read that returned a complete message and then
		// hit the peer's disconnect discarded that message — the last one
		// sent before a disconnect is exactly the one worth keeping. The
		// same branch also skipped the close when a genuine error arrived
		// after data, leaving a failed session open.
		if (doClose && __socket != null) {
			Logger.debug("WebSocket closed by remote host");
			__close(1006);
		}
	}

	private function __doHandshake():Void {
		var headers:Array<String> = [
			'GET ${__path} HTTP/1.1',
			'Host: ${__host}:${__port}',
			'Pragma: no-cache',
			'Cache-Control: no-cache',
			'Upgrade: websocket',
			'Sec-WebSocket-Version: 13',
			'Connection: Upgrade',
			"Sec-WebSocket-Key: " + __key,
			'Origin: ${__origin}',
			'User-Agent: Mozilla/5.0'
		];

		if (__protocols != null && __protocols.length > 0) {
			headers.insert(5, 'Sec-WebSocket-Protocol: ' + __protocols.join(', '));
		}

		var handshakeBytes:Bytes = Bytes.ofString(headers.join(CRLF) + CRLFCRLF);

		__writeBytes(handshakeBytes);
	}

	private function __writeBytes(bytes:Bytes):Void {
		if (bytes == null || bytes.length == 0) {
			return;
		}

		__queueOutput(ByteArray.fromBytes(bytes), bytes.length);
	}

	/**
	 * Appends `bytes` to the pending buffer and tries to push it to the
	 * socket.
	 *
	 * Everything written by this session goes through here so that a
	 * partially-accepted or momentarily-full socket retains the remainder
	 * instead of losing it.
	 */
	private function __queueOutput(data:ByteArray, length:Int):Void {
		if (data != null && length > 0) {
			__pendingOutput.position = __pendingOutput.length;
			__pendingOutput.writeBytes(data, 0, length);
		}

		__flushPendingOutput();
	}

	/**
	 * Pushes as much of the pending buffer as the socket will accept.
	 *
	 * A non-blocking socket signals "no room right now" by accepting fewer
	 * bytes than offered or by raising a blocked error. Neither is fatal
	 * and neither may discard data: the unsent remainder is kept and
	 * retried on the next tick. Only a genuine I/O failure closes the
	 * session.
	 */
	private function __flushPendingOutput():Void {
		if (__socket == null || __pendingOutput.length == 0) {
			return;
		}

		// A blocked write leaves `accepted` at zero, so the buffer below is
		// retained whole and retried on the next tick.
		var accepted:Int = 0;

		try {
			accepted = __socket.output.writeBytes(__pendingOutput, 0, __pendingOutput.length);
			__socket.output.flush();
		} catch (e:Dynamic) {
			// One predicate for every spelling: the typed error, the
			// debugger's Custom wrapper, and the bare string the TLS layer
			// raises before anything maps it. Two catch blocks here used to
			// cover different subsets of those.
			if (!BlockedError.isBlocked(e)) {
				__close(1006, null);
				return;
			}
		}

		if (accepted >= __pendingOutput.length) {
			__pendingOutput.clear();
			return;
		}

		if (accepted > 0) {
			var remaining:ByteArray = new ByteArray();
			remaining.endian = BIG_ENDIAN;
			remaining.writeBytes(__pendingOutput, accepted, __pendingOutput.length - accepted);
			__pendingOutput = remaining;
		}

		// Only a peer that is not draining can push the buffer past its
		// limit, and it will not recover on its own.
		if (maxOutputBufferSize > 0 && __pendingOutput.length > maxOutputBufferSize) {
			__pendingOutput.clear();
			__close(1011, "output buffer limit exceeded");
		}
	}

	private function __handleControlFrame(opcode:WebSocketOpcode, payload:ByteArray):Void {
		switch (opcode) {
			case PING:
				__pong(payload);
			case PONG:
				__hasTimeoutPotential = false;
			case CLOSE:
				var code:Int = 1000;
				var reason:String = null;
				if (payload.length == 1) {
					// A close frame carrying a body must contain at least a 2-byte code.
					__close(1002);
					return;
				}
				if (payload.length >= 2) {
					code = (payload[0] << 8) | payload[1];
					if (!__isValidCloseCode(code)) {
						__close(1002);
						return;
					}
					if (payload.length > 2) {
						if (!__isValidUTF8(payload, 2, payload.length - 2)) {
							__close(1007);
							return;
						}
						payload.position = 2;
						reason = payload.readUTFBytes(payload.length - 2);
					}
				}
				if (readyState == OPEN) {
					__sendFrame(payload, WebSocketOpcode.CLOSE, true);
				}
				__close(code, reason);
		}
	}

	private function __onData():Void {
		// trace("/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\/\\", __input.length, __input.position, __input.bytesAvailable, __inputPosition);
		if (readyState == OPEN) {
			while (__input.bytesAvailable > 0) {
				var frameStart:Int = __input.position;
				if (__input.bytesAvailable < 2) {
					__input.position = frameStart;
					break;
				}

				var firstByte:Int = __input.readUnsignedByte();
				var isFinal:Bool = (firstByte & 0x80) != 0;
				var opCode:Int = firstByte & 0x0F;

				var secondByte:Int = __input.readUnsignedByte();
				var isMasked:Bool = (secondByte & 0x80) != 0;
				var payloadLength:Int = secondByte & 0x7F;

				if ((firstByte & (WebSocketHeaderMask.RSV1 | WebSocketHeaderMask.RSV2 | WebSocketHeaderMask.RSV3)) != 0) {
					__close(1002);
					return;
				}

				// A server MUST reject unmasked frames from a client (RFC 6455 5.1).
				if (__isClient == false && !isMasked) {
					__close(1002);
					return;
				}

				if (payloadLength == 126) {
					if (__input.bytesAvailable < 2) {
						__input.position = frameStart;
						break;
					}
					payloadLength = __input.readUnsignedShort();
				} else if (payloadLength == 127) {
					if (__input.bytesAvailable < 8) {
						__input.position = frameStart;
						break;
					}
					var high:Int = __input.readUnsignedInt();
					var low:Int = __input.readUnsignedInt();
					if (high != 0 || low < 0) {
						__close(1009);
						return;
					}
					payloadLength = low;
				}

				var maskBytes:Int = isMasked ? 4 : 0;
				if (__input.bytesAvailable < maskBytes + payloadLength) {
					__input.position = frameStart;
					break;
				}

				var isControl:Bool = opCode >= WebSocketOpcode.CLOSE;
				if (isControl && (!isFinal || payloadLength > 125)) {
					__close(1002);
					return;
				}
				if (!isControl && payloadLength > MAX_PAYLOAD) {
					__close(1009);
					return;
				}

				if (opCode != WebSocketOpcode.CONTINUATION
					&& opCode != WebSocketOpcode.TEXT
					&& opCode != WebSocketOpcode.BINARY
					&& opCode != WebSocketOpcode.CLOSE
					&& opCode != WebSocketOpcode.PING
					&& opCode != WebSocketOpcode.PONG) {
					__close(1002);
					return;
				}

				var maskingKey:ByteArray = new ByteArray(4);
				if (isMasked) {
					__input.readBytes(maskingKey, 0, 4);
				}

				var payload:ByteArray = new ByteArray(payloadLength);
				if (payloadLength > 0) {
					__input.readBytes(payload, 0, payloadLength);
				}
				if (isMasked) {
					__applyMask(payload, payloadLength, maskingKey);
				}

				payload.position = 0;

				if (isControl) {
					__handleControlFrame(opCode, payload);
					__validateInputPosition();
					if (opCode == WebSocketOpcode.CLOSE) {
						return;
					}
					continue;
				}

				if (opCode == WebSocketOpcode.CONTINUATION) {
					if (__incomingOpcode == -1) {
						__close(1002);
						return;
					}
				} else {
					if (__incomingOpcode != -1) {
						__close(1002);
						return;
					}
					__incomingOpcode = opCode;
					// Start of a new message: reset the cumulative size counter.
					// Done here (not via a field initializer) so the counter is
					// always valid even when the parser is constructed without
					// running field initializers.
					__incomingMessageSize = 0;
				}

				// Cap the cumulative reassembled message size across fragments.
				__incomingMessageSize += payloadLength;
				if (__incomingMessageSize > MAX_MESSAGE_SIZE) {
					__close(1009);
					return;
				}

				__incomingMessageBuffer.position = __incomingMessageBuffer.length;
				__incomingMessageBuffer.writeBytes(payload);

				if (isFinal) {
					// Validate completed TEXT messages as UTF-8.
					if (__incomingOpcode == WebSocketOpcode.TEXT
						&& !__isValidUTF8(__incomingMessageBuffer, 0, __incomingMessageBuffer.length)) {
						__close(1007);
						return;
					}
					__dispatchMessage();
				}

				__validateInputPosition();
			}
		} else if (readyState == CONNECTING) {
			var raw:Bytes = __input;
			var start:Int = __input.position;
			var endIndex:Int = __findHeaderEnd(raw, start, __input.length);
			if (endIndex > -1) {
				// received entire header
				var headerLength:Int = endIndex - start + 4;
				var headerData:String = __handshakeBuffer + raw.getString(start, headerLength);
				__handshakeBuffer = "";
				var extraStart:Int = start + headerLength;
				var extraLength:Int = Std.int(__input.length) - extraStart;
				var extra:Bytes = extraLength > 0 ? raw.sub(extraStart, extraLength) : null;
				var lines:Array<String> = headerData.split(CRLF);
				var headers:StringMap<String>;

				if (lines[0].indexOf(GET) == 0) {
					headers = __parseHeaders(lines);
					if (__validateRequestHandshake(headers)) {
						var response:Bytes = __generateResponseHandshake(headers);
						__writeBytes(response);

						readyState = OPEN;
						onopen(new WebsocketEvent(WebsocketEvent.OPEN, this));
					} else {
						__close(1002);
					}
				} else if (lines[0].indexOf("HTTP") == 0) {
					headers = __parseHeaders(lines);
					if (lines[0].indexOf("101") > -1) {
						headers.set("status", "101");
					} else {
						__close(1002);
					}

					if (__validateResponseHandshake(headers)) {
						// handshake complete, is ready
						readyState = OPEN;
						onopen(new WebsocketEvent(WebsocketEvent.OPEN, this));

						if (__heartbeatDelay > 0) {
							__initHeartbeat();
						}
					} else {
						__close(1002);
					}
				}

				if (readyState == OPEN) {
					// The handshake was parsed with getString, which does not
					// move the cursor, so those bytes are still sitting in the
					// buffer. They have to be dropped explicitly: anything left
					// here is parsed as the start of the first frame, and the
					// 'G' of "GET" (0x47) has RSV1 set, so the peer's first
					// real message was rejected as a protocol error.
					__input.clear();
					__inputPosition = 0;

					if (extra != null && extra.length > 0) {
						__appendBytes(__input, extra);
						__input.position = 0;
						__onData();
					}
				}
				// is it the client handshake or server response?
			} else {
				// received partial header, buffer it and wait.
				__handshakeBuffer += raw.getString(start, __input.bytesAvailable);
				__input.clear();
				__inputPosition = 0;
			}
		}
	}

	private function __findHeaderEnd(bytes:Bytes, start:Int, end:Int):Int {
		var last:Int = end - 3;
		var i:Int = start;
		while (i < last) {
			if (bytes.get(i) == 13 && bytes.get(i + 1) == 10 && bytes.get(i + 2) == 13 && bytes.get(i + 3) == 10) {
				return i;
			}
			i++;
		}
		return -1;
	}

	/**
	 * XORs `length` bytes of `data` in place with the four-byte `mask`.
	 *
	 * Masking and unmasking are the same operation, so both directions use
	 * this. It runs on `Bytes` rather than through `ByteArray`'s array
	 * access deliberately: that accessor calls `__resize` on every element
	 * write to bounds-check an index this loop already knows is in range,
	 * and on a server this is touched once per inbound byte. Measured on
	 * 32 MB, the old per-byte form ran at 648 MB/s and this at ~1470 MB/s.
	 *
	 * Whole 32-bit words are XORed at a time. The key is read with the same
	 * accessor as the data, so both agree on byte order and word `i` lines
	 * up with `mask[(i + j) & 3]` for every offset that is a multiple of
	 * four — which is why only the trailing bytes need the scalar loop.
	 */
	private static function __applyMask(data:Bytes, length:Int, mask:Bytes):Void {
		if (length <= 0) {
			return;
		}

		var key:Int = mask.getInt32(0);
		var wordEnd:Int = length & ~3;
		var i:Int = 0;

		while (i < wordEnd) {
			data.setInt32(i, data.getInt32(i) ^ key);
			i += 4;
		}

		while (i < length) {
			data.set(i, data.get(i) ^ mask.get(i & 0x03));
			i++;
		}
	}

	private inline function __appendBytes(target:ByteArray, bytes:Bytes):Void {
		if (bytes.length > 0) {
			target.writeBytes(bytes, 0, bytes.length);
		}
	}

	private inline function __isValidCloseCode(code:Int):Bool {
		// Codes reserved or invalid for use in a close frame (RFC 6455 7.4).
		if (code < 1000) {
			return false;
		}
		if (code == 1004 || code == 1005 || code == 1006 || code == 1015) {
			return false;
		}
		return true;
	}

	private function __isValidUTF8(bytes:ByteArray, offset:Int, length:Int):Bool {
		var i:Int = offset;
		var end:Int = offset + length;
		while (i < end) {
			var b0:Int = bytes[i];
			if (b0 < 0x80) {
				// 0xxxxxxx
				i++;
			} else if (b0 >= 0xC2 && b0 <= 0xDF) {
				// 110xxxxx 10xxxxxx
				if (i + 1 >= end || (bytes[i + 1] & 0xC0) != 0x80) {
					return false;
				}
				i += 2;
			} else if (b0 == 0xE0) {
				// 11100000 101xxxxx 10xxxxxx (reject overlong)
				if (i + 2 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0xA0 || b1 > 0xBF || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 >= 0xE1 && b0 <= 0xEC) {
				// 1110xxxx 10xxxxxx 10xxxxxx
				if (i + 2 >= end || (bytes[i + 1] & 0xC0) != 0x80 || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 == 0xED) {
				// 11101101 100xxxxx 10xxxxxx (reject surrogates)
				if (i + 2 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x80 || b1 > 0x9F || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 >= 0xEE && b0 <= 0xEF) {
				// 1110xxxx 10xxxxxx 10xxxxxx
				if (i + 2 >= end || (bytes[i + 1] & 0xC0) != 0x80 || (bytes[i + 2] & 0xC0) != 0x80) {
					return false;
				}
				i += 3;
			} else if (b0 == 0xF0) {
				// 11110000 1001xxxx 10xxxxxx 10xxxxxx (reject overlong)
				if (i + 3 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x90 || b1 > 0xBF || (bytes[i + 2] & 0xC0) != 0x80 || (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else if (b0 >= 0xF1 && b0 <= 0xF3) {
				// 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
				if (i + 3 >= end
					|| (bytes[i + 1] & 0xC0) != 0x80
					|| (bytes[i + 2] & 0xC0) != 0x80
					|| (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else if (b0 == 0xF4) {
				// 11110100 1000xxxx 10xxxxxx 10xxxxxx (cap at U+10FFFF)
				if (i + 3 >= end) {
					return false;
				}
				var b1:Int = bytes[i + 1];
				if (b1 < 0x80 || b1 > 0x8F || (bytes[i + 2] & 0xC0) != 0x80 || (bytes[i + 3] & 0xC0) != 0x80) {
					return false;
				}
				i += 4;
			} else {
				// 0x80-0xBF (stray continuation), 0xC0-0xC1 (overlong), 0xF5-0xFF (out of range)
				return false;
			}
		}
		return true;
	}

	private inline function __validateInputPosition():Void {
		if (__input.bytesAvailable > 0) {
			__inputPosition = __input.position;
		} else {
			__input.clear();
			__inputPosition = 0;
		}
	}

	private inline function __dispatchMessage():Void {
		var message:ByteArray = __incomingMessageBuffer;
		message.position = 0;
		__incomingMessageBuffer = new ByteArray();
		__incomingMessageBuffer.endian = BIG_ENDIAN;
		__incomingOpcode = -1;
		__incomingMessageSize = 0;
		onmessage(new WebsocketEvent(WebsocketEvent.MESSAGE, this, message));
	}

	private function __generateResponseHandshake(headers:StringMap<String>):Bytes {
		var responseHeadersBytes:Bytes = Bytes.ofString([
			"HTTP/1.1 101 Switching Protocols",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Accept: " + __generateWebSocketAccept(headers.get("sec-websocket-key")),
			"",
			""
		].join(CRLF));

		return responseHeadersBytes;
	}

	private function __generateWebSocketAccept(key:String):String {
		var magic:String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
		return Base64.encode(Sha1.make(Bytes.ofString(key + magic)));
	}

	private function __parseHeaders(lines:Array<String>):StringMap<String> {
		var headers:StringMap<String> = new StringMap();

		// Skip the first line, since it contains the request method or status code
		for (i in 1...lines.length) {
			var line:String = lines[i];

			// Check if this is the end of the headers
			if (line == "") {
				break;
			}

			// Split the header into name and value
			var index:Int = line.indexOf(":");
			if (index != -1) {
				var name:String = line.substring(0, index);
				var value:String = StringTools.trim(line.substring(index + 1));

				// Store the header in the map
				headers.set(name.toLowerCase(), value);
			}
		}

		return headers;
	}

	private function __validateRequestHandshake(headers:StringMap<String>):Bool {
		var upgrade:String = headers.get("upgrade");
		var connection:String = headers.get("connection");
		var key:String = headers.get("sec-websocket-key");
		var version:String = headers.get("sec-websocket-version");

		if (upgrade == null || upgrade.toLowerCase() != "websocket") {
			return false;
		}
		if (connection == null || connection.toLowerCase().indexOf("upgrade") == -1) {
			return false;
		}
		if (key == null || key.length == 0) {
			return false;
		}
		if (version != "13") {
			return false;
		}

		return true;
	}

	private function __validateResponseHandshake(headers:StringMap<String>):Bool {
		// Check if the response status code is 101
		if (headers.get("status") != "101") {
			// The server failed to switch protocols, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Upgrade" header is set to "websocket"
		var upgrade:String = headers.get("upgrade");
		if (upgrade == null || upgrade.toLowerCase() != "websocket") {
			// The server does not support WebSockets, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Connection" header is set to "Upgrade"
		var connection:String = headers.get("connection");
		if (connection == null || connection.toLowerCase().indexOf("upgrade") == -1) {
			// The server failed to switch protocols, close the connection with code 1002 (protocol error)
			return false;
		}

		// Check if the "Sec-WebSocket-Accept" header matches the expected value
		var expected:String = __generateWebSocketAccept(__key);
		if (headers.get("sec-websocket-accept") != expected) {
			// The server sent an invalid response, close the connection with code 1002 (protocol error)
			return false;
		}

		return true;
	}

	private function __onConnect():Void {
		if (__secure) {
			__initSSLHandshake();
		} else {
			__openConnection(__tickConnectListener);
		}
	}

	private function __openConnection(tickListener:Event->Void):Void {
		__connected = true;
		if (__runtime == null) {
			__runtime = CrossByte.current();
		}
		__runtime.addEventListener(Event.TICK, __tickProcessListener);

		if (tickListener != null) {
			__runtime.removeEventListener(Event.TICK, tickListener);
		}

		// Only a client sends the upgrade request; a server waits to receive
		// one. This is keyed on the role rather than on whether a listener
		// was passed, because an accepted TLS session also arrives here with
		// a listener to retire -- and would otherwise start talking like a
		// client.
		if (__isClient != false) {
			__doHandshake();
		}
	}

	private function __initSSLHandshake():Void {
		__timeout = 3000;
		__timestamp = Sys.time();

		__runtime.removeEventListener(Event.TICK, __tickConnectListener);
		__runtime.addEventListener(Event.TICK, __tickSSLHandshakeListener);
	}

	private function __onTickSSLHandshake(e:Event):Void {
		// Three outcomes, kept distinct: completed, needs more data, or
		// failed. Previously a non-`Blocked` error left the "retry" flag
		// clear and fell through to __openConnection(), treating a failed
		// handshake as a successful one.
		var complete:Bool = false;
		var failed:Bool = false;

		try {
			__socket.handshake();
			complete = true;
		} catch (e:Dynamic) {
			// Blocked only means the peer's next flight has not arrived
			// yet. Anything else is terminal. The Dynamic catch is what
			// covers the TLS layer's string form, which a typed catch here
			// used to miss — turning a mid-handshake pause into a failure.
			if (!BlockedError.isBlocked(e)) {
				failed = true;
			}
		}

		if (complete) {
			__openConnection(__tickSSLHandshakeListener);
			return;
		}

		// A terminal failure closes immediately instead of idling until the
		// deadline; a merely stalled peer closes once the deadline passes.
		if (failed || Sys.time() - __timestamp > __timeout / 1000) {
			__runtime.removeEventListener(Event.TICK, __tickSSLHandshakeListener);
			__close(1015);
		}
	}

	private function __onError(errorMessage:String):Void {
		onerror(new WebsocketEvent(WebsocketEvent.ERROR, this, errorMessage));
	}

	private function __onMessage(data:Dynamic):Void {
		onmessage(new WebsocketEvent(WebsocketEvent.MESSAGE, this, data));
	}

	public function close(?code:Int, ?reason:String):Void {
		if (__socket == null)
			return;

		if (readyState == OPEN) {
			__sendFrame(Bytes.alloc(0), WebSocketOpcode.CLOSE, true);
		}

		__close(code, reason);
	}

	private function __close(code:Int, ?reason:String):Void {
		readyState = CLOSED;

		if (__socket == null) {
			onclose(new WebsocketEvent(WebsocketEvent.CLOSE, this, null, code, reason));
			return;
		}

		if (__connected) {
			__socket.close();

			if (__heartbeatID > 0) {
				GlobalTimer.clearInterval(__heartbeatID);
			}

			__connected = false;
			__detachTickListeners();
		} else {
			__detachTickListeners();
		}

		onclose(new WebsocketEvent(WebsocketEvent.CLOSE, this, null, code, reason));

		__socket = null;
	}

	private inline function __detachTickListeners():Void {
		if (__runtime == null) {
			return;
		}

		__runtime.removeEventListener(Event.TICK, __tickProcessListener);
		__runtime.removeEventListener(Event.TICK, __tickConnectListener);
		__runtime.removeEventListener(Event.TICK, __tickSSLHandshakeListener);
	}

	private function __initHeartbeat():Void {
		__heartbeatID = GlobalTimer.setInterval(__heartbeatInterval, __heartbeatDelay);
	}

	private function __heartbeatInterval() {
		if (__hasTimeoutPotential) {
			Logger.debug('WebSocket heartbeat timed out after ${__heartbeatDelay}ms, closing session');
			__close(1006);
			return;
		}

		ping();
		__hasTimeoutPotential = true;
	}

	public function sendBytes(data:ByteArray):Void {
		__prepareMessage(data, WebSocketOpcode.BINARY);
	}

	public function sendString(data:String):Void {
		__prepareMessage(Bytes.ofString(data), WebSocketOpcode.TEXT);
	}

	private function __prepareMessage(data:ByteArray, opcode:Int):Void {
		if (readyState != OPEN) {
			throw "WebSocket is not open";
		}
		data.position = 0;

		// handles fragmentation of message into multiple frames
		if (data.length > MAX_PAYLOAD) {
			var firstFrame:Bool = true;
			while (data.position != data.length) {
				var fin:Bool;
				var fragmentOpcode:Int;
				var length:Int;

				var remaining:Int = data.length - data.position;

				if (remaining > MAX_PAYLOAD) {
					fin = false;
					length = MAX_PAYLOAD;
					fragmentOpcode = firstFrame ? opcode : WebSocketOpcode.CONTINUATION;
				} else {
					fin = true;
					length = remaining;
					fragmentOpcode = firstFrame ? opcode : WebSocketOpcode.CONTINUATION;
				}
				firstFrame = false;

				__outgoingMessageBuffer.length = length;
				__outgoingMessageBuffer.position = 0;

				data.readBytes(__outgoingMessageBuffer, 0, length);

				__sendFrame(__outgoingMessageBuffer, fragmentOpcode, fin);
			}
		} else {
			__sendFrame(data, opcode, true);
		}
	}

	private static function __generateMaskBytes():ByteArray {
		return SecureRandom.getSecureRandomBytes(4);
	}

	private inline function __sendFrame(payload:ByteArray, opcode:Int, isFinal:Bool):Void {
		if (__socket == null) {
			return;
		}

		// Write the frame header
		var fin:Int = isFinal ? WebSocketHeaderMask.FIN : 0;
		__output.clear();
		__output.writeByte(fin | opcode);
		var length:Int = payload.length;

		if (__isClient == false) {
			__writePayloadLength(length);
			__output.writeBytes(payload);
		} else {
			__writePayloadLength(length, WebSocketHeaderMask.MASK);
			var frameMask:ByteArray = __generateMaskBytes();

			// Copy in bulk, then mask in place with the same XOR the inbound
			// path uses, rather than a per-byte writeByte through the
			// ByteArray write path.
			__maskedPayload.length = length;
			__maskedPayload.position = 0;
			if (length > 0) {
				(__maskedPayload : Bytes).blit(0, payload, 0, length);
				__applyMask(__maskedPayload, length, frameMask);
			}

			// Write the masked payload
			__output.writeBytes(frameMask);
			__output.writeBytes(__maskedPayload);
		}
		// Hand the frame to the pending buffer rather than writing it
		// directly: a momentarily full socket is a normal condition, and
		// treating it as fatal here used to drop the session outright.
		__queueOutput(__output, __output.length);
		__output.clear();
	}

	private inline function __writePayloadLength(length:UInt, maskFlag:Int = 0x00):Void {
		if (length > 65535) {
			maskFlag |= 127;
			__output.writeByte(maskFlag);
			__output.writeUnsignedInt(0);
			__output.writeUnsignedInt(length);
		} else if (length > 125) {
			maskFlag |= 126;
			__output.writeByte(maskFlag);
			__output.writeShort(length);
		} else {
			maskFlag |= length;
			__output.writeByte(maskFlag);
		}
	}

	public function ping():Void {
		__sendFrame(new ByteArray(), WebSocketOpcode.PING, true);
	}

	private function __pong(?payload:ByteArray):Void {
		if (payload == null) {
			payload = new ByteArray();
		}
		__sendFrame(payload, WebSocketOpcode.PONG, true);
	}

	@:access(crossbyte._internal.websocket)
	inline function fromAcceptedSocket(socket:FlexSocket):WebSocket {
		var acceptedSocket:WebSocket = new AcceptedWebSocket();
		acceptedSocket.__initSocket(socket);

		return acceptedSocket;
	}
}

enum abstract BinaryType(String) to String from String {
	var ARRAYBUFFER = "arraybuffer";
	var BLOB = "blob";
}

enum abstract WebSocketHeaderMask(Int) from Int to Int {
	public static inline var FIN:Int = 0x80;
	public static inline var RSV1:Int = 0x40;
	public static inline var RSV2:Int = 0x20;
	public static inline var RSV3:Int = 0x10;
	public static inline var MASK:Int = 0x80;
}

enum abstract WebSocketOpcode(Int) from Int to Int {
	public static inline var CONTINUATION:Int = 0x00;
	public static inline var TEXT:Int = 0x01;
	public static inline var BINARY:Int = 0x02;
	public static inline var CLOSE:Int = 0x08;
	public static inline var PING:Int = 0x09;
	public static inline var PONG:Int = 0x0A;
}

@:private @:noCompletion class AcceptedWebSocket extends WebSocket {
	private function new() {
		__isClient = false;
		super(null, null, null);
	}
}

@:access(crossbyte._internal.websocket)
inline function fromAcceptedSocket(socket:FlexSocket):WebSocket {
	var acceptedSocket:WebSocket = new AcceptedWebSocket();
	acceptedSocket.__initSocket(socket);

	return acceptedSocket;
}
