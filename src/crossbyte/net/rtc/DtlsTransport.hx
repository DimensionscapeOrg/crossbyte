package crossbyte.net.rtc;

import crossbyte.Future;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
#if cpp
import cpp.ConstPointer;
import cpp.Pointer;
import cpp.RawPointer;
import cpp.UInt8;
import crossbyte.net.rtc._internal.ClientHelloAssembly;
import crossbyte.net.rtc._internal.NativeDtlsSession;
#end

/**
	The encrypted channel a WebRTC data channel runs inside.

	ICE finds a path; this is what makes it private. Every byte a peer connection
	carries -- and, once SCTP is here, every message on every data channel --
	travels inside a DTLS session negotiated over the same socket the
	connectivity checks used.

	```haxe
	// Given certificate:DtlsCertificate, theirFingerprint:String, isClient:Bool, socket:crossbyte.net.DatagramSocket, peerAddress:String, peerPort:Int, message:crossbyte.io.ByteArray.
	import crossbyte.core.CrossByte;
	import crossbyte.events.DatagramSocketDataEvent;
	import crossbyte.events.TickEvent;

	var transport = new DtlsTransport(certificate, theirFingerprint, isClient);
	transport.onSend = payload -> socket.send(payload, 0, payload.length, peerAddress, peerPort);

	// What the peer sends goes to `receive`, and `poll` runs the handshake's
	// retransmissions on the tick.
	socket.addEventListener(DatagramSocketDataEvent.DATA, e -> transport.receive(e.data, haxe.Timer.stamp()));
	CrossByte.current().addEventListener(TickEvent.TICK, _ -> transport.poll(haxe.Timer.stamp()));

	transport.established.then(function(_) {
		transport.send(message);
	});
	```

	## It owns no socket, like everything else here

	`onSend` out, `receive` in, `poll` for time. That is not a preference: the
	socket a peer would want is already carrying ICE checks and will later carry
	SCTP, and mbedTLS would want to own it. So the session is driven through
	memory instead, which also means two transports can be handed each other's
	datagrams with no network in between -- which is how the handshake here is
	tested.

	## Who is the client

	DTLS has one, and neither ICE role says which peer it is. The session
	description decides, with `a=setup` (RFC 5763, RFC 8842): an offer says
	`actpass`, leaving it to the answer, and the answer conventionally takes
	`active`, the client -- which is what a browser answering does. So the
	client is usually the answerer, the ICE-controlled peer, and not the
	controlling one. `PeerConnection` and `SessionDescription.answerSetupFor`
	settle it; a caller using this directly has to, and both peers must agree,
	or both wait for the other to open the handshake.

	## Verification is by fingerprint, and it is not optional

	There is no certificate authority in WebRTC. The handshake accepts whatever
	certificate the peer presents, and the check that matters happens afterwards:
	the certificate is hashed and compared against the fingerprint that arrived
	over signalling. Skipping it would leave a session encrypted against an
	attacker rather than against eavesdroppers, which is why the expected
	fingerprint is a constructor argument rather than something to remember to
	pass later -- there is no way to build one of these that does not check.

	## Native only

	mbedTLS is what hxcpp links. Node has no DTLS in core; a browser has it
	inside `RTCPeerConnection` where nothing else can reach it.
**/
class DtlsTransport {
	/** The largest datagram this will hand out or accept. **/
	public static inline var MAX_DATAGRAM:Int = 16384;

	/**
		Whether a DTLS session can be run from here.

		Native only, and reported rather than discovered from a failure.
	**/
	public static var isSupported(default, null):Bool = #if cpp true #else false #end;

	/** This peer's certificate, whose fingerprint the far side was told. **/
	public var certificate(default, null):DtlsCertificate;

	/** The fingerprint the far side signalled, which its certificate must match. **/
	public var expectedFingerprint(default, null):String;

	/** Whether this peer opens the handshake. **/
	public var isClient(default, null):Bool;

	/** Whether the handshake has completed and the fingerprint checked. **/
	public var connected(default, null):Bool = false;

	/**
		Resolves once the session is established and the peer's certificate has
		been checked against the fingerprint it signalled.

		Fails if the handshake fails, or -- just as firmly -- if it succeeds
		against a certificate that is not the one that was promised.
	**/
	public var established(default, null):Future<DtlsTransport>;

