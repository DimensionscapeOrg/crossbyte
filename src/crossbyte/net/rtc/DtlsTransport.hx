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
	var transport = new DtlsTransport(certificate, theirFingerprint, controlling);
	transport.onSend = (payload) -> server.sendTo(payload, peer.address, peer.port);

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

	DTLS has one, ICE does not. The controlling agent takes the client role by
	convention, which is what a browser does, and both peers must agree or both
	will wait for the other to open the handshake.

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

	@:noCompletion private var __handle:Int = -1;
	@:noCompletion private var __closed:Bool = false;

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
		pass opposite values; by convention the controlling ICE agent is the
		client.
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
		Moves the handshake forward and delivers anything that has arrived.

		@param now Seconds, from a clock the caller uses consistently. DTLS runs
		its own retransmission schedule off this, so a transport that is never
		polled never retransmits a lost handshake datagram -- and over UDP one
		will be lost.
	**/
	public function poll(now:Float):Void {
		#if cpp
		if (__closed || __handle <= 0) {
			return;
		}

		var state = NativeDtlsSession.step(__handle, now);

		__flush();

		if (state < 0) {
			__fail("The DTLS handshake failed: mbedTLS returned " + NativeDtlsSession.error(__handle) + ".");
			return;
		}

		if (!connected && state == 1) {
			if (!__verifyPeer()) {
				return;
			}

			connected = true;
			@:privateAccess established.__resolve(this);
		}

		__deliver();
		#end
	}

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

		var bytes = haxe.io.Bytes.alloc(payload.length);
		payload.position = 0;

		for (i in 0...payload.length) {
			bytes.set(i, payload.readUnsignedByte());
		}

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
		poll(now);
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

		var bytes = haxe.io.Bytes.alloc(payload.length);
		payload.position = 0;

		for (i in 0...payload.length) {
			bytes.set(i, payload.readUnsignedByte());
		}

		NativeDtlsSession.write(__handle, __constPtr(bytes), bytes.length);
		__flush();
		#end
	}

	public function close():Void {
		#if cpp
		if (__closed) {
			return;
		}

		__closed = true;
		connected = false;

		if (__handle > 0) {
			NativeDtlsSession.close(__handle);
			__handle = -1;
		}
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

			var bytes = haxe.io.Bytes.alloc(size);
			var written = NativeDtlsSession.take(__handle, __ptr(bytes), size);

			if (written <= 0) {
				return;
			}

			var out = new ByteArray();
			out.writeBytes(ByteArray.fromBytes(bytes), 0, written);
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

			var bytes = haxe.io.Bytes.alloc(size);
			var read = NativeDtlsSession.read(__handle, __ptr(bytes), size);

			if (read <= 0) {
				return;
			}

			var out = new ByteArray();
			out.writeBytes(ByteArray.fromBytes(bytes), 0, read);
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

		close();

		if (!connected) {
			@:privateAccess established.__fail(reason, null);
		}
	}
	#end
}