	/** Called with a datagram to put on the wire. **/
	public dynamic function onSend(payload:ByteArray):Void {}

	/** Called with each decrypted message. **/
	public dynamic function onMessage(payload:ByteArray):Void {}

	/**
		Called once when an established session is ended from the far side:
		the peer's close_notify, a fatal alert, or a record mbedTLS will not go
		on past. Not called for `close()`, which the caller already knows about.

		Without it a peer that closed its end was indistinguishable from one
		that had gone quiet: the session stayed `connected`, `send` went on
		encrypting into it, and the only thing that ever noticed was ICE
		consent, thirty seconds later and with a reason that named the wrong
		layer.
	**/
	public dynamic function onClose(reason:String):Void {}

	/** mbedtls's code for a peer that said goodbye rather than failed. **/
	@:noCompletion private static inline var PEER_CLOSE_NOTIFY:Int = -0x7880;

	@:noCompletion private static inline var FATAL_ALERT:Int = -0x7780;
	@:noCompletion private static inline var CLIENT_RECONNECT:Int = -0x6780;

	/** mbedtls's MBEDTLS_ERR_SSL_TIMEOUT: a flight resent until the schedule ran out. **/
	@:noCompletion private static inline var HANDSHAKE_TIMEOUT:Int = -0x6800;

	/** The states `NativeDtlsSession.step` reports. **/
	@:noCompletion private static inline var STATE_ESTABLISHED:Int = 1;

	@:noCompletion private static inline var STATE_CLOSED:Int = 2;

	@:noCompletion private var __handle:Int = -1;
	@:noCompletion private var __closed:Bool = false;

	/** Times the native session has been stepped, which is what an idle poll costs. For tests. **/
	@:noCompletion private var __steps:Int = 0;

	#if cpp
	/** Only a server reads a ClientHello, so only a server needs one. **/
	@:noCompletion private var __assembly:ClientHelloAssembly;
	#end

	/**
		@param certificate This peer's own, whose fingerprint the far side has
		already been given.
		@param expectedFingerprint What the far side signalled. Required: a
		session that does not check it is not authenticated at all.
		@param isClient Whether this peer opens the handshake. The two peers must
		pass opposite values, as the description's `a=setup` settles them: the
		answerer, which is the ICE-controlled peer, is the client by convention.
	**/
	public function new(certificate:DtlsCertificate, expectedFingerprint:String, isClient:Bool) {
		if (certificate == null) {
			throw new ArgumentError("A certificate is required to prove who this peer is.");
		}

		if (expectedFingerprint == null || expectedFingerprint.length == 0) {
			throw new ArgumentError("The peer's fingerprint is required. Without it the handshake would accept any certificate at all, which is an encrypted session with whoever answered rather than with the intended peer.");
		}

		this.certificate = certificate;
		this.expectedFingerprint = expectedFingerprint;
		this.isClient = isClient;
		this.established = new Future<DtlsTransport>();

		#if cpp
		if (!isClient) {
			__assembly = new ClientHelloAssembly();
		}

		__handle = NativeDtlsSession.open(!isClient, certificate.certificatePem, certificate.privateKeyPem);

		if (__handle <= 0) {
			var code = __handle;
			__handle = -1;
			@:privateAccess established.__fail("A DTLS session could not be opened: mbedTLS returned " + code + ".", null);
		}
		#else
		@:privateAccess established.__fail("DTLS runs on native targets only, where mbedTLS is linked. Check DtlsTransport.isSupported.", null);
		#end
	}

	/**
		Moves the handshake forward.

		@param now Seconds, from a clock the caller uses consistently. DTLS runs
		its own retransmission schedule off this, so a transport that is never
		polled never retransmits a lost handshake datagram -- and over UDP one
		will be lost.

		Once the session is established this does nothing, because nothing in
		it runs on a timer any more: a record is decrypted as `receive` hands it
		over and encrypted as `send` does. It used to step the native session
		every tick anyway -- three native calls per idle peer per tick, each
		finding nothing, which at ten thousand peers and twelve ticks a second
		is a third of a million calls a second doing nothing.
	**/
	public function poll(now:Float):Void {
		#if cpp
		if (connected) {
			return;
		}

		__step(now);
		#end
	}

	#if cpp
	/** One step of the native session: timers, what was fed, and what came of it. **/
	@:noCompletion private function __step(now:Float):Void {
		if (__closed || __handle <= 0) {
			return;
		}

		__steps++;

		var state = NativeDtlsSession.step(__handle, now);

		__flush();

		if (state < 0) {
			var code:Int = NativeDtlsSession.error(__handle);

			__fail(code == HANDSHAKE_TIMEOUT ? "The DTLS handshake timed out: the peer did not answer."
				: "The DTLS handshake failed: mbedTLS returned " + code + ".");
			return;
		}

		if (!connected && state == STATE_ESTABLISHED) {
			if (!__verifyPeer()) {
				return;
			}

			connected = true;
			@:privateAccess established.__resolve(this);
		}

		// Before the session's end is reported: a peer that sends a last
		// message and then closes meant both, and the message was decrypted
		// before the alert was read.
		__deliver();

		if (state == STATE_CLOSED) {
			__endedByPeer();
		}
	}
	#end

	/**
		Hands over a datagram that arrived from the peer.

		@return Whether it looked like DTLS. A record layer type between 20 and
		63 is DTLS by RFC 7983's demultiplexing rule, which is what lets STUN,
		DTLS and media share one socket -- so anything else belongs to whoever
		else is on it and is left alone.
	**/
	public function receive(payload:ByteArray, now:Float):Bool {
		#if cpp
		if (__closed || __handle <= 0 || payload == null || payload.length == 0) {
			return false;
		}

		if (!looksLikeDtls(payload)) {
			return false;
		}

		// The datagram's own storage, not a copy. A `ByteArray` is a
		// `haxe.io.Bytes` underneath, `feed` copies into the native session's
		// queue before returning, and the assembly blits what it keeps --
		// nothing holds this reference past the call, so the byte-at-a-time
		// copy that used to sit here bought nothing and cost a pass over every
		// record the connection ever received.
		var bytes:haxe.io.Bytes = payload;

		// A server's first job is to read a ClientHello, and a browser's is
		// large enough to be sent in pieces that mbedtls will not put back
		// together. A client never sees one, so it never takes this path.
		if (__assembly != null) {
			bytes = __assembly.accept(bytes);

			// Held: fragments still to come, and nothing to hand over yet. The
			// datagram was still DTLS, which is what the caller asked.
			if (bytes == null) {
				return true;
			}
		}

		NativeDtlsSession.feed(__handle, __constPtr(bytes), bytes.length);

		// Read straight away, established or not: this is the one moment an
		// established session has anything to do.
		__step(now);
		return true;
		#else
		return false;
		#end
	}

	/**
		Encrypts and queues a message.

		@throws ArgumentError if the session is not established. Sending before
		then would have to either drop the message or buffer it, and a transport
		that silently does one when the caller assumed the other is worse than
		one that says no.
	**/
	public function send(payload:ByteArray):Void {
		#if cpp
		if (!connected || __closed || __handle <= 0) {
			throw new ArgumentError("This DTLS session is not established yet. Wait on `established` before sending.");
		}

		if (payload == null || payload.length == 0) {
			return;
		}

		if (payload.length > MAX_DATAGRAM) {
			throw new ArgumentError("A DTLS record carries at most " + MAX_DATAGRAM + " bytes, and this is " + payload.length + ".");
		}

		// The caller's storage, not a copy: the native session encrypts into
		// its own buffers before returning, so nothing here outlives the call.
		NativeDtlsSession.write(__handle, __constPtr(payload), payload.length);
		__flush();
		#end
	}

	/**
		Ends the session.

		@param notifyPeer Whether to tell the peer first, with a close_notify
		handed to `onSend` before this returns. On by default, because a peer
		that is not told keeps its end open until something times out. Off for
		a path that is already known to be dead -- RFC 7675 asks a sender whose
		consent has expired to stop transmitting, and a goodbye is a
		transmission.
	**/
	public function close(notifyPeer:Bool = true):Void {
		#if cpp
		if (__closed) {
			return;
		}

		__closed = true;
		connected = false;

		if (__handle > 0) {
			if (notifyPeer) {
				NativeDtlsSession.notifyClose(__handle);
				__flush();
			}

			NativeDtlsSession.close(__handle);
			__handle = -1;
		}

		// A caller waiting on `established` when the session is closed under it
		// would otherwise wait forever: every other path that settles this one
		// runs from the handshake, which closing is what stops. Future.__fail
		// is idempotent, so a session that did complete keeps its result.
		@:privateAccess established.__cancel("The session was closed before the handshake completed.");
		#end
	}

	/**
		Whether a datagram is DTLS rather than something else on the same socket.

		RFC 7983 divides the space by first byte: below 2 is STUN, 20 to 63 is
		DTLS, 128 and above is RTP or RTCP. That rule is the only reason one
		socket can carry ICE checks and an encrypted session at once, which is
		exactly what a peer connection does.
	**/
	public static function looksLikeDtls(payload:ByteArray):Bool {
		if (payload == null || payload.length == 0) {
			return false;
		}

		var position = payload.position;
		payload.position = 0;
		var first = payload.readUnsignedByte();
		payload.position = position;

		return first >= 20 && first <= 63;
	}

	#if cpp
	@:noCompletion private function __verifyPeer():Bool {
		var peerPem = NativeDtlsSession.peerCertificate(__handle);

		if (peerPem == null) {
			__fail("The peer presented no certificate, so there is nothing to check against the fingerprint it signalled.");
			return false;
		}

		if (!DtlsCertificate.matches(peerPem, expectedFingerprint)) {
			// The handshake itself succeeded. That is precisely the case this
			// check exists for: an attacker who can answer gets an encrypted
			// session unless the certificate is tied back to what was signalled.
			__fail("The peer's certificate does not match the fingerprint it signalled, so this session is with somebody else.");
			return false;
		}

		return true;
	}

	@:noCompletion private function __flush():Void {
		while (true) {
			var size = NativeDtlsSession.pending(__handle);

			if (size <= 0) {
				return;
			}

			// Straight into the ByteArray the handler receives -- its backing
			// store is a `haxe.io.Bytes` the native session can fill, so the
			// second full copy this used to make of every outbound record is
			// gone.
			var out = new ByteArray(size);
			var written = NativeDtlsSession.take(__handle, __ptr(out), size);

			if (written <= 0) {
				return;
			}

			if (written < size) {
				out.length = written;
			}

			out.position = 0;
			onSend(out);
		}
	}

	@:noCompletion private function __deliver():Void {
		while (true) {
			var size = NativeDtlsSession.available(__handle);

			if (size <= 0) {
				return;
			}

			var out = new ByteArray(size);
			var read = NativeDtlsSession.read(__handle, __ptr(out), size);

			if (read <= 0) {
				return;
			}

			if (read < size) {
				out.length = read;
			}

			out.position = 0;
			onMessage(out);
		}
	}

	// The same shape Blake3 uses to hand hxcpp a buffer: a pointer to the first
	// element of the underlying storage, which is what the extern signatures
	// take. Never called with an empty buffer -- every caller checks first,
	// because element zero of nothing does not exist.
	@:noCompletion private static inline function __ptr(bytes:haxe.io.Bytes):RawPointer<UInt8> {
		return cast Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion private static inline function __constPtr(bytes:haxe.io.Bytes):ConstPointer<UInt8> {
		return Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion private function __fail(reason:String):Void {
		if (__closed) {
			return;
		}

		// Before close(), which settles `established` too but only knows that
		// the session is closing. Future.__fail is idempotent, so whichever
		// runs first wins -- and this one knows what actually went wrong. Put
		// the other way round, a refused certificate reported "closed before
		// the handshake completed" and the reason was lost.
		if (!connected) {
			@:privateAccess established.__fail(reason, null);
		}

		close();
	}

	/**
		The peer ended the session, or the session ended under it.

		Nothing is sent back: mbedtls has marked the context finished, and a
		close_notify in answer to one is a courtesy nobody is left to receive.
	**/
	@:noCompletion private function __endedByPeer():Void {
		if (__closed) {
			return;
		}

		var code:Int = NativeDtlsSession.error(__handle);
		var reason:String = "The DTLS session failed: mbedTLS returned " + code + ".";

		if (code == PEER_CLOSE_NOTIFY) {
			reason = "The peer closed the DTLS session.";
		} else if (code == FATAL_ALERT) {
			reason = "The peer ended the DTLS session with a fatal alert.";
		} else if (code == CLIENT_RECONNECT) {
			reason = "The peer began a new DTLS session from the same address, which ends this one.";
		}

		if (!connected) {
			__fail(reason);
			return;
		}

		close(false);
		onClose(reason);
	}
	#end
}
