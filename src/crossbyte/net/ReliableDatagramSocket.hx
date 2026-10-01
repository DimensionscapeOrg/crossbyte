package crossbyte.net;

// Not built for the browser: it is a reliability layer over UDP, which the browser does not have.
#if !(js && !nodejs)

import crossbyte.Seq32;
import crossbyte.Timer as CBTimer;
import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.io.IDataInput;
import crossbyte.io.IDataOutput;
import crossbyte.net._internal.reliable.OutstandingFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.ds.IntMap;
import haxe.ds.Vector;
#if !(js && !nodejs)
#if !nodejs
import sys.net.Host;
#end
import crossbyte._internal.net.IPv6;
#end

@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.DatagramSocket)
@:access(crossbyte.core.CrossByte)
/**
	The `ReliableDatagramSocket` class provides a session-oriented reliable transport
	on top of UDP.
	It adds handshake, retransmission, acknowledgment, ordered delivery, and optional
	stream-style buffering on top of `DatagramSocket`.
	Use `mode = DATAGRAM` to preserve reliable payload boundaries and receive
	`DatagramSocketDataEvent.DATA` events. Use `mode = STREAM` to expose the same
	reliable ordered transport through the `IDataInput` and `IDataOutput` APIs and
	receive `ProgressEvent.SOCKET_DATA` notifications instead.
	Socket mode must be selected before connecting or before a server accepts the session.

	What a session sends -- messages, acknowledgements, retransmissions -- is
	gathered and sent together when the runtime's loop finishes its pass,
	several frames to a datagram where the peer takes them, so a burst of
	small messages costs a few system calls rather than one each. `flush()`
	sends what is gathered at once.

	A frame lost on the way is found from what arrives after it. The
	receiver's acknowledgement names the frames it holds past a gap, and a
	frame sent before one that arrived is sent again once it has had that
	one's round trip, and a little more, to arrive in. When nothing comes back
	at all, the last frame goes again as a probe, and only then does a frame
	wait out its retransmission timeout.

	A session ends in one of three ways, and dispatches `close` once when it
	has. `close()` is graceful: everything sent before it arrives, in order,
	and then the peer's `close`; this side's follows when the peer has
	acknowledged it all, or when the peer has gone `closeTimeout` seconds
	without acknowledging anything. `abort()` ends it at once on both sides,
	dropping whatever has not arrived. And a failure ends it with an
	`ioError` saying why, and then `close`: a connect that times out or
	whose name does not resolve, a send the system refuses, or a peer silent
	for `idleTimeout`.
	@event connect Dispatched when the reliable handshake completes.
	@event close Dispatched once, when the session ends: closed by the peer,
	       by this side's `close()` once it has finished, by `abort()`, or by
	       a failure, after the `ioError` that says what it was. A connect
	       that fails dispatches `ioError` and then `close`.
	@event ioError Dispatched when a handshake or transport error occurs, and
	       always followed by `close`.
	@event data Dispatched in `DATAGRAM` mode when a complete reliable payload is delivered.
	@event socketData Dispatched in `STREAM` mode when additional ordered bytes are available.
**/
class ReliableDatagramSocket extends EventDispatcher implements IDataInput implements IDataOutput implements crossbyte.core._internal.PassFlush #if !nodejs implements crossbyte._internal.net.DatagramSender #end {
	/**
		A slot for whatever the application wants this connection to carry.

		Untouched by the framework, and it goes when the connection does.
		Without one, an application holding per-connection state -- a session,
		a player, a room membership -- keeps a `Map` beside the connection and
		has to remember to remove the entry on close. Forgetting is not
		noisy: the connection is gone, the traffic stops, and the entry stays
		until the process does.

		Typed as `Any` rather than `Dynamic` so reading it back needs an
		explicit cast, and a wrong one is a compile error rather than a field
		access on whatever happened to be there.

		```haxe
		connection.userData = new Session(player);
		var session:Session = cast connection.userData;
		```
	**/
	public var userData:Any = null;

	/**
		Indicates whether reliable UDP sessions are supported by the current target.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/**
		Indicates whether the underlying UDP transport is currently bound.
	**/
	public var bound(get, never):Bool;

	/**
		The number of readable bytes currently buffered for stream mode.
		Returns `0` while in datagram mode.
	**/
	public var bytesAvailable(get, never):UInt;

	/**
		The number of bytes queued in the local stream output buffer waiting for `flush()`.
		Returns `0` while in datagram mode.
	**/
	public var bytesPending(get, never):Int;

	/**
		Indicates whether the reliable session handshake has completed, and
		the session has not been closed since. False from the moment `close()`
		is called, while what it waits on is still on its way.
	**/
	public var connected(get, never):Bool;

	/**
		The byte order of the messages this socket dispatches, and of its
		stream-mode reads and writes.

		`ByteArray.defaultEndian` when the socket is made -- little-endian
		unless the application changed it, as a ByteArray it makes is -- so a
		number written into a new ByteArray reads back as itself from the
		message that carried it. Set `Endian.BIG_ENDIAN` for a protocol in
		network byte order. Messages came big-endian whatever the rest of the
		application did.
	**/
	public var endian(get, set):Endian;

	/**
		The local IP address of the underlying UDP transport.
	**/
	public var localAddress(get, never):String;

	/**
		The local UDP port of the underlying transport.
	**/
	public var localPort(get, never):Int;

	/**
		Controls whether the socket exposes reliable payloads as discrete datagrams or
		as a buffered ordered byte stream. This property must be set before the socket
		connects or before it is accepted by a server.
	**/
	public var mode(get, set):ReliableDatagramSocketMode;

	/**
		Controls how `readObject()` and `writeObject()` serialize stream-mode objects.
	**/
	public var objectEncoding:ObjectEncoding;

	/**
		The remote IP address for this reliable session, or an empty string before a
		connection attempt begins.
	**/
	public var remoteAddress(get, never):String;

	/**
		The remote UDP port for this reliable session, or `0` before a connection attempt begins.
	**/
	public var remotePort(get, never):Int;

	/**
		The connection timeout, in milliseconds, used while establishing a
		reliable session: 20 seconds unless changed. Zero means no deadline:
		the attempt goes on, a CONNECT every three seconds, until the peer
		answers or `close()` is called. Set it before `connect()`; an attempt
		already under way keeps the deadline it began with.

		@throws RangeError If set below zero.
	**/
	public var timeout(get, set):Int;

	/**
		How many bytes may wait for the window before `outputOverflowPolicy`
		decides what happens. Zero, the default, means no limit.

		What is waiting is visible as `bufferedAmount`; an application that
		watches that never reaches this.
	**/
	public var maxOutputBufferSize:Int = 0;

	/** What to do when the queue exceeds `maxOutputBufferSize`. **/
	public var outputOverflowPolicy:OutputOverflowPolicy = CLOSE;

	/**
		Bytes written and not yet put on the wire.

		Zero while the path keeps up. It grows when the congestion window has
		no room left, which is how a sender learns the peer or the path
		between cannot take data as fast as it is being produced.
	**/
	public var bufferedAmount(get, never):Int;

	@:noCompletion private function get_bufferedAmount():Int {
		return __queuedBytes;
	}

	/**
		The largest reliable message the peer may send this socket, in bytes.
		Zero means no limit.

		A reliable message larger than one frame travels as several, and is
		held here until its last one arrives -- so what a peer can make this
		side hold is whatever it declares a message to be. Past this the
		session is ended at once, as `abort()` ends one, with an `ioError`
		saying why, rather than the fragments being kept for a message with no
		end; the peer dispatches `close`.
	**/
	public var maxMessageSize:Int = DEFAULT_MAX_MESSAGE_SIZE;

	/** `maxMessageSize` unless changed: eight megabytes, as `FrameCodec` takes. **/
	public static inline var DEFAULT_MAX_MESSAGE_SIZE:Int = 8 * 1024 * 1024;

	/**
		What the peer sent with its CONNECT, or `null` if no CONNECT has come
		from it.

		Every session a server accepts has one -- empty when the peer's
		`connect` passed nothing -- and it is the payload
		`ReliableDatagramServerSocket.admit` was shown, from its start, so the
		handler that takes the session can tell who it is by the same token
		the hook let it in on. A dialled session has one only when its peer
		dialled too, as two peers opening a path through NAT both do; a client
		of an ordinary server never receives a CONNECT, and reads `null`.
	**/
	public var connectPayload(default, null):ByteArray = null;

	/**
		The round trip to the peer in seconds, smoothed, as the session
		measures it to time its own retransmissions: RFC 6298's SRTT. Taken
		from the acknowledgement of each reliable frame sent only once -- one
		sent again cannot say which copy was answered -- so it is -1 until the
		first reliable message has been acknowledged, and it follows only as
		often as reliable messages are sent. It includes however long the peer
		takes to acknowledge, which is usually the rest of its tick.

		For a round trip between two applications, rather than between two
		transports, measure one with messages of their own; `PeerClock` does
		that and also finds where the peer's clock stands.
	**/
	public var roundTripTime(get, never):Float;

	/**
		How much the round trip varies, in seconds: RFC 6298's RTTVAR, the
		smoothed difference between one measurement and the average. Zero
		until the first.
	**/
	public var roundTripVariation(get, never):Float;

	/**
		How long a reliable frame is waited for before it is sent again, in
		seconds: `roundTripTime` plus four times `roundTripVariation`, held
		between 0.2 and 10. One second until a round trip is measured, and
		doubled whenever a frame has to be sent again.
	**/
	public var retransmitTimeout(get, never):Float;

	/**
		The fastest round trip measured, in seconds: the path with nothing
		queued on it, as near as the session has seen. -1 until the first
		measurement.
	**/
	public var minRoundTripTime(get, never):Float;

	/**
		How many reliable frames the peer is known to have received, counted
		once each, as soon as it is known: when acknowledged, or when reported
		held past a gap that has not yet filled. A frame of a message counts,
		not a message, and frames sent again count once. From zero when the
		socket is made, and again after it closes.

		Unlike what the cumulative acknowledgement has passed, this does not
		stall while a lost frame is sent again and then jump when it arrives,
		so the difference between two readings is what the peer received in
		between: the rate a `CongestionControl` measures a path by.
	**/
	public var framesDelivered(get, never):Float;

	/**
		What decides how many frames this session may have in the network at
		once. `CongestionControl`, which is TCP's Reno, unless another is set;
		`LossTolerantCongestionControl` suits a path that loses frames to radio
		rather than to congestion. A session a server accepts or dials takes
		the server's `ReliableDatagramServerSocket.congestionControlFor`.

		Set it before connecting, or at any point after: the new policy
		starts from its own window. One instance serves one session.

		@throws ArgumentError if set to `null`.
	**/
	public var congestionControl(get, set):CongestionControl;

	@:noCompletion private inline function get_roundTripTime():Float {
		return __smoothedRtt;
	}

	@:noCompletion private inline function get_minRoundTripTime():Float {
		return __minRtt;
	}

	@:noCompletion private inline function get_framesDelivered():Float {
		return __framesDelivered;
	}

	@:noCompletion private inline function get_congestionControl():CongestionControl {
		return __congestion;
	}

	@:noCompletion private function set_congestionControl(value:CongestionControl):CongestionControl {
		if (value == null) {
			throw new ArgumentError("A reliable datagram session needs a congestion control.");
		}
		return __congestion = value;
	}

	@:noCompletion private inline function get_roundTripVariation():Float {
		return __rttVariation;
	}

	@:noCompletion private inline function get_retransmitTimeout():Float {
		return __rto;
	}

	/**
		What a session asks the operating system for, in bytes, to hold
		datagrams in each direction when it makes its socket: its largest
		window -- 500 frames of up to 1211 bytes -- rounded up to a megabyte.

		A window is sent in one pass of the loop, so it lands on the receiving
		socket all at once, and what the socket cannot hold is dropped, each
		loss then waiting out a retransmission timeout. The systems' defaults
		hold far less: 64 KB on Windows, where over loopback 1000-byte
		messages ran at 7,700 a second on the default and at 73,000 with this.

		Only ever raised, never lowered, and only asked for: Linux, for one,
		grants no more than `net.core.rmem_max`, which the session survives as
		it survives any loss, only more slowly.
	**/
	public static inline var WINDOW_BUFFER_SIZE:Int = 1 << 20;

	/**
		The operating system's receive buffer, in bytes, for the socket this
		session reads from; see `DatagramSocket.receiveBufferSize`. At least
		`WINDOW_BUFFER_SIZE` where the system grants it. A session a server
		accepted or dialled shares that server's socket, so this is the
		server's.
	**/
	public var receiveBufferSize(get, set):Int;

	/**
		The operating system's send buffer, in bytes, for this session's socket;
		see `DatagramSocket.sendBufferSize`. Shared with the server, as
		`receiveBufferSize` is, for a session a server accepted or dialled.
	**/
	public var sendBufferSize(get, set):Int;

	@:noCompletion private inline function get_receiveBufferSize():Int {
		return __transport != null ? __transport.receiveBufferSize : 0;
	}

	@:noCompletion private function set_receiveBufferSize(value:Int):Int {
		if (__transport == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		return __transport.receiveBufferSize = value;
	}

	@:noCompletion private inline function get_sendBufferSize():Int {
		return __transport != null ? __transport.sendBufferSize : 0;
	}

	@:noCompletion private function set_sendBufferSize(value:Int):Int {
		if (__transport == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		return __transport.sendBufferSize = value;
	}

	/**
		Asks for `WINDOW_BUFFER_SIZE` in each direction where the socket has
		less. Best effort: a target that cannot size buffers, or a system that
		refuses, leaves the socket as it was.
	**/
	@:noCompletion private static function __reserveWindow(socket:DatagramSocket):Void {
		if (!DatagramSocket.bufferSizeSupported) {
			return;
		}
		try {
			if (socket.receiveBufferSize < WINDOW_BUFFER_SIZE) {
				socket.receiveBufferSize = WINDOW_BUFFER_SIZE;
			}
			if (socket.sendBufferSize < WINDOW_BUFFER_SIZE) {
				socket.sendBufferSize = WINDOW_BUFFER_SIZE;
			}
		} catch (_:Dynamic) {}
	}

	@:noCompletion private static inline var CONNECTION_ATTEMPT_INTERVAL:Float = 3.0;
	@:noCompletion private static inline var DELIVERY_WINDOW:Int = 500;

	/** `keepAliveInterval` unless changed, in seconds. **/
	public static inline var DEFAULT_KEEP_ALIVE_INTERVAL:Float = 15.0;

	/** `idleTimeout` unless changed, in seconds. **/
	public static inline var DEFAULT_IDLE_TIMEOUT:Float = 60.0;

	/**
		How long, in seconds, a connected session may go without sending
		anything before it sends a keepalive. Zero sends none.

		A keepalive is what keeps a quiet session up: without one a session
		with nothing to say heard nothing either, and was closed as dead
		however healthy both ends were. It also keeps a NAT's mapping for the
		session open, which most drop after thirty seconds or so of silence --
		hence fifteen by default. It is the session's opening HANDSHAKE sent
		again, which a peer on every version answers with an acknowledgement
		and takes nothing else from.

		Set it before connecting or at any point after; the next interval is
		measured from the change.
	**/
	public var keepAliveInterval(get, set):Float;

	/**
		How long, in seconds, a connected session hears nothing from its peer
		before it gives the peer up, dispatching `ioError` and then `close`.
		Zero never gives up.

		Checked every `keepAliveInterval` seconds (or every quarter of this,
		with keepalives off), so a session is closed up to one interval after
		the timeout has passed.
	**/
	public var idleTimeout(get, set):Float;

	/** `closeTimeout` unless changed, in seconds. **/
	public static inline var DEFAULT_CLOSE_TIMEOUT:Float = 10.0;

	/**
		How long, in seconds, `close()` waits on a peer that has stopped
		acknowledging what this side sent. Zero sets no deadline, and a peer
		that stops answering is then given up only at `idleTimeout`.

		Measured from the last frame the peer was known to receive, not from
		the call, so a long queue draining steadily is not cut off. A peer
		that acknowledges nothing for this long is given up: an `ioError`
		says what was sent before the close may not have arrived, unless all
		that went unacknowledged was the close itself; the peer is sent a FIN
		that ends its session at once, as `abort()` sends; and `close`
		follows.

		Read while a close waits, so changing it then changes that close.
	**/
	public var closeTimeout(get, set):Float;

	@:noCompletion private var __keepAliveInterval:Float = DEFAULT_KEEP_ALIVE_INTERVAL;
	@:noCompletion private var __idleTimeout:Float = DEFAULT_IDLE_TIMEOUT;
	@:noCompletion private var __closeTimeout:Float = DEFAULT_CLOSE_TIMEOUT;

	// A graceful close under way: close() has been called, and the session
	// is waiting for the peer to acknowledge what it sent and the FIN after
	// it. When the close began, and the timer that checks on it.
	@:noCompletion private var __closing:Bool = false;
	@:noCompletion private var __closeStartedAt:Float = 0;
	@:noCompletion private var __closeTimerHandle:Int = -1;

	// Whether a datagram has gone out since the last keepalive check, and for
	// how long in a row the peer has been silent at those checks.
	@:noCompletion private var __sentSinceKeepAlive:Bool = false;
	@:noCompletion private var __silentFor:Float = 0;

	// This side's connection id, carried in the sequence field of every
	// CONNECT it sends -- a field no receiver read before -- so that a server
	// holding a session for this address and port can tell this attempt
	// from an earlier one: the same peer, restarted. Never 0, which is what a
	// CONNECT from an older build carries and means "no id".
	@:noCompletion private var __connectionId:Int = 0;

	// The peer's, from the CONNECT it sent, or 0 when it sent none. Echoed in
	// every HANDSHAKE this side sends, so the peer can tell an answer to its
	// own CONNECT from one to an attempt that came before it.
	@:noCompletion private var __peerConnectionId:Int = 0;

	// A server's check on a CONNECT carrying a new id for a session it holds:
	// when it asked the old peer whether it is still there (-1 while not
	// asking), and whether anything has come from it since.
	@:noCompletion private var __challengedAt:Float = -1;
	@:noCompletion private var __heardSinceChallenge:Bool = false;

	// A HANDSHAKE's payload when it echoes an id: four bytes, big-endian.
	@:noCompletion private var __echoScratch:ByteArray;

	/**
		How often the socket looks for frames whose time is up.

		One timer for the session rather than one per frame. The old shape
		armed a repeating `CBTimer` for every packet put on the wire, so a
		sender with the window full held hundreds of live timers, and a server
		held that many times its connection count. This is the granularity of
		the retransmission clock, not the wait itself -- what a frame waits is
		its own deadline, from `__rto`.
	**/
	@:noCompletion private static inline var RETRANSMIT_TICK:Float = 0.05;

	/** The floor on a retransmission timeout, as RFC 6298 puts it. **/
	@:noCompletion private static inline var MIN_RTO:Float = 0.2;

	/** And the ceiling, so a dead path is given up on rather than waited for. **/
	@:noCompletion private static inline var MAX_RTO:Float = 10.0;

	/** What the timeout is before a single round trip has been measured. **/
	@:noCompletion private static inline var INITIAL_RTO:Float = 1.0;

	#if (hl || neko || eval)
	/**
		How far `__clock` moves when the clock under it has not: a microsecond,
		which is several of the smallest steps a double can take at a time of
		day in seconds.
	**/
	@:noCompletion private static inline var CLOCK_STEP:Float = 0.000001;
	#end

	@:noCompletion private var __alive:Bool = false;
	@:noCompletion private var __closed:Bool = false;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __connectionAttemptHandle:Int = -1;

	// The sequence this side's first frame carries, which every HANDSHAKE it
	// sends names. Not `__outSequence`: that moves once frames go out, and a
	// HANDSHAKE sent again later must still say where they began.
	@:noCompletion private var __firstSequence:Seq32 = 0;

	// Whether the peer has shown it took this side's HANDSHAKE, by sending
	// anything a connected session sends.
	@:noCompletion private var __peerConfirmed:Bool = false;

	// Set on a session not yet connected that heard a frame only a connected
	// peer sends: it owes that peer its HANDSHAKE again, once a pass.
	@:noCompletion private var __handshakeOwed:Bool = false;
	// What every CONNECT this side sends carries: a copy, taken when connect
	// was called, or null for nothing.
	@:noCompletion private var __connectOut:ByteArray = null;

	// The bundle being gathered, in `__scratch`: two bytes kept at the front
	// for the bundle's magic, then each frame after two bytes of its length,
	// written in place. `__pendingLength` is where the next entry goes.
	@:noCompletion private var __pendingLength:Int = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
	@:noCompletion private var __pendingCount:Int = 0;

	// Asked to be flushed at the end of this pass, and not yet flushed.
	@:noCompletion private var __flushQueued:Bool = false;

	// Whether the peer's CONNECT or HANDSHAKE said it takes bundles.
	@:noCompletion private var __peerTakesBundles:Bool = false;

	// A packet has arrived since the last acknowledgement went out, and the
	// newest acknowledgement a frame in the bundle already carries. One
	// cumulative ACK a pass says everything the separate ones did.
	@:noCompletion private var __ackOwed:Bool = false;
	@:noCompletion private var __bundleHasAck:Bool = false;
	@:noCompletion private var __bundleAck:Int = 0;
	@:noCompletion private var __connectionTimeoutHandle:Int = -1;
	// Whether connect() is looking a name up, and a count of its attempts so
	// only the latest one's answer is acted on.
	@:noCompletion private var __lookingUp:Bool = false;
	@:noCompletion private var __lookups:Int = 0;
	@:noCompletion private var __endian:Endian = ByteArray.defaultEndian;
	// Out-of-order frames, kept whole: a fragment's `more` flag is as much a
	// part of it as its bytes.
	@:noCompletion private var __inFrameCache:IntMap<ReliableDatagramFrame>;

	// The fragments of a reliable message still arriving, and their total.
	// Joined once when the last arrives, rather than appended to a buffer
	// that grows -- and copies -- as it goes.
	@:noCompletion private var __fragments:Array<ByteArray> = [];
	@:noCompletion private var __fragmentBytes:Int = 0;

	// The newest counter delivered on each sequenced channel, -1 for none,
	// and the next to send. Made on first use: most sessions never sequence
	// anything, and 256 entries each is not worth carrying for them.
	@:noCompletion private var __sequencedIn:Vector<Int>;
	@:noCompletion private var __sequencedOut:Vector<Int>;

	// Every frame this socket sends is written here and sent from here. A
	// send has finished with its bytes before it returns, so one buffer
	// serves every frame, where encoding each into one of its own was an
	// allocation per packet and per acknowledgement.
	@:noCompletion private var __scratch:ByteArray;
	@:noCompletion private var __inFrameCacheSize:Int = 0;
	@:noCompletion private var __inSequence:Seq32 = 0;
	@:noCompletion private var __incoming:Bool = false;
	@:noCompletion private var __input:ByteArray;
	@:noCompletion private var __keepAliveHandle:Int = -1;
	@:noCompletion private var __mode:ReliableDatagramSocketMode = DATAGRAM;
	@:noCompletion private var __outFrameCache:IntMap<OutstandingFrame>;
	@:noCompletion private var __retransmitHandle:Int = -1;

	/**
		What decides how many frames may be in flight at once; see
		`congestionControl`.

		The send window was a constant 500 that took no notice of whether any
		of it was arriving. A reliable transport that retransmits on a fixed
		schedule into a path that is already dropping packets makes the drops
		worse, and with a window that never yields it keeps doing so -- which
		is how one slow client costs a server the bandwidth of many.
	**/
	@:noCompletion private var __congestion:CongestionControl = new CongestionControl();

	// See `framesDelivered`. A Float, so a long session does not wrap it.
	@:noCompletion private var __framesDelivered:Float = 0;

	/** Smoothed round trip time, and its variation. -1 until one is measured. **/
	@:noCompletion private var __smoothedRtt:Float = -1;

	@:noCompletion private var __rttVariation:Float = 0;

	/** What a frame waits before it is sent again. **/
	@:noCompletion private var __rto:Float = INITIAL_RTO;

	/**
		How many duplicate acknowledgements from a peer that sends no
		selective ones mark the frame it is waiting for as lost; and how many
		frames held past a gap, on a path that has never reordered one, let
		loss be judged with no allowance for stragglers. RFC 6675's count and
		RFC 8985's use of it.
	**/
	@:noCompletion private static inline var DUP_THRESHOLD:Int = 3;

	// Loss recovery: whether this session is in it, and the sequence that
	// ends it -- the next to be sent when it began -- so that every loss from
	// one burst halves the window once, not once each.
	@:noCompletion private var __inRecovery:Bool = false;
	@:noCompletion private var __recoveryPoint:Seq32 = 0;

	// Acknowledgements in a row that moved nothing, from a peer that sends no
	// selective ones.
	@:noCompletion private var __dupAcks:Int = 0;

	// Frames sent again because the peer's acknowledgements showed them lost,
	// as tail probes, and because their timeout ran out; the last is the
	// slow way.
	@:noCompletion private var __fastResends:Int = 0;
	@:noCompletion private var __probes:Int = 0;
	@:noCompletion private var __timeoutResends:Int = 0;

	// Of the frames known delivered, the one sent last: when, which, and the
	// round trip it took. `__rackSentAt` is -1 until one is.
	@:noCompletion private var __rackSentAt:Float = -1;
	@:noCompletion private var __rackSequence:Seq32 = 0;
	@:noCompletion private var __rackRtt:Float = 0;

	// The fastest round trip measured, -1 until one is.
	@:noCompletion private var __minRtt:Float = -1;

	#if (hl || neko || eval)
	// The last reading `__clock` gave, which the next must pass.
	@:noCompletion private var __lastClock:Float = -1;
	#end

	// The highest sequence known delivered, and whether a frame has ever
	// arrived below it without having been sent again.
	@:noCompletion private var __highestDelivered:Seq32 = 0;
	@:noCompletion private var __reorderingSeen:Bool = false;

	// Whether the peer sends selective acknowledgements.
	@:noCompletion private var __peerSacks:Bool = false;

	// When a frame last went out, and when the peer last showed it had one
	// it had not before; whether the tail has been probed since.
	@:noCompletion private var __lastTransmitAt:Float = 0;
	@:noCompletion private var __lastDeliveryAt:Float = 0;
	@:noCompletion private var __probed:Bool = false;

	/**
		The least a tail probe waits, however short the round trip: enough
		that a peer whose loop is busy for a moment is not probed for it.
	**/
	@:noCompletion private static inline var MIN_PROBE_TIMEOUT:Float = 0.01;

	// Where a selective acknowledgement is written before it is sent.
	@:noCompletion private var __sackScratch:ByteArray;

	// Outstanding frames the peer has said it holds. They have left the
	// network, so they no longer count against the congestion window.
	@:noCompletion private var __sackedCount:Int = 0;

	/** Bytes sitting in `__outgoingQueue` waiting for the window to open. **/
	@:noCompletion private var __queuedBytes:Int = 0;

	/** How far `__outgoingQueue` has been drained; see `__drainQueue`. **/
	@:noCompletion private var __queueAt:Int = 0;
	@:noCompletion private var __outSequence:Seq32 = 0;
	// Frames made and not yet sent. They are the frames the retransmission
	// cache will hold, made once, carrying the `more` flag with them.
	@:noCompletion private var __outgoingQueue:Array<OutstandingFrame>;
	@:noCompletion private var __output:ByteArray;
	@:noCompletion private var __ownsTransport:Bool = true;
	@:noCompletion private var __remoteAddress:String = "";
	@:noCompletion private var __remotePort:Int = 0;
	@:noCompletion private var __remoteResponsePort:Int = 0;
	@:noCompletion private var __server:ReliableDatagramServerSocket;

	/**
		The relay this session reaches its peer through, or null for a peer
		reached directly: set by `ReliableDatagramServerSocket` for a session
		accepted through its relay or dialled with `connectRelayed`, and never
		changed. Every datagram then goes to the relay to forward.
	**/
	@:noCompletion private var __relay:TurnClient = null;

	@:noCompletion private var __timeout:Int = 20000;
	@:noCompletion private var __transport:DatagramSocket;
	#if !nodejs
	// The peer's address as the transport sends to it, kept: the transport
	// keeps only the last one it was asked for, so a server sending a
	// datagram to each of its sessions in turn built a Host and an Address
	// for every datagram. Refreshed when the peer or the transport changes.
	@:noCompletion private var __target:sys.net.Address = null;
	@:noCompletion private var __targetAddress:String = null;
	@:noCompletion private var __targetPort:Int = 0;
	@:noCompletion private var __targetTransport:DatagramSocket = null;
	#end
	@:noCompletion private var __transportListenerReady:Bool = false;
	@:noCompletion private var __windowBase:Seq32 = 0;

	/**
		Creates a new `ReliableDatagramSocket`.
		If `host` and `port` are supplied, the socket attempts to open a reliable
		session immediately.
		@param host The remote host to connect to. Pass `null` to create an unconnected socket.
		@param port The remote port to connect to. Pass `0` to create an unconnected socket.
	**/
	public function new(host:String = null, port:Int = 0) {
		super();

		__inFrameCache = new IntMap();
		__inFrameCacheSize = 0;
		__outFrameCache = new IntMap();
		__outgoingQueue = [];
		__scratch = new ByteArray();
		// A single frame of the largest size, with room before it for the
		// bundle's magic and its length, which it is sent without.
		__scratch.length = ReliableDatagramProtocol.MAX_FRAME_SIZE + ReliableDatagramProtocol.BUNDLE_HEADER_SIZE
			+ ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE;
		objectEncoding = ObjectEncoding.DEFAULT;
		__input = __createBuffer();
		__output = __createBuffer();
		__transport = new DatagramSocket();
		__reserveWindow(__transport);
		__prepareTransportListener();
		__resetSequences();

		if (host != null || port != 0) {
			connect(host, port);
		}
	}

	/**
		Binds the underlying UDP transport before connecting.
		This is only available on client-created sockets; sockets accepted by a
		`ReliableDatagramServerSocket` inherit the server transport.
		@param localPort The local UDP port to bind to. Use `0` to allow the operating system to choose.
		@param localAddress The local address to bind to. Use `"0.0.0.0"` to bind on all IPv4 interfaces.
		@throws IllegalOperationError If this socket was accepted by a server.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (!__ownsTransport) {
			throw new IllegalOperationError("Cannot bind a socket accepted by a server.");
		}

		__transport.bind(localPort, localAddress);
	}

	/**
		Closes the reliable session gracefully: everything sent before this
		call reaches the peer, in order, before the peer's `close`.

		What is waiting goes first -- frames gathered this pass, frames the
		congestion window is holding back (`bufferedAmount`), and in `STREAM`
		mode bytes written and not yet flushed -- and whatever the peer has
		not acknowledged is sent again as it needs to be. A FIN follows, in
		the same sequence, so the peer acts on it only once everything before
		it has arrived, whatever the network lost or reordered on the way.
		This side's `close` is dispatched when the peer has acknowledged all
		of it, or when the peer has gone `closeTimeout` seconds without
		acknowledging anything -- after an `ioError`, if what went
		unacknowledged was more than the FIN itself.

		From the call on, the session is closed to the application:
		`connected` reads false, sends, writes and reads throw, and what the
		peer sends meanwhile is acknowledged and dropped. Calling it again
		does nothing, and `abort()` ends a close that is waiting. A session
		not yet connected has nothing to deliver, and is ended at once, as
		`abort()` ends one.

		A peer from before 1.0 takes the FIN the moment it arrives and does
		not acknowledge it, so a close to one ends at `closeTimeout`.
	**/
	public function close():Void {
		if (__closed || __closing) {
			return;
		}

		if (!__connected || __remoteAddress == "" || __remotePort <= 0 || __transport == null) {
			abort();
			return;
		}

		// Set before the stream's bytes are queued: they are the last of
		// what was sent, and go however far past `maxOutputBufferSize` they
		// take the queue, a limit on a sender outrunning its path, which a
		// close is not.
		__closing = true;
		__closeStartedAt = __clock();
		if (__mode == STREAM && __output.length > 0) {
			__queueBytes(__output, 0, __output.length);
			__output = __createBuffer();
		}
		// Unread, and now unreadable: `bytesAvailable` says so.
		__input = __createBuffer();

		__queueFin();
		__armCloseTimer(__closeTimeout);
		// Now rather than when the pass ends, as the FIN always went: a
		// program that closes and then exits still sends it.
		__sendBundle();
	}

	/**
		Ends the session at once, on both sides.

		What this session has gathered in the pass goes, and then a FIN that
		ends the peer's session the moment it arrives, holding nothing back
		for what is still on its way: whatever the peer has not received by
		then -- frames the congestion window held, frames lost and not yet
		sent again, stream bytes not flushed -- is dropped, on both sides.
		`close` is dispatched before this returns, for a session that had a
		peer, and the peer dispatches its own when the FIN arrives.

		For a session that cannot or should not wait: a server shutting down,
		a peer breaking the protocol. `close()` is the graceful way, and
		calling this while it waits ends that close.
	**/
	public function abort():Void {
		if (__closed) {
			return;
		}

		if (__remoteAddress != "" && __remotePort > 0) {
			__sendControl(FIN);
			__sendBundle();
		}

		__dispose(true);
	}

	/**
		Queues the graceful FIN behind everything this session has to send.
		It takes its sequence when it goes, as a PACKET does -- the place
		after the last frame -- and is sent again until acknowledged, as a
		PACKET is.
	**/
	@:noCompletion private function __queueFin():Void {
		var frame = new OutstandingFrame(new ByteArray(), 0, 0, false);
		frame.fin = true;
		if (__queueAt < __outgoingQueue.length || __windowExceeded()) {
			__outgoingQueue.push(frame);
			return;
		}
		__sendPacket(frame);
	}

	/** (Re)starts the timer that checks on a close, `delay` seconds from now; none for no deadline. **/
	@:noCompletion private function __armCloseTimer(delay:Float):Void {
		if (__closeTimerHandle != -1) {
			CBTimer.clear(__closeTimerHandle);
			__closeTimerHandle = -1;
		}
		if (__closeTimeout <= 0) {
			return;
		}
		__closeTimerHandle = CBTimer.setTimeout(delay, __onCloseTimer);
	}

	/**
		The close's deadline, looked at: given up if the peer has gone
		`closeTimeout` seconds without showing it received anything, and
		looked at again when it would have if it has shown so since.
	**/
	@:noCompletion private function __onCloseTimer():Void {
		__closeTimerHandle = -1;
		if (__closed || !__closing || __closeTimeout <= 0) {
			return;
		}

		var since:Float = __lastDeliveryAt > __closeStartedAt ? __lastDeliveryAt : __closeStartedAt;
		var left:Float = __closeTimeout - (__clock() - since);
		if (left > 0) {
			__armCloseTimer(left);
			return;
		}
		__giveUpClose();
	}

	/**
		The peer acknowledged nothing for `closeTimeout` seconds. What it has
		not acknowledged may never arrive, which an `ioError` says -- unless
		all that is missing is the FIN's own acknowledgement, which means the
		rest arrived and only word of the close was lost. Then the peer is
		told the session is over, at once, as `abort()` tells it: it may be
		holding frames past a gap that will now never fill.
	**/
	@:noCompletion private function __giveUpClose():Void {
		if (__sentButUnacknowledged() && hasEventListener(IOErrorEvent.IO_ERROR)) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, 'The peer acknowledged nothing for ${__closeTimeout} s after close(); '
				+ 'what it had not acknowledged by then may not have arrived.'));
		}
		abort();
	}

	/**
		Whether anything sent before the FIN is still unacknowledged: in
		flight, held past a gap the peer has not filled, or waiting for the
		window.
	**/
	@:noCompletion private function __sentButUnacknowledged():Bool {
		var sequence:Seq32 = __windowBase;
		while (sequence < __outSequence) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);
			if (frame != null && !frame.fin) {
				return true;
			}
			sequence++;
		}
		for (index in __queueAt...__outgoingQueue.length) {
			if (!__outgoingQueue[index].fin) {
				return true;
			}
		}
		return false;
	}

	/**
		Initiates a reliable UDP session to the specified remote endpoint.
		The socket automatically binds its transport to an ephemeral local port if
		you have not called `bind()` already.

		`payload` rides in every CONNECT the handshake sends, for the server's
		`admit` to decide on before it allocates anything -- a join token, a
		protocol version, a ticket. It must fit one frame. It is sent in the
		clear and repeated until the server answers, and nothing proves the
		sender's address until the handshake completes, so what it can carry
		is something the server can check, not something that must stay secret.

		`host` may be a name everywhere but Node. It is looked up off the
		runtime's thread, and the handshake starts when the answer comes;
		`remoteAddress` is the address it resolved to from then. The attempt's
		timeout counts the lookup. A name that does not resolve is reported as
		an `ioError` event, and the socket then closes, as an attempt that
		timed out does.

		@param host The remote address, or a name, to connect to.
		@param port The remote UDP port to connect to.
		@param payload Sent with the CONNECT: all of it, from 0 to its length,
		       copied now, so changing it afterwards changes nothing sent.
		@throws IOError If the socket is closed or otherwise invalid.
		@throws IllegalOperationError If this socket was accepted by a server.
		@throws ArgumentError If `host` is empty, or a malformed address, or
		        -- on Node -- a name.
		@throws RangeError If `port` is outside the valid UDP port range, or
		        `payload` is larger than one frame,
		        `ReliableDatagramProtocol.MAX_PAYLOAD_SIZE` bytes.
	**/
	public function connect(host:String, port:Int, ?payload:ByteArray):Void {
		// A close still waiting on its peer is as closed as one finished.
		if (__closed || __closing) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!__ownsTransport) {
			throw new IllegalOperationError("Cannot connect a socket accepted by a server.");
		}

		if (host == null || host.length == 0) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		if (port <= 0 || port > 65535) {
			throw new RangeError("Invalid socket port number specified.");
		}

		var outgoing:ByteArray = __connectPayloadOf(payload);

		if (!bound) {
			__transport.bind();
		}

		#if nodejs
		// No resolution step. hxnodejs resolves a name synchronously through
		// `deasync`, a native npm addon that has to be installed and built --
		// requiring it is enough to stop the program loading, whether or not a
		// name is ever passed. A numeric address needs no lookup, and a name
		// is refused for the same reason a connected DatagramSocket refuses
		// one: a session is matched against the address a reply arrives from.
		if (!IPv6.isNumericAddress(host)) {
			throw new ArgumentError("A reliable datagram session needs a numeric address on Node, not a name: the session is matched against the address replies arrive from, and resolving a name there needs a callback this call cannot wait for.");
		}

		__remoteAddress = host;
		#else
		// Whatever an earlier attempt was waiting on, its answer is not this
		// one's.
		__lookups++;
		__lookingUp = false;

		if (crossbyte._internal.net.Resolver.needsLookup(host) && crossbyte._internal.net.Resolver.runtimeHere() != null) {
			__connectByName(host, port, outgoing);
			return;
		}

		var resolved:Host;
		try {
			resolved = new Host(host);
		} catch (_:Dynamic) {
			throw new ArgumentError("One of the parameters is invalid");
		}

		__remoteAddress = resolved.toString();
		#end
		__remotePort = port;
		__remoteResponsePort = 0;
		__incoming = false;
		__connectOut = outgoing;
		__resetSequences();
		__connectionId = __newConnectionId();
		__transport.receive();
		__beginHandshake();
	}

	#if !nodejs
	/**
		`connect()` to a name: looked up off the runtime's thread (see
		`Resolver`), and the handshake begun when the answer comes.

		It used to be looked up in the call, on the runtime's thread, so every
		socket and timer there waited on the resolver -- a second, for a name
		that does not exist -- and a client reconnecting in a loop did it again
		exactly while the resolver was failing. The attempt's deadline runs
		from the call and is not restarted by the answer, so a resolver that
		never answers times the attempt out as a silent peer would; a name
		that does not resolve is reported as `ioError`, and the session
		closed, as a failed attempt is.
	**/
	@:noCompletion private function __connectByName(host:String, port:Int, outgoing:ByteArray):Void {
		__remoteAddress = "";
		__remotePort = port;
		__remoteResponsePort = 0;
		__incoming = false;
		__connectOut = outgoing;
		__resetSequences();
		__connectionId = __newConnectionId();
		__transport.receive();

		__clearHandshakeTimers();
		__armConnectionTimeout();

		var lookup:Int = __lookups;
		__lookingUp = true;
		crossbyte._internal.net.Resolver.resolve(host, function(resolved:Null<Host>, failure:Null<String>):Void {
			// Closed, or asked to connect somewhere else, meanwhile.
			if (__closed || lookup != __lookups) {
				return;
			}

			if (resolved == null) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Could not connect to " + host + ": the name did not resolve (" + failure + ")"));
				__dispose(true);
				return;
			}

			__lookingUp = false;
			__remoteAddress = resolved.toString();
			__beginHandshake(true);
		});
	}
	#end

	/** A connection id: random, 32 bits, and never 0, which means none. **/
	@:noCompletion private function __newConnectionId():Int {
		var id:Int = 0;
		while (id == 0) {
			id = __randomSequenceSeed();
		}
		return id;
	}

	/**
		A copy of a CONNECT payload, or null for none; refused rather than
		split when it is larger than the one frame a CONNECT is.
	**/
	@:noCompletion private static function __connectPayloadOf(payload:ByteArray):ByteArray {
		if (payload == null || payload.length == 0) {
			return null;
		}
		if (payload.length > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
			throw new RangeError('A CONNECT payload must fit one frame, ${ReliableDatagramProtocol.MAX_PAYLOAD_SIZE} bytes, and this one is ${payload.length}.');
		}
		var copy = new ByteArray();
		copy.length = payload.length;
		(copy : haxe.io.Bytes).blit(0, payload, 0, payload.length);
		return copy;
	}

	/**
		Sends what this session has waiting now, rather than when the runtime's
		loop finishes its pass.

		In `STREAM` mode it first turns what has been written into reliable
		frames, which is the only way written bytes are sent. In either mode
		it then sends every frame gathered so far: messages, acknowledgements,
		retransmissions. Reliable frames the congestion window has not let out
		yet still wait for it; `bufferedAmount` counts those.

		Nothing needs it for correctness -- everything goes at the end of the
		pass anyway. It is for what should not wait for the rest of the pass,
		such as an input sent from deep inside a long tick handler.

		@throws IOError If there are written stream bytes to send and the
		        reliable session is not connected.
	**/
	public function flush():Void {
		if (__mode == STREAM && __output.length > 0) {
			__requireOpenConnection();
			__queueBytes(__output, 0, __output.length);
			__output = __createBuffer();
		}

		__sendBundle();
	}

	/**
		Reads a Boolean value from the stream buffer.
		@return The next Boolean value in the buffered stream.
	**/
	public function readBoolean():Bool {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readBoolean();
	}

	/**
		Reads a signed byte from the stream buffer.
		@return The next signed byte value.
	**/
	public function readByte():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readByte();
	}

	/**
		Reads bytes from the stream buffer into another `ByteArray`.
		@param bytes The destination byte array.
		@param offset The zero-based offset into `bytes` where the copied data should begin.
		@param length The number of bytes to read. Use `0` to read all available buffered bytes.
	**/
	public function readBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__input.readBytes(bytes, offset, length);
	}

	/**
		Reads a double-precision floating-point value from the stream buffer.
		@return The next IEEE 754 double-precision value.
	**/
	public function readDouble():Float {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readDouble();
	}

	/**
		Reads a single-precision floating-point value from the stream buffer.
		@return The next IEEE 754 single-precision value.
	**/
	public function readFloat():Float {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readFloat();
	}

	/**
		Reads a signed 32-bit integer from the stream buffer.
		@return The next signed integer value.
	**/
	public function readInt():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readInt();
	}

	/**
		Reads a multibyte string from the stream buffer using the specified character set.
		@param length The number of bytes to consume from the stream buffer.
		@param charSet The character set to use when decoding the bytes.
		@return The decoded string.
	**/
	public function readMultiByte(length:UInt, charSet:String):String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readMultiByte(length, charSet);
	}

	/**
		Reads a serialized object from the stream buffer, in `objectEncoding`:
		any encoding a `ByteArray` reads, and one this build cannot do throws.
		@return The decoded object.
	**/
	public function readObject():Dynamic {
		__requireStreamMode();
		__requireOpenConnection();

		// As a ByteArray reads one, in every encoding a ByteArray can -- JSON
		// always, AMF with -lib format -- and one this build cannot do throws.
		// Only HXSF was read: anything else read null, and said nothing.
		__input.objectEncoding = objectEncoding;
		return __input.readObject();
	}

	/**
		Reads a signed 16-bit integer from the stream buffer.
		@return The next signed short value.
	**/
	public function readShort():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readShort();
	}

	/**
		Reads an unsigned byte from the stream buffer.
		@return The next unsigned byte value.
	**/
	public function readUnsignedByte():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedByte();
	}

	/**
		Reads an unsigned 32-bit integer from the stream buffer.
		@return The next unsigned integer value.
	**/
	public function readUnsignedInt():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedInt();
	}

	/**
		Reads an unsigned 16-bit integer from the stream buffer.
		@return The next unsigned short value.
	**/
	public function readUnsignedShort():Int {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUnsignedShort();
	}

	/**
		Reads a UTF-8 string prefixed by its 16-bit byte length.
		@return The decoded UTF-8 string.
	**/
	public function readUTF():String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUTF();
	}

	/**
		Reads a fixed number of UTF-8 bytes from the stream buffer.
		@param length The number of UTF-8 bytes to consume.
		@return The decoded UTF-8 string.
	**/
	public function readUTFBytes(length:Int):String {
		__requireStreamMode();
		__requireOpenConnection();
		return __input.readUTFBytes(length);
	}

	/**
		Sends one message while in `DATAGRAM` mode, delivered as `delivery`
		says; see `DeliveryMode`.

		The peer receives it as one `DatagramSocketDataEvent.DATA` holding
		exactly these bytes. A `RELIABLE` message larger than a frame is split
		into frames and put back together before it is delivered, up to the
		peer's `maxMessageSize` -- eight megabytes unless the peer changed it.
		Past that the peer ends the session, as `abort()` ends one: an
		`ioError` on its side, and `close` on both. An unreliable or sequenced
		message must fit one frame.

		It goes out when the runtime's loop finishes its pass, in a datagram
		with whatever else this session sends in the same pass, or at
		`flush()`. The bytes are copied now, so the caller may reuse them.

		@param bytes The payload bytes to send.
		@param offset The zero-based offset into `bytes` at which the payload begins.
		@param length The number of bytes to send. Use `0` to send all remaining bytes from `offset`.
		@param delivery `RELIABLE` unless given.
		@throws IllegalOperationError If the socket is not in `DATAGRAM` mode.
		@throws IOError If the reliable session is not connected.
		@throws RangeError If `offset` or `length` are out of bounds, or an
		        unreliable or sequenced message is larger than
		        `ReliableDatagramProtocol.MAX_PAYLOAD_SIZE`.
	**/
	public function send(bytes:ByteArray, offset:Int = 0, length:Int = 0, delivery:DeliveryMode = RELIABLE):Void {
		__requireDatagramMode();
		__requireOpenConnection();
		if (delivery == RELIABLE) {
			__queueBytes(bytes, offset, length);
		} else {
			__sendUnreliable(bytes, offset, length, delivery);
		}
	}

	/**
		Appends a Boolean value to the stream-mode output buffer.
		@param value The Boolean value to queue for sending.
	**/
	public function writeBoolean(value:Bool):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeBoolean(value);
	}

	/**
		Appends a byte value to the stream-mode output buffer.
		@param value The byte value to queue for sending.
	**/
	public function writeByte(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeByte(value);
	}

	/**
		Appends bytes to the stream-mode output buffer.
		Call `flush()` to segment and send the queued bytes.
		@param bytes The source bytes to append.
		@param offset The zero-based offset into `bytes` at which reading should begin.
		@param length The number of bytes to append. Use `0` to append all remaining bytes from `offset`.
	**/
	public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeBytes(bytes, offset, length);
	}

	/**
		Appends a double-precision floating-point value to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeDouble(value:Float):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeDouble(value);
	}

	/**
		Appends a single-precision floating-point value to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeFloat(value:Float):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeFloat(value);
	}

	/**
		Appends a signed 32-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeInt(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeInt(value);
	}

	/**
		Appends a multibyte string to the stream-mode output buffer using the specified character set.
		@param value The string to queue for sending.
		@param charSet The character set to use when encoding the string.
	**/
	public function writeMultiByte(value:String, charSet:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeMultiByte(value, charSet);
	}

	/**
		Serializes and appends an object to the stream-mode output buffer, in
		`objectEncoding`: any encoding a `ByteArray` writes.
		@param object The object to serialize and queue for sending.
	**/
	public function writeObject(object:Dynamic):Void {
		__requireStreamMode();
		__requireOpenConnection();

		// As a ByteArray writes one; see readObject. Anything but HXSF wrote
		// nothing, and said nothing.
		__output.objectEncoding = objectEncoding;
		__output.writeObject(object);
	}

	/**
		Appends a signed 16-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeShort(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeShort(value);
	}

	/**
		Appends an unsigned 32-bit integer to the stream-mode output buffer.
		@param value The value to queue for sending.
	**/
	public function writeUnsignedInt(value:Int):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUnsignedInt(value);
	}

	/**
		Appends a UTF-8 string prefixed with a 16-bit byte length to the stream-mode output buffer.
		@param value The string to queue for sending.
	**/
	public function writeUTF(value:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUTF(value);
	}

	/**
		Appends a raw UTF-8 string to the stream-mode output buffer without a length prefix.
		@param value The string to queue for sending.
	**/
	public function writeUTFBytes(value:String):Void {
		__requireStreamMode();
		__requireOpenConnection();
		__output.writeUTFBytes(value);
	}

	@:noCompletion private static function __createAccepted(
		transport:DatagramSocket,
		remoteAddress:String,
		remotePort:Int,
		server:ReliableDatagramServerSocket,
		mode:ReliableDatagramSocketMode,
		payload:ByteArray,
		congestion:CongestionControl,
		peerConnectionId:Int = 0,
		?relay:TurnClient
	):ReliableDatagramSocket {
		var socket = new ReliableDatagramSocket();
		if (congestion != null) {
			socket.__congestion = congestion;
		}
		var temporaryTransport = socket.__transport;
		socket.__teardownTransportListener();
		if (temporaryTransport != null) {
			temporaryTransport.close();
		}
		socket.__ownsTransport = false;
		socket.__incoming = true;
		// Before the handshake, whose first answer goes back the way the
		// CONNECT came.
		socket.__relay = relay;
		socket.connectPayload = payload;
		socket.__mode = mode;
		socket.__server = server;
		socket.__transport = transport;
		socket.__remoteAddress = remoteAddress;
		socket.__remotePort = remotePort;
		socket.__remoteResponsePort = 0;
		socket.__peerConnectionId = peerConnectionId;
		socket.__keepAliveInterval = server.keepAliveInterval;
		socket.__idleTimeout = server.idleTimeout;
		socket.__resetSequences();
		socket.__beginHandshake();
		return socket;
	}

	/**
	 * A session this side initiates, over a transport somebody else owns.
	 *
	 * The mirror of `__createAccepted`, and it exists because dialling out from
	 * a socket that is already bound and listening is not a thing a caller can
	 * assemble from the public API -- `connect()` always makes its own
	 * transport. A peer-to-peer mesh needs exactly that, because hole punching
	 * only works when the port a peer dials out from is the port it is
	 * reachable on, and that is one socket.
	 *
	 * `server` is kept rather than nulled, which is the difference that matters.
	 * The server's data pump routes frames to the session registered for their
	 * source endpoint, so a dialled session that is registered gets its replies
	 * through one listener and one owner. Attaching a second listener to the
	 * shared transport instead -- which is what assembling this from outside
	 * forces -- leaves both the server and the session reading the same socket,
	 * and leaves the server free to accept a duplicate session for an endpoint
	 * the dialled one already holds.
	 *
	 * A null `remoteAddress` is a peer whose name is still being looked up:
	 * the attempt's deadline starts now, and counts the lookup, and the
	 * handshake waits for `__beginDialled` with the answer.
	 */
	@:noCompletion private static function __createDialed(transport:DatagramSocket, remoteAddress:Null<String>, remotePort:Int,
			server:ReliableDatagramServerSocket, mode:ReliableDatagramSocketMode, timeoutMs:Int, payload:ByteArray,
			congestion:CongestionControl, ?relay:TurnClient):ReliableDatagramSocket {
		var socket = new ReliableDatagramSocket();
		if (congestion != null) {
			socket.__congestion = congestion;
		}
		// Before the handshake, whose first CONNECT goes through it.
		socket.__relay = relay;
		var temporaryTransport = socket.__transport;
		socket.__teardownTransportListener();

		if (temporaryTransport != null) {
			temporaryTransport.close();
		}

		// Set before the handshake begins, or the first retransmission window
		// is measured against the default rather than what the caller asked for.
		if (timeoutMs > 0) {
			socket.timeout = timeoutMs;
		}

		socket.__ownsTransport = false;
		socket.__incoming = false;
		socket.__connectOut = payload;
		socket.__mode = mode;
		socket.__server = server;
		socket.__transport = transport;
		socket.__remoteAddress = remoteAddress != null ? remoteAddress : "";
		socket.__remotePort = remotePort;
		socket.__remoteResponsePort = 0;
		socket.__keepAliveInterval = server.keepAliveInterval;
		socket.__idleTimeout = server.idleTimeout;
		socket.__resetSequences();
		socket.__connectionId = socket.__newConnectionId();
		if (remoteAddress == null) {
			socket.__lookingUp = true;
			socket.__armConnectionTimeout();
		} else {
			socket.__beginHandshake();
		}
		return socket;
	}

	/**
		A dialled session's peer, looked up: the address its name resolved to,
		and the policy the server chose for it. The handshake begins, under the
		deadline that has been running since the call.
	**/
	@:noCompletion private function __beginDialled(remoteAddress:String, congestion:Null<CongestionControl>):Void {
		__lookingUp = false;
		if (congestion != null) {
			__congestion = congestion;
		}
		__remoteAddress = remoteAddress;
		__beginHandshake(true);
	}

	@:noCompletion private function __acceptFrame(frame:ReliableDatagramFrame):Void {
		if (__closed || frame == null) {
			return;
		}

		// Meant for an earlier attempt from this address and port -- a
		// session that went on answering a peer since restarted -- and taking
		// it would start this one from that session's sequence.
		if (frame.type == HANDSHAKE && __answersAnotherAttempt(frame)) {
			return;
		}

		// A CONNECT is not a sign of life from a peer that has finished its
		// handshake: that peer never sends one again. A restarted peer does,
		// every few seconds, and counting those kept the session it had left
		// behind alive for as long as it went on trying.
		if (frame.type != CONNECT || !__peerConfirmed) {
			__alive = true;
		}

		// Only what a connected peer sends is the old peer answering a
		// challenge. A HANDSHAKE with no acknowledgement comes from a peer that
		// is not connected -- a restarted one, drawn out by something the old
		// session sent it.
		if (__challengedAt >= 0 && (frame.ack != null || (frame.type != HANDSHAKE && frame.type != CONNECT))) {
			__heardSinceChallenge = true;
		}
		if (frame.ack != null) {
			__acceptAck(frame.ack);
			// What it acknowledged was the last of a close this side was
			// waiting on, and the session is over: nothing it carries is
			// for anyone now.
			if (__closed) {
				return;
			}
		}

		switch (frame.type) {
			// A FIN that ends the session at once can come from anyone -- a
			// server telling a peer it holds no session for it -- where a
			// graceful one, holding a place in the sequence, only ever comes
			// from a connected peer.
			case CONNECT, HANDSHAKE:
			case FIN if (!frame.graceful):
			default:
				if (!__connected) {
					// Only a connected peer sends this, so the peer took this
					// side's HANDSHAKE and the one it sent back was lost. This
					// side cannot place the frame without that one, and the
					// peer will not send it again unasked -- nothing would,
					// and the session would sit there until it timed out.
					// Asked once a pass, however many frames arrive: one
					// datagram answered with one, as a CONNECT is.
					__oweHandshake();
					return;
				}
				__peerConfirmed = true;
		}

		switch (frame.type) {
			case CONNECT:
				// Answered whichever side dialled, which is what makes hole
				// punching possible. The guard here was `__incoming`, on the
				// reading that only an accepted session answers a CONNECT --
				// true of a client and a server, and false of two peers behind
				// NAT. Those must dial each other at the same moment, because
				// each side's outbound datagram is what opens its own mapping
				// for the other; so both are outgoing, both sent CONNECT, and
				// neither would answer. Both sessions then sat retransmitting
				// until they timed out, which is a peer-to-peer connection
				// failing for no reason the peers could see.
				//
				// HANDSHAKE is the same frame an accepted session replies with,
				// so the client-and-server case is unchanged: it took this
				// branch before and takes it now.
				if (frame.bundles) {
					__peerTakesBundles = true;
				}
				// The peer's id, from the first CONNECT that brings one, so the
				// HANDSHAKE below and every one after says which attempt it
				// answers.
				if (__peerConnectionId == 0) {
					__peerConnectionId = frame.sequence;
				}
				if (!__connected) {
					__sendHandshake();
				}
				// The first one a dialled peer sends, kept as the server keeps
				// an accepted session's. Held only at a size the protocol can
				// send, as the server holds it.
				if (connectPayload == null && frame.payload.length <= ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
					connectPayload = frame.payload;
				}
			case HANDSHAKE:
				if (frame.bundles) {
					__peerTakesBundles = true;
				}
				__onHandshake(frame.sequence, frame.ack != null);
			case PACKET:
				__acceptPacket(frame.sequence, frame.payload, frame.more);
			case ACK:
				__acceptAckFrame(frame.sequence, frame.payload);
			case FIN:
				if (frame.graceful) {
					__acceptFin(frame.sequence);
				} else if (__closing) {
					__closeEndedByPeer();
				} else {
					__dispose(true);
				}
			case UNRELIABLE:
				__acceptUnreliable(frame.payload);
			case SEQUENCED:
				__acceptSequenced(frame.sequence, frame.payload);
		}
	}

	/**
		An unreliable message, delivered as it arrives. Only on an established
		datagram session: before the handshake there is no session for it to
		belong to, and a stream has no message boundaries to give it.
	**/
	@:noCompletion private function __acceptUnreliable(payload:ByteArray):Void {
		if (!__connected || __mode != DATAGRAM) {
			return;
		}
		__dispatchPayload(payload);
	}

	/**
		A sequenced message, delivered only if it is newer than the last one
		delivered on its channel. An older one arriving late is dropped, and so
		is a duplicate, which is the same counter arriving twice.
	**/
	@:noCompletion private function __acceptSequenced(field:Seq32, payload:ByteArray):Void {
		if (!__connected || __mode != DATAGRAM) {
			return;
		}

		if (__sequencedIn == null) {
			__sequencedIn = __filled(DeliveryMode.CHANNELS, -1);
		}

		var channel:Int = ReliableDatagramProtocol.channelOf(field);
		var counter:Int = ReliableDatagramProtocol.counterOf(field);
		var newest:Int = __sequencedIn[channel];
		if (newest != -1 && !ReliableDatagramProtocol.counterIsNewer(counter, newest)) {
			return;
		}

		__sequencedIn[channel] = counter;
		__dispatchPayload(payload);
	}

	/**
		One in-order reliable frame. In a stream it is bytes; in datagram mode
		it is a message, or part of one when `more` says another follows.

		A message of one frame -- nearly every message -- is delivered as it
		came, with no copy. Fragments are held until the last and joined once.
	**/
	@:noCompletion private function __deliverReliable(payload:ByteArray, more:Bool):Void {
		if (__mode == STREAM) {
			__dispatchPayload(payload);
			return;
		}

		var limit:Int = maxMessageSize;
		// The length as an Int. A limit lowered below what is already held
		// makes the difference negative, and a UInt compared with a negative
		// Int is unsigned on every target but HashLink: four billion, which
		// nothing is past.
		var length:Int = payload.length;
		if (limit > 0 && length > limit - __fragmentBytes) {
			var message:String = 'A reliable message from the peer passed the $limit byte maxMessageSize before it ended; '
				+ 'the session was closed rather than hold more of it.';
			__fragments.resize(0);
			__fragmentBytes = 0;
			if (hasEventListener(IOErrorEvent.IO_ERROR)) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
			}
			// At once: a graceful close would wait on a peer that is sending
			// what this side has just refused to hold.
			abort();
			return;
		}

		if (__fragments.length == 0 && !more) {
			__dispatchPayload(payload);
			return;
		}

		__fragments.push(payload);
		__fragmentBytes += payload.length;
		if (more) {
			return;
		}

		var whole:ByteArray = new ByteArray();
		whole.length = __fragmentBytes;
		var at:Int = 0;
		for (fragment in __fragments) {
			(whole : haxe.io.Bytes).blit(at, fragment, 0, fragment.length);
			at += fragment.length;
		}
		__fragments.resize(0);
		__fragmentBytes = 0;
		__dispatchPayload(whole);
	}

	@:noCompletion private static function __filled(size:Int, value:Int):Vector<Int> {
		var vector = new Vector<Int>(size);
		for (i in 0...size) {
			vector[i] = value;
		}
		return vector;
	}

	/** A cumulative acknowledgement carried on another frame. **/
	@:noCompletion private function __acceptAck(ackValue:Seq32):Void {
		// Checked before the clock is read: every frame carries one, and
		// almost all of them say nothing new.
		if (ackValue <= __windowBase || __outSequence < ackValue) {
			return;
		}
		var now:Float = __clock();
		__release(ackValue, now);
		__detectLosses(now);
		__drainQueue();
	}

	/**
		Releases every frame below `ackValue`, and says whether that was any.

		Walked from the old acknowledgement point to the new one rather than
		by asking every outstanding frame whether it is covered: the
		acknowledgement is cumulative, so the frames it releases are the run
		between the two, and that is the number of frames released rather
		than the number still in flight.
	**/
	@:noCompletion private function __release(ackValue:Seq32, now:Float):Bool {
		if (ackValue <= __windowBase || __outSequence < ackValue) {
			return false;
		}

		var newest:Float = -1;
		var released:Int = 0;
		var sequence:Seq32 = __windowBase;

		while (sequence < ackValue) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);

			if (frame != null) {
				if (frame.sacked) {
					// Delivered when the peer first said it held it, and
					// measured then: timed now, it would count the wait for
					// the gap below it as a round trip. It did, and a session
					// losing one frame in ten took its round trip on loopback
					// to half a second.
					__sackedCount--;
				} else {
					__noteDelivered(sequence, frame, now);
					// Karn's algorithm: a frame that was sent more than once
					// cannot say which copy this acknowledges.
					if (frame.attempts == 1 && frame.sentAt > newest) {
						newest = frame.sentAt;
					}
				}
				__outFrameCache.remove(sequence);
				released++;
			}

			sequence++;
		}

		__windowBase = ackValue;
		if (__inRecovery && !(ackValue < __recoveryPoint)) {
			__inRecovery = false;
		}

		// One measurement an acknowledgement, from the last frame sent of
		// those it covers: the others waited behind it for the same answer.
		if (newest >= 0) {
			__sampleRoundTrip(now - newest);
		}

		// After the round trip it measured, so the policy reads it, and before
		// any loss this acknowledgement shows.
		if (released > 0) {
			__congestion.onAcknowledged(this, released, now);
		}

		// A close waiting on the peer, and nothing left in flight or queued:
		// the FIN, which went last, is acknowledged, and so is everything
		// before it.
		if (__closing && __windowBase == __outSequence && __queueAt >= __outgoingQueue.length) {
			__dispose(true);
		}
		return true;
	}

	/**
		A standalone acknowledgement: the cumulative value, then whatever its
		selective map says the peer holds, then whatever that shows was lost,
		sent again now rather than when its timeout runs out. That wait was
		the whole cost of a loss -- at least 200 ms, and one frame per check
		-- and over a window of losses it was the ceiling on everything else.

		From a peer that sends no selective acknowledgements, the third in a
		row that moves nothing marks the frame it is waiting for as lost.
	**/
	@:noCompletion private function __acceptAckFrame(ackValue:Seq32, sack:ByteArray):Void {
		var now:Float = __clock();
		var progressed:Bool = __release(ackValue, now);

		if (sack != null && sack.length > 0) {
			__peerSacks = true;
			__dupAcks = 0;
			__acceptSack(ackValue, sack, now);
			__detectLosses(now);
			// What the peer now holds has left the window: new frames can go
			// out behind it, which keeps acknowledgements coming, and with
			// them word of anything else lost.
			__drainQueue();
			return;
		}

		if (progressed) {
			__dupAcks = 0;
			__detectLosses(now);
			__drainQueue();
			return;
		}

		// A peer that has sent a selective acknowledgement sends one whenever
		// it holds a frame past a gap, so a plain one from it is a duplicate
		// arriving, not a gap: counting those would send frames still on
		// their way.
		if (__peerSacks) {
			return;
		}

		var oldest:Null<OutstandingFrame> = __outFrameCache.get(__windowBase);
		if (oldest != null && ackValue == __windowBase) {
			__dupAcks++;
			if (__dupAcks == DUP_THRESHOLD) {
				__resendLost(__windowBase, oldest, now);
			}
		}
	}

	/** Marks what the peer's selective acknowledgement says it holds. **/
	@:noCompletion private function __acceptSack(ackValue:Seq32, sack:ByteArray, now:Float):Void {
		var bytes:haxe.io.Bytes = sack;
		var length:Int = sack.length < ReliableDatagramProtocol.SACK_BYTES ? sack.length : ReliableDatagramProtocol.SACK_BYTES;
		var base:Seq32 = ackValue + 1;
		var newest:Float = -1;

		for (index in 0...length) {
			var bits:Int = bytes.get(index);
			if (bits == 0) {
				continue;
			}
			for (bit in 0...8) {
				if ((bits & (1 << bit)) == 0) {
					continue;
				}
				var sequence:Seq32 = base + ((index << 3) + bit);
				var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);
				if (frame == null || frame.sacked) {
					continue;
				}
				frame.sacked = true;
				__sackedCount++;
				__noteDelivered(sequence, frame, now);
				if (frame.attempts == 1 && frame.sentAt > newest) {
					newest = frame.sentAt;
				}
			}
		}

		if (newest >= 0) {
			__sampleRoundTrip(now - newest);
		}
	}

	/**
		Keeps the record loss is judged by: of every frame known delivered,
		the one sent last, and how long it took. RFC 8985 calls it RACK.
	**/
	@:noCompletion private function __noteDelivered(sequence:Seq32, frame:OutstandingFrame, now:Float):Void {
		__framesDelivered++;
		__lastDeliveryAt = now;
		__probed = false;

		// A frame sent once and delivered below the highest delivered one
		// was overtaken on the way, which a lost frame and this one can look
		// alike: from here on, loss waits a little for stragglers.
		if (__rackSentAt < 0 || __highestDelivered < sequence) {
			__highestDelivered = sequence;
		} else if (frame.attempts == 1) {
			__reorderingSeen = true;
		}

		var roundTrip:Float = now - frame.sentAt;
		// Sent again, and back faster than anything has ever come back: the
		// first copy arrived, not the one the send time is of.
		if (frame.attempts > 1 && __minRtt >= 0 && roundTrip < __minRtt) {
			return;
		}
		if (__rackSentAt < 0 || frame.sentAt > __rackSentAt || (frame.sentAt == __rackSentAt && __rackSequence < sequence)) {
			__rackSentAt = frame.sentAt;
			__rackSequence = sequence;
			__rackRtt = roundTrip;
		}
	}

	/**
		Sends again each frame that was sent before one the peer has, and has
		had the round trip that one took, and a little more, to arrive in.

		By send time rather than by counting the frames held past it, as RFC
		6675 does. A count needs three frames past the gap: in a window of
		fewer, which is what a lossy path leaves, no loss is found that way,
		and each waits out a timeout instead. And a frame sent again and lost
		again has frames held past it from the first time, so the count says
		nothing about the second; time does.
	**/
	@:noCompletion private function __detectLosses(now:Float):Void {
		if (__rackSentAt < 0 || __closed) {
			return;
		}

		var allowance:Float = __rackRtt + __reorderWindow();
		var sequence:Seq32 = __windowBase;
		while (sequence < __outSequence) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);
			if (frame != null && !frame.sacked) {
				if (frame.sentAt > __rackSentAt || (frame.sentAt == __rackSentAt && !(sequence < __rackSequence))) {
					// Sent after it. First sends go out in order and a frame
					// sent again goes out later still, so every frame past a
					// first send is later too, and nothing further is lost.
					if (frame.attempts == 1) {
						return;
					}
				} else if (now - frame.sentAt >= allowance) {
					__resendLost(sequence, frame, now);
					if (__closed) {
						return;
					}
				}
			}
			sequence++;
		}
	}

	/**
		How much longer than the round trip a frame is given, past one sent
		after it that arrived, before it counts as lost: a quarter of the
		fastest round trip, for stragglers. Nothing while this path has never
		reordered a frame and three are held past a gap, or loss is already
		being recovered from, as RFC 8985 has it.
	**/
	@:noCompletion private function __reorderWindow():Float {
		if (!__reorderingSeen && (__inRecovery || __sackedCount >= DUP_THRESHOLD)) {
			return 0;
		}
		var window:Float = __minRtt > 0 ? __minRtt / 4 : 0;
		return __smoothedRtt > 0 && window > __smoothedRtt ? __smoothedRtt : window;
	}

	/**
		Sends a lost frame again. The first loss of a burst is the policy's to
		answer, and the rest of the burst, up to where recovery ends, is not
		answered again. The timeout is left as it is: nothing timed out.
	**/
	@:noCompletion private function __resendLost(sequence:Seq32, frame:OutstandingFrame, now:Float):Void {
		if (!__inRecovery) {
			__inRecovery = true;
			__recoveryPoint = __outSequence;
			__congestion.onLoss(this, now);
		}

		frame.attempts++;
		frame.sentAt = now;
		frame.deadline = now + __rto;
		__lastTransmitAt = now;
		__fastResends++;
		__transmit(sequence, frame, true);
	}

	/** Sends every frame not yet acknowledged again, in order. **/
	@:noCompletion private function __resendUnacknowledged():Void {
		var now:Float = __clock();
		var sequence:Seq32 = __windowBase;
		while (sequence < __outSequence) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);
			if (frame != null) {
				frame.attempts++;
				frame.sentAt = now;
				frame.deadline = now + __rto;
				__lastTransmitAt = now;
				__fastResends++;
				__transmit(sequence, frame, true);
				if (__closed) {
					return;
				}
			}
			sequence++;
		}
	}

	/**
		Sends the last frame not yet delivered again, once, when nothing has
		come back for two round trips: RFC 8985's tail loss probe.

		Loss is found by what arrives after it, and at the end of a burst, or
		with a window full of frames sent again and lost again, nothing does.
		What was left then was the timeout, at least 200 ms, doubling, and
		the window halved with it. The probe's acknowledgement says what the
		peer holds, and the frames before it that it lacks are then found
		lost the ordinary way. One per silence: if that is lost too, the
		timeout is what is left.
	**/
	@:noCompletion private function __probeTail(now:Float):Void {
		if (__probed || __smoothedRtt < 0) {
			return;
		}

		var wait:Float = 2 * __smoothedRtt;
		if (wait < MIN_PROBE_TIMEOUT) {
			wait = MIN_PROBE_TIMEOUT;
		}
		var quietSince:Float = __lastDeliveryAt > __lastTransmitAt ? __lastDeliveryAt : __lastTransmitAt;
		if (now - quietSince < wait) {
			return;
		}

		var sequence:Seq32 = __outSequence - 1;
		while (!(sequence < __windowBase)) {
			var frame:Null<OutstandingFrame> = __outFrameCache.get(sequence);
			if (frame != null && !frame.sacked) {
				__probed = true;
				__probes++;
				frame.attempts++;
				frame.sentAt = now;
				__lastTransmitAt = now;
				__transmit(sequence, frame, true);
				return;
			}
			if (sequence == __windowBase) {
				return;
			}
			sequence--;
		}
	}

	/**
		Folds one round trip measurement into the retransmission timeout.

		RFC 6298 section 2, and the reason a fixed three seconds was wrong in
		both directions: on a local path it made a lost frame wait three
		seconds for no reason, and on a path slower than that it declared loss
		that had not happened and sent the frame again, which is how a
		congested link is made worse.
	**/
	@:noCompletion private function __sampleRoundTrip(sample:Float):Void {
		if (sample <= 0) {
			return;
		}

		if (__minRtt < 0 || sample < __minRtt) {
			__minRtt = sample;
		}

		if (__smoothedRtt < 0) {
			__smoothedRtt = sample;
			__rttVariation = sample / 2;
		} else {
			var difference:Float = __smoothedRtt - sample;

			if (difference < 0) {
				difference = -difference;
			}

			__rttVariation = 0.75 * __rttVariation + 0.25 * difference;
			__smoothedRtt = 0.875 * __smoothedRtt + 0.125 * sample;
		}

		__setRto(__smoothedRtt + 4 * __rttVariation);
	}

	@:noCompletion private function __setRto(value:Float):Void {
		__rto = value < MIN_RTO ? MIN_RTO : (value > MAX_RTO ? MAX_RTO : value);
	}

	@:noCompletion private function __acceptPacket(sequence:Seq32, payload:ByteArray, more:Bool = false):Void {
		if (sequence == __inSequence) {
			__inSequence++;
			__deliverReliable(payload, more);
			__drainBufferedPackets();
		} else if (__shouldBufferPacket(sequence)) {
			__cacheFrame(sequence, payload, more);
		}

		// A handler may have closed the session, or a message too large may
		// have; there is then nobody to acknowledge to, and the send would
		// fail and report an error about a socket the caller closed itself.
		if (!__closed) {
			__sendAck();
		}
	}

	/**
		The peer's graceful FIN, which holds the place after the last frame it
		sent, taken in order as a PACKET is: the session ends now if that
		place is the next one due, and otherwise the FIN waits, as a frame
		past a gap does, for what is missing before it.

		The FIN carried no sequence, and the session ended the moment one
		arrived. One that overtook a lost frame, or arrived while frames past
		a gap were held, ended it with those never delivered -- and the
		closing side, disposed at once, never sent them again.
	**/
	@:noCompletion private function __acceptFin(sequence:Seq32):Void {
		if (sequence == __inSequence) {
			__inSequence++;
			__finishByPeer();
			return;
		}

		if (__shouldBufferPacket(sequence)) {
			__cacheFin(sequence);
		}
		__sendAck();
	}

	/** A graceful FIN held past a gap, as `__cacheFrame` holds a PACKET. **/
	@:noCompletion private function __cacheFin(sequence:Seq32):Void {
		if (!__inFrameCache.exists(sequence)) {
			__inFrameCacheSize++;
		}

		__inFrameCache.set(sequence, new ReliableDatagramFrame(FIN, sequence, null, false, null, false, false, true));
	}

	/**
		The peer has closed, and everything it sent before its FIN has been
		delivered. The FIN is acknowledged at once -- the peer's close is
		waiting on it, and this session sends nothing after it -- and the
		session ends.
	**/
	@:noCompletion private function __finishByPeer():Void {
		__ackOwed = true;
		__sendBundle();
		__dispose(true);
	}

	/**
		The peer ended the session at once while this side's close was
		waiting on it: it aborted, or had let its session go already -- as
		one does once it has taken the FIN, and then hears it again because
		its acknowledgement was lost. As at the deadline, an `ioError` says
		so if more than the FIN went unacknowledged, and the session ends.
		Nothing is sent to a peer that has gone.
	**/
	@:noCompletion private function __closeEndedByPeer():Void {
		if (__sentButUnacknowledged() && hasEventListener(IOErrorEvent.IO_ERROR)) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, 'The peer ended the session before acknowledging everything sent before close(); '
				+ 'what it had not acknowledged may not have arrived.'));
		}
		__dispose(true);
	}

	@:noCompletion private function __shouldBufferPacket(sequence:Seq32):Bool {
		// Only buffer sequences that are strictly ahead of the next expected one
		// and that fall inside the delivery window. RFC-1982 wrapping comparison
		// is provided by the Seq32 ordering operators, so this stays correct at
		// the 32-bit wrap boundary.
		if (!(__inSequence < sequence) || sequence > __windowCeiling()) {
			return false;
		}

		if (__inFrameCache.exists(sequence)) {
			return false;
		}

		// Cap the out-of-order cache so a flood of high sequences cannot grow it
		// without bound. The window itself bounds the live range; this guards the
		// number of distinct buffered frames within that range.
		return __inFrameCacheCount() < DELIVERY_WINDOW;
	}

	@:noCompletion private inline function __windowCeiling():Seq32 {
		return __inSequence + DELIVERY_WINDOW;
	}

	// Every insert into the out-of-order cache runs through here, and every
	// removal decrements alongside the `remove`, so `__inFrameCacheSize` tracks
	// the map exactly. The count used to be recovered by walking `keys()`, which
	// cost an O(n) iteration plus an iterator allocation for every buffered
	// datagram.
	@:noCompletion private function __cacheFrame(sequence:Seq32, payload:ByteArray, more:Bool = false):Void {
		if (!__inFrameCache.exists(sequence)) {
			__inFrameCacheSize++;
		}

		__inFrameCache.set(sequence, new ReliableDatagramFrame(PACKET, sequence, payload, false, null, more));
	}

	@:noCompletion private inline function __inFrameCacheCount():Int {
		return __inFrameCacheSize;
	}

	@:noCompletion private function __beginHandshake(deadlineArmed:Bool = false):Void {
		// Armed already when the attempt began with a name to look up: the
		// deadline counts the lookup, so it is not restarted after it.
		if (!deadlineArmed) {
			__clearHandshakeTimers();
			__armConnectionTimeout();
		}

		// Only a session that dialled repeats itself. An accepted one is
		// answering a CONNECT it never asked for, from an address UDP let
		// the sender simply claim -- so retransmitting turned one spoofed
		// datagram into a handful aimed at whoever owns that address, this
		// socket paying the postage. Answering once costs the same as the
		// packet that arrived.
		//
		// Nothing is lost by waiting: the dialling side retransmits its own
		// CONNECT on this interval until it gives up, and an unconnected
		// session answers every one of them with a fresh HANDSHAKE. A lost
		// answer is recovered by the next attempt either way.
		if (!__incoming) {
			__connectionAttemptHandle = CBTimer.setInterval(CONNECTION_ATTEMPT_INTERVAL, CONNECTION_ATTEMPT_INTERVAL, __sendHandshakeAttempt);
		}

		__sendHandshakeAttempt();
	}

	/**
		The attempt's deadline, `timeout` from now; none for a timeout of
		zero, which was armed as a timer of zero and gave the attempt up at
		the first pass.
	**/
	@:noCompletion private function __armConnectionTimeout():Void {
		if (__timeout > 0) {
			__connectionTimeoutHandle = CBTimer.setTimeout(__timeout / 1000, __onConnectionFailed);
		}
	}

	@:noCompletion private function __clearHandshakeTimers():Void {
		if (__connectionAttemptHandle != -1) {
			CBTimer.clear(__connectionAttemptHandle);
			__connectionAttemptHandle = -1;
		}

		if (__connectionTimeoutHandle != -1) {
			CBTimer.clear(__connectionTimeoutHandle);
			__connectionTimeoutHandle = -1;
		}
	}

	@:noCompletion private static function __copyRange(bytes:ByteArray, offset:Int, length:Int):ByteArray {
		var copy:ByteArray = new ByteArray();
		copy.writeBytes(bytes, offset, length);
		copy.position = 0;
		return copy;
	}

	@:noCompletion private function __appendStreamPayload(payload:ByteArray):Void {
		var nextInput:ByteArray = __createBuffer();
		var remaining:UInt = __input.bytesAvailable;
		if (remaining > 0) {
			nextInput.writeBytes(__input, __input.position, remaining);
		}
		nextInput.writeBytes(payload, 0, payload.length);
		nextInput.position = 0;
		__input = nextInput;
		dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, payload.length, 0));
	}

	@:noCompletion private function __createBuffer():ByteArray {
		var buffer = new ByteArray();
		buffer.endian = __endian;
		buffer.objectEncoding = objectEncoding;
		return buffer;
	}

	@:noCompletion private function __dispatchPayload(payload:ByteArray):Void {
		// Closed by this side, and waiting only to finish: what the peer sent
		// meanwhile is acknowledged, so it is not sent again, and goes no
		// further -- as a browser's WebSocket drops a message arriving after
		// close() was called.
		if (__closing) {
			return;
		}

		payload.position = 0;
		payload.endian = __endian;
		payload.objectEncoding = objectEncoding;

		if (__mode == STREAM) {
			__appendStreamPayload(payload);
			return;
		}

		dispatchEvent(new DatagramSocketDataEvent(
			DatagramSocketDataEvent.DATA,
			__remoteAddress,
			__remotePort,
			localAddress,
			localPort,
			payload
		));
	}

	@:noCompletion private function __dispatchTimeoutError():Void {
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Remote connection attempt has timed out and the connection could not be completed"));
	}

	@:noCompletion private function __dispose(dispatchClose:Bool):Void {
		if (__closed) {
			return;
		}

		__closed = true;
		__clearHandshakeTimers();
		if (__keepAliveHandle != -1) {
			CBTimer.clear(__keepAliveHandle);
			__keepAliveHandle = -1;
		}
		if (__closeTimerHandle != -1) {
			CBTimer.clear(__closeTimerHandle);
			__closeTimerHandle = -1;
		}
		__closing = false;

		__stopRetransmitClock();

		__outFrameCache = new IntMap();
		__inFrameCache = new IntMap();
		__inFrameCacheSize = 0;
		__fragments.resize(0);
		__fragmentBytes = 0;
		__sequencedIn = null;
		__sequencedOut = null;
		__outgoingQueue.resize(0);
		__queueAt = 0;
		__queuedBytes = 0;
		__congestion.reset();
		__framesDelivered = 0;
		__smoothedRtt = -1;
		__rttVariation = 0;
		__rto = INITIAL_RTO;
		__inRecovery = false;
		__dupAcks = 0;
		__sackedCount = 0;
		__rackSentAt = -1;
		__rackRtt = 0;
		__minRtt = -1;
		__reorderingSeen = false;
		__peerSacks = false;
		__probed = false;
		__input = __createBuffer();
		__output = __createBuffer();
		// Anything still gathered is for a session that no longer exists.
		// abort() sent it before coming here, and so did a peer's close; a
		// failure or a timeout has nobody left to send it to, and a close
		// of this side's has finished with the peer's last acknowledgement.
		__pendingLength = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
		__pendingCount = 0;
		__ackOwed = false;
		__handshakeOwed = false;
		__peerConfirmed = false;
		__bundleHasAck = false;
		__challengedAt = -1;
		__silentFor = 0;

		var wasConnected:Bool = __connected;
		__connected = false;
		// An attempt still looking its peer's name up is an attempt, and ends
		// as one does, though it has no address yet.
		var wasLookingUp:Bool = __lookingUp;
		__lookingUp = false;

		if (__server != null) {
			__server.__onSocketClosed(this);
		}

		if (__ownsTransport && __transport != null) {
			__teardownTransportListener();
			__transport.close();
		}

		if (dispatchClose && (wasConnected || __remoteAddress != "" || wasLookingUp)) {
			dispatchEvent(new Event(Event.CLOSE));
		}
	}

	@:noCompletion private function __drainBufferedPackets():Void {
		while (!__closed && __inFrameCache.exists(__inSequence)) {
			var frame:ReliableDatagramFrame = __inFrameCache.get(__inSequence);
			__inFrameCache.remove(__inSequence);
			__inFrameCacheSize--;
			__inSequence++;
			// The peer's FIN, held for the gap that has just filled: the last
			// of what it sent has been delivered.
			if (frame.type == FIN) {
				__finishByPeer();
				return;
			}
			__deliverReliable(frame.payload, frame.more);
		}
	}

	@:noCompletion private function __drainQueue():Void {
		// A cursor rather than taking the front off, which moves everything
		// still queued for each packet that leaves.
		while (__queueAt < __outgoingQueue.length && !__windowExceeded()) {
			var frame:OutstandingFrame = __outgoingQueue[__queueAt];
			__outgoingQueue[__queueAt] = null;
			__queueAt++;
			__queuedBytes -= frame.payload.length;
			__sendPacket(frame);
		}

		if (__queueAt >= __outgoingQueue.length) {
			__outgoingQueue.resize(0);
			__queueAt = 0;
			__queuedBytes = 0;
		} else if (__queueAt > 64 && __queueAt * 2 >= __outgoingQueue.length) {
			__outgoingQueue = __outgoingQueue.slice(__queueAt);
			__queueAt = 0;
		}
	}

	@:noCompletion private inline function __onConnectionFailed():Void {
		if (__connected) {
			return;
		}

		__dispatchTimeoutError();
		__dispose(true);
	}

	/**
		A HANDSHAKE names the sequence its sender's frames start from, and
		carries an acknowledgement once its sender has taken this side's. The
		first one connects this session. Every one is answered: with this
		side's own HANDSHAKE when the sender has not taken it, and otherwise
		with an ACK, which is how a peer that sent the last HANDSHAKE learns
		it arrived.

		Only the first is taken. A repeat names the same sequence, from a peer
		whose answer went missing, and the sequence was once taken from a
		repeat too: a peer that had sent frames since named where they had got
		to, and this side then skipped any still on their way, delivering
		nothing for them and acknowledging them all.

		Two peers that dialled each other used to answer every HANDSHAKE with
		one, each answer drawing the next, for as long as they were connected.
		An answer now carries an acknowledgement, and one that does is answered
		with an ACK, which draws nothing.
	**/
	@:noCompletion private function __onHandshake(sequence:Seq32, peerHasOurs:Bool):Void {
		var first:Bool = !__connected;
		if (first) {
			__inSequence = sequence;
			__connected = true;
			__alive = true;
		}

		if (peerHasOurs) {
			__peerConfirmed = true;
			__sendAck();
		} else {
			__sendHandshake();
			// Asked again after connecting, by a peer that has acknowledged
			// nothing: it never took the one this side sent back, and a
			// session not yet connected drops every frame it is sent. So
			// all of them go again now, rather than a timeout from now -- the
			// first of which, with no round trip measured yet, is a second.
			if (!first && __windowBase == __firstSequence) {
				__resendUnacknowledged();
			}
		}

		if (!first) {
			return;
		}

		// A session that dialled keeps its attempt interval, which sends its
		// HANDSHAKE again until the peer shows it arrived; see
		// `__sendHandshakeAttempt`. The timeout is done with either way.
		if (__peerConfirmed || __incoming) {
			__clearHandshakeTimers();
		} else if (__connectionTimeoutHandle != -1) {
			CBTimer.clear(__connectionTimeoutHandle);
			__connectionTimeoutHandle = -1;
		}
		__startKeepAlive();
		dispatchEvent(new Event(Event.CONNECT));

		if (__server != null) {
			__server.__onSocketConnected(this);
		}
	}

	/**
		How often the keepalive check runs: every `keepAliveInterval`, or with
		keepalives off, often enough to notice `idleTimeout` passing. Zero when
		there is nothing to do at all.
	**/
	@:noCompletion private function __keepAlivePeriod():Float {
		if (__keepAliveInterval > 0) {
			return __keepAliveInterval;
		}
		return __idleTimeout > 0 ? __idleTimeout / 4 : 0;
	}

	/** (Re)starts the keepalive check, for a connected session. **/
	@:noCompletion private function __startKeepAlive():Void {
		if (__keepAliveHandle != -1) {
			CBTimer.clear(__keepAliveHandle);
			__keepAliveHandle = -1;
		}

		__silentFor = 0;
		__sentSinceKeepAlive = false;

		var period:Float = __keepAlivePeriod();
		if (__closed || !__connected || period <= 0) {
			return;
		}
		__keepAliveHandle = CBTimer.setInterval(period, period, __onKeepAlive);
	}

	/**
		The peer's silence measured, and this side's broken.

		This used to be all of it: a check every 75 seconds that closed the
		session if nothing had arrived since the last, and nothing sent to
		make anything arrive. A session with nothing to say was closed as dead
		somewhere between 75 and 150 seconds in, with both ends running.
	**/
	@:noCompletion private function __onKeepAlive():Void {
		if (__closed || !__connected) {
			return;
		}

		var period:Float = __keepAlivePeriod();
		if (__alive) {
			__silentFor = 0;
		} else {
			__silentFor += period;
		}
		__alive = false;

		if (__idleTimeout > 0 && __silentFor >= __idleTimeout) {
			if (hasEventListener(IOErrorEvent.IO_ERROR)) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, 'Nothing was heard from the peer for ${Math.round(__silentFor)} s; '
					+ 'the session was closed as idle.'));
			}
			__dispose(true);
			return;
		}

		// Only a session that has been quiet: one sending anyway is already
		// drawing acknowledgements, which say as much.
		if (__keepAliveInterval > 0 && !__sentSinceKeepAlive) {
			__sendHandshake();
		}
		__sentSinceKeepAlive = false;
	}

	/**
		Asks the peer whether it is still there, for a server that has been
		sent a CONNECT with a new id from this session's address and port: a
		keepalive, which a peer that is still running answers.
	**/
	@:noCompletion private function __challenge(now:Float):Void {
		__challengedAt = now;
		__heardSinceChallenge = false;
		__sendHandshake();
	}

	/**
		How long a challenged peer has to answer: two retransmission timeouts,
		which is a round trip with room to spare, held between half a second
		and less than the three a dialling peer waits between CONNECTs -- so
		the CONNECT after the one that asked finds the answer due.
	**/
	@:noCompletion private function __challengeWindow():Float {
		var window:Float = __rto * 2;
		return window < 0.5 ? 0.5 : (window > 2.5 ? 2.5 : window);
	}

	@:noCompletion private inline function get_keepAliveInterval():Float {
		return __keepAliveInterval;
	}

	@:noCompletion private function set_keepAliveInterval(value:Float):Float {
		if (!(value >= 0)) {
			throw new RangeError("A keepalive interval cannot be negative.");
		}
		__keepAliveInterval = value;
		if (__connected) {
			__startKeepAlive();
		}
		return value;
	}

	@:noCompletion private inline function get_idleTimeout():Float {
		return __idleTimeout;
	}

	@:noCompletion private function set_idleTimeout(value:Float):Float {
		if (!(value >= 0)) {
			throw new RangeError("An idle timeout cannot be negative.");
		}
		__idleTimeout = value;
		if (__connected) {
			__startKeepAlive();
		}
		return value;
	}

	@:noCompletion private inline function get_closeTimeout():Float {
		return __closeTimeout;
	}

	@:noCompletion private function set_closeTimeout(value:Float):Float {
		if (!(value >= 0)) {
			throw new RangeError("A close timeout cannot be negative.");
		}
		__closeTimeout = value;
		// A close already waiting is held to the new deadline, from the same
		// point: the call, or the peer's last sign of progress since.
		if (__closing && !__closed) {
			__armCloseTimer(0);
		}
		return value;
	}

	@:noCompletion private function __prepareTransportListener():Void {
		if (__transportListenerReady) {
			return;
		}

		__transport.addEventListener(DatagramSocketDataEvent.DATA, __onTransportData);
		__transportListenerReady = true;
	}

	@:noCompletion private function __queueBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		var totalLength:Int = bytes.length;
		if (offset < 0 || offset > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		if (length == 0) {
			length = totalLength - offset;
		}

		// Against the bytes left after `offset` rather than `offset +
		// length`. That sum overflows for a large length and wraps
		// negative, so the range check passed and the send read past the
		// end of the buffer.
		if (length < 0 || length > totalLength - offset) {
			throw new RangeError("The supplied index is out of bounds.");
		}

		// Every frame but the last says more follows, which is how the receiver
		// knows where the message ends and hands it over in one piece.
		var cursor:Int = offset;
		var remaining:Int = length;
		while (remaining > 0) {
			var chunkLength:Int = remaining > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE ? ReliableDatagramProtocol.MAX_PAYLOAD_SIZE : remaining;
			remaining -= chunkLength;
			__queuePacket(__copyRange(bytes, cursor, chunkLength), remaining > 0);
			cursor += chunkLength;
		}
	}

	@:noCompletion private function __queuePacket(payload:ByteArray, more:Bool = false):Void {
		var frame = new OutstandingFrame(payload, 0, 0, more);
		if (__windowExceeded()) {
			__outgoingQueue.push(frame);
			__queuedBytes += payload.length;
			__enforceOutputLimit();
			return;
		}

		__sendPacket(frame);
	}

	/**
		An unreliable or sequenced message: one frame, straight onto the wire
		from the caller's own bytes -- nothing is kept, so nothing is copied.
	**/
	@:noCompletion private function __sendUnreliable(bytes:ByteArray, offset:Int, length:Int, delivery:DeliveryMode):Void {
		var totalLength:Int = bytes.length;
		if (offset < 0 || offset > totalLength) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length == 0) {
			length = totalLength - offset;
		}
		if (length < 0 || length > totalLength - offset) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length > ReliableDatagramProtocol.MAX_PAYLOAD_SIZE) {
			throw new RangeError('An unreliable message must fit one frame, ${ReliableDatagramProtocol.MAX_PAYLOAD_SIZE} bytes, and this one is $length; '
				+ 'split it, or send it RELIABLE.');
		}

		if (!delivery.isSequenced) {
			__sendFrame(UNRELIABLE, 0, bytes, offset, length, false, null, false);
			return;
		}

		if (__sequencedOut == null) {
			__sequencedOut = __filled(DeliveryMode.CHANNELS, 0);
		}
		var channel:Int = delivery.channel;
		var counter:Int = __sequencedOut[channel];
		__sequencedOut[channel] = (counter + 1) & ReliableDatagramProtocol.SEQUENCED_COUNTER_MASK;
		__sendFrame(SEQUENCED, ReliableDatagramProtocol.sequencedField(channel, counter), bytes, offset, length, false, null, false);
	}

	/**
		Applies `maxOutputBufferSize` to what is waiting for the window.

		Flow control means a write is not necessarily a send: it waits for
		room, and what waits is held. Before the window was allowed to close
		this queue could not grow, because the window never closed; now that
		it does, an application producing faster than the path will carry has
		to be told rather than have the queue grow until the process dies.
		Same bound and same two policies as `Socket`, for the same reason.
	**/
	@:noCompletion private function __enforceOutputLimit():Void {
		var limit:Int = maxOutputBufferSize;

		// Not for a close's own stream bytes, the last of what was written.
		if (limit <= 0 || __queuedBytes <= limit || __closing) {
			return;
		}

		var message:String = 'Reliable datagram output queue reached ${__queuedBytes} bytes, exceeding the $limit byte limit; '
			+ 'the path to the peer is not carrying data as fast as it is being written.';

		switch (outputOverflowPolicy) {
			case CLOSE:
				if (hasEventListener(IOErrorEvent.IO_ERROR)) {
					dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
				}

				// At once: a graceful close would wait for the very queue
				// that has outgrown its limit to drain.
				abort();

			case THROW:
				throw new IOError(message);
		}
	}

	@:noCompletion private inline function __requireDatagramMode():Void {
		if (__mode != DATAGRAM) {
			throw new IllegalOperationError("Cannot use datagram send while the socket is in stream mode.");
		}
	}

	@:noCompletion private inline function __requireOpenConnection():Void {
		if (__closed || __closing || !__connected || __transport == null) {
			throw new IOError("Operation attempted on invalid socket.");
		}
	}

	@:noCompletion private inline function __requireStreamMode():Void {
		if (__mode != STREAM) {
			throw new IllegalOperationError("Cannot use stream I/O while the socket is in datagram mode.");
		}
	}

	@:noCompletion private function __resetSequences():Void {
		var seed:Seq32 = __randomSequenceSeed();
		__outSequence = seed;
		__windowBase = seed;
		__firstSequence = seed;
		__inSequence = 0;
	}

	@:noCompletion private function __randomSequenceSeed():Seq32 {
		try {
			var bytes:ByteArray = SecureRandom.getSecureRandomBytes(4);
			bytes.position = 0;
			var b0:Int = bytes.readUnsignedByte();
			var b1:Int = bytes.readUnsignedByte();
			var b2:Int = bytes.readUnsignedByte();
			var b3:Int = bytes.readUnsignedByte();
			return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
		} catch (_:Dynamic) {
			// Targets without a CSPRNG (e.g. eval) fall back to a full 32-bit
			// seed assembled from two non-cryptographic draws.
			var hi:Int = Std.random(0x10000);
			var lo:Int = Std.random(0x10000);
			return (hi << 16) | lo;
		}
	}

	@:noCompletion private function __sendControl(type:ReliableDatagramFrameType, ?sequence:Seq32):Void {
		if (__remoteAddress == "" || __remotePort == 0 || __transport == null) {
			return;
		}

		var controlSequence:Seq32 = sequence == null ? 0 : sequence;
		var ack:Null<Seq32> = switch (type) {
			case ACK, CONNECT:
				null;
			default:
				__currentAck();
		}
		__sendFrame(type, controlSequence, null, 0, 0, false, ack, false);
	}

	@:noCompletion private function __sendHandshakeAttempt():Void {
		if (__connected) {
			// Connected by the peer's HANDSHAKE, with nothing yet to show the
			// one sent back arrived. If it was lost, the peer is not connected
			// and never will be: nothing else sends it. Sent again only while
			// this side has sent nothing else. Once it has, those frames draw
			// the peer's HANDSHAKE again if the peer is still waiting. An
			// older peer, taking every HANDSHAKE's sequence, would take a
			// repeat as a new place to start from.
			if (__peerConfirmed || __outSequence != __firstSequence) {
				__clearHandshakeTimers();
				return;
			}
			__sendHandshake();
			return;
		}
		if (__incoming) {
			__sendHandshake();
			return;
		}
		if (__remoteAddress == "" || __remotePort == 0 || __transport == null) {
			return;
		}
		__sendFrame(CONNECT, __connectionId, __connectOut, 0, __connectOut == null ? 0 : __connectOut.length, false, null, false);
	}

	/**
		This side's HANDSHAKE: where its frames start, an acknowledgement once
		connected, and -- once the peer has sent a CONNECT with an id -- that
		id, so the peer can tell it answers this attempt and not an earlier
		one. An older peer reads none of the payload.
	**/
	@:noCompletion private function __sendHandshake():Void {
		if (__remoteAddress == "" || __remotePort == 0 || __transport == null) {
			return;
		}

		if (__peerConnectionId == 0) {
			__sendControl(HANDSHAKE, __firstSequence);
			return;
		}

		if (__echoScratch == null) {
			__echoScratch = new ByteArray();
			__echoScratch.length = 4;
		}
		var bytes:haxe.io.Bytes = __echoScratch;
		bytes.set(0, __peerConnectionId >>> 24);
		bytes.set(1, (__peerConnectionId >>> 16) & 0xFF);
		bytes.set(2, (__peerConnectionId >>> 8) & 0xFF);
		bytes.set(3, __peerConnectionId & 0xFF);
		__sendFrame(HANDSHAKE, __firstSequence, __echoScratch, 0, 4, false, __currentAck(), false);
	}

	/**
		Whether a HANDSHAKE echoes a connection id other than this side's:
		sent by a session answering an earlier attempt from this address and
		port. One that echoes nothing -- from an older build, or one answering
		a HANDSHAKE rather than a CONNECT -- is taken as before.
	**/
	@:noCompletion private function __answersAnotherAttempt(frame:ReliableDatagramFrame):Bool {
		if (__connectionId == 0 || frame.payload == null || frame.payload.length < 4) {
			return false;
		}
		var bytes:haxe.io.Bytes = frame.payload;
		var echoed:Int = (bytes.get(0) << 24) | (bytes.get(1) << 16) | (bytes.get(2) << 8) | bytes.get(3);
		return echoed != 0 && echoed != __connectionId;
	}

	@:noCompletion private function __sendPacket(frame:OutstandingFrame):Void {
		var sequence:Seq32 = __outSequence;
		var now:Float = __clock();

		frame.sentAt = now;
		frame.deadline = now + __rto;
		frame.attempts = 1;
		__lastTransmitAt = now;
		__outFrameCache.set(sequence, frame);
		__transmit(sequence, frame, false);
		__outSequence++;
		__armRetransmitClock();
	}

	/**
		Puts an outstanding frame on the wire, first time or again: a PACKET,
		or the graceful FIN that ends the sequence.
	**/
	@:noCompletion private inline function __transmit(sequence:Seq32, frame:OutstandingFrame, resend:Bool):Void {
		__sendFrame(frame.fin ? FIN : PACKET, sequence, frame.payload, 0, frame.payload.length, resend, __currentAck(), frame.more, frame.fin);
	}

	/** The one timer the session retransmits from, started on demand. **/
	@:noCompletion private function __armRetransmitClock():Void {
		if (__retransmitHandle != -1 || __closed) {
			return;
		}

		__retransmitHandle = CBTimer.setInterval(RETRANSMIT_TICK, RETRANSMIT_TICK, function() {
			__checkRetransmits();
		});
	}

	@:noCompletion private function __stopRetransmitClock():Void {
		if (__retransmitHandle != -1) {
			CBTimer.clear(__retransmitHandle);
			__retransmitHandle = -1;
		}
	}

	/**
		What the clock finds lost, each tick: a frame whose allowance ran out
		with no acknowledgement arriving to notice, then, failing that, the
		oldest frame past its timeout, then a probe of the tail once nothing
		has come back for two round trips.

		The timeout is the last resort, and the oldest frame decides it.
		Acknowledgement is cumulative, so nothing behind a missing frame can
		be released until it arrives, and sending the rest again would be
		spending bandwidth on what the receiver is already holding. One frame
		per timeout, the window halved, the timeout doubled -- and the frames
		behind it go out as the window reopens.
	**/
	@:noCompletion private function __checkRetransmits():Void {
		if (__closed || !__connected) {
			return;
		}

		if (!__outFrameCache.keys().hasNext()) {
			__stopRetransmitClock();
			return;
		}

		var now:Float = __clock();
		// A frame sent before one that arrived becomes lost with time alone,
		// once its allowance runs out with no acknowledgement to notice.
		__detectLosses(now);
		if (__closed) {
			return;
		}

		var overdue:Null<OutstandingFrame> = __overdueFrame(now);

		if (overdue == null) {
			__probeTail(now);
			return;
		}

		__timeoutResends++;
		overdue.attempts++;
		overdue.sentAt = now;
		__lastTransmitAt = now;
		// Backed off first, so the deadline set below is the new one: RFC
		// 6298 section 5.5 doubles the timeout and then restarts the clock.
		// A path that just failed to deliver is not one to try again on the
		// same schedule, and what it may carry is the policy's to say.
		__congestion.onTimeout(this, now);
		__setRto(__rto * 2);
		overdue.deadline = now + __rto;
		__transmit(__windowBase, overdue, true);
	}

	/**
		The frame whose time is up, or null while none is.

		Only ever the oldest. Acknowledgement is cumulative, so nothing behind
		a missing frame can be released until it arrives, and sending the rest
		again would spend bandwidth on what the receiver is already holding.
	**/
	@:noCompletion private function __overdueFrame(now:Float):Null<OutstandingFrame> {
		var oldest:Null<OutstandingFrame> = __outFrameCache.get(__windowBase);

		if (oldest == null || now < oldest.deadline) {
			return null;
		}

		return oldest;
	}

	/**
		Now, for this session's round trips and losses: `haxe.Timer.stamp()`,
		never repeating a reading or going back where that clock can.

		A session reads the clock at every send and every acknowledgement, and
		two readings the same say nothing happened between them. On neko under
		Windows `haxe.Timer.stamp()` is the time of day to the millisecond, and
		it moves once a system tick -- every millisecond at best, every 15.6 by
		default. A frame acknowledged in the tick it went out in measured a
		round trip of nothing, which is thrown away, so a session there never
		had one: no probe of a silent tail, and no allowance for a straggler
		before a frame was called lost. A frame sent again in the tick it first
		went out in was taken for sent before the frame whose arrival showed it
		lost, and so was lost again, and sent again, with nothing new to say so.
		hl, neko and the interpreter all read the time of day, which can also
		be set back; this clock stands still until the time of day passes it.

		Everywhere else the clock is monotonic and finer than a send takes, and
		this is the stamp and nothing more.
	**/
	@:noCompletion private #if !(hl || neko || eval) inline #end function __clock():Float {
		#if (hl || neko || eval)
		var now:Float = haxe.Timer.stamp();
		if (!(now > __lastClock)) {
			now = __lastClock + CLOCK_STEP;
		}
		return __lastClock = now;
		#else
		return haxe.Timer.stamp();
		#end
	}

	// Owed rather than sent: the acknowledgement is cumulative, so however
	// many packets arrive in a pass, one ACK when it ends says all of it --
	// and none, when a frame going out in the same bundle already carries it.
	@:noCompletion private inline function __sendAck():Void {
		__ackOwed = true;
		if (!__flushQueued) {
			__queueFlush();
		}
	}

	@:noCompletion private inline function __oweHandshake():Void {
		__handshakeOwed = true;
		if (!__flushQueued) {
			__queueFlush();
		}
	}

	/**
		Adds a frame to the bundle being gathered for the peer, sending the
		bundle first if the frame would take it past `BUNDLE_LIMIT`. The frame
		is written in place, so nothing is copied or allocated for it.
	**/
	@:noCompletion private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Null<Seq32>, more:Bool, graceful:Bool = false):Void {
		var size:Int = ReliableDatagramProtocol.frameSize(payload == null ? 0 : length, ack != null);
		if (__pendingCount > 0
			&& __pendingLength + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + size > ReliableDatagramProtocol.BUNDLE_LIMIT) {
			__sendBundle();
		}

		var entry:Int = __pendingLength;
		var at:Int = entry + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE;
		var written:Int = ReliableDatagramProtocol.encodeInto(__scratch, type, sequence, payload, offset, length, resend, ack, more, at, graceful);
		var bytes:haxe.io.Bytes = __scratch;
		bytes.set(entry, written >> 8);
		bytes.set(entry + 1, written & 0xFF);
		__pendingLength = at + written;
		__pendingCount++;

		if (ack != null) {
			__bundleHasAck = true;
			__bundleAck = ack;
		}

		if (!__flushQueued) {
			__queueFlush();
		}
	}

	/**
		Asks the runtime to flush this session when its loop finishes the
		pass. With no runtime to ask -- none on this thread, or one that has
		stopped -- there is no pass to wait for, and the bundle goes now.
	**/
	@:noCompletion private function __queueFlush():Void {
		var runtime:CrossByte = __transport != null ? __transport.__cbInstance : null;
		if (runtime == null) {
			// Throws natively on a thread no runtime is attached to.
			try {
				runtime = CrossByte.current();
			} catch (_:Dynamic) {}
		}
		if (runtime == null || runtime.__didExit) {
			__sendBundle();
			return;
		}
		__flushQueued = true;
		runtime.__queuePassFlush(this);
	}

	/** The runtime's call at the end of a pass. **/
	@:noCompletion public function __flushPass():Void {
		__flushQueued = false;
		__sendBundle();
	}

	/**
		Sends the bundle: one frame as it is, several as one datagram to a
		peer that takes bundles, and one datagram each to a peer that does not.
		That check is made here, once per datagram, and a single frame never
		pays for the bundle's magic or its length.
	**/
	@:noCompletion private function __sendBundle():Void {
		if (__handshakeOwed) {
			__handshakeOwed = false;
			if (!__closed && !__connected) {
				__sendHandshake();
			}
		}

		if (__ackOwed) {
			__ackOwed = false;
			if (!__closed) {
				if (__inFrameCacheSize > 0) {
					// Frames are held past a gap, so the acknowledgement says
					// which, and goes on its own even when a frame going out
					// carries the cumulative value: that one has no room for
					// the map.
					var length:Int = __writeSack();
					__sendFrame(ACK, __inSequence, __sackScratch, 0, length, false, null, false);
				} else if (!(__bundleHasAck && __bundleAck == (__inSequence : Int))) {
					__sendFrame(ACK, __inSequence, null, 0, 0, false, null, false);
				}
			}
		}

		var count:Int = __pendingCount;
		if (count == 0 || __transport == null) {
			return;
		}

		// Taken down before sending, so whatever a failed send's handlers do
		// to this session starts from an empty bundle.
		var length:Int = __pendingLength;
		__pendingLength = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
		__pendingCount = 0;
		__bundleHasAck = false;

		var first:Int = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE;
		if (count == 1) {
			__sendDatagram(first, length - first);
			return;
		}

		var bytes:haxe.io.Bytes = __scratch;
		if (__peerTakesBundles) {
			bytes.set(0, ReliableDatagramProtocol.BUNDLE_MAGIC >> 8);
			bytes.set(1, ReliableDatagramProtocol.BUNDLE_MAGIC & 0xFF);
			__sendDatagram(0, length);
			return;
		}

		var at:Int = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
		while (at < length) {
			var size:Int = (bytes.get(at) << 8) | bytes.get(at + 1);
			if (!__sendDatagram(at + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE, size)) {
				return;
			}
			at += ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + size;
		}
	}

	/**
		Writes the map of frames held past the gap into `__sackScratch`, and
		says how many bytes of it matter.
	**/
	@:noCompletion private function __writeSack():Int {
		if (__sackScratch == null) {
			__sackScratch = new ByteArray();
			__sackScratch.length = ReliableDatagramProtocol.SACK_BYTES;
		}
		var bytes:haxe.io.Bytes = __sackScratch;
		bytes.fill(0, ReliableDatagramProtocol.SACK_BYTES, 0);

		var base:Int = (__inSequence : Int) + 1;
		var used:Int = 0;
		for (sequence in __inFrameCache.keys()) {
			// Wrapped to 32 bits, which JavaScript's arithmetic is not.
			var offset:Int = (sequence - base) | 0;
			if (offset < 0 || offset >= ReliableDatagramProtocol.SACK_BITS) {
				continue;
			}
			var index:Int = offset >> 3;
			bytes.set(index, bytes.get(index) | (1 << (offset & 7)));
			if (index + 1 > used) {
				used = index + 1;
			}
		}
		return used;
	}

	#if !nodejs
	/** The peer's address as the transport sends to it, kept; null while a name is looked up. **/
	@:noCompletion private function __peerTarget():Null<sys.net.Address> {
		if (__target == null || __targetAddress != __remoteAddress || __targetPort != __remotePort || __targetTransport != __transport) {
			__target = __transport.__resolveTarget(__remoteAddress, __remotePort);
			__targetAddress = __remoteAddress;
			__targetPort = __remotePort;
			__targetTransport = __transport;
		}
		return __target;
	}

	/** A datagram the transport's batch could not send: as a send that failed when made. **/
	@:noCompletion public function __datagramFailed(error:String):Void {
		if (__closed) {
			return;
		}
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, error));
		__dispose(true);
	}
	#end

	@:noCompletion private function __sendDatagram(offset:Int, length:Int):Bool {
		__sentSinceKeepAlive = true;
		try {
			if (__relay != null) {
				__sendRelayed(offset, length);
			} else {
				#if nodejs
				__transport.send(__scratch, offset, length, __remoteAddress, __remotePort);
				#else
				// With everything else this transport sends in the pass, and
				// on Linux in a call or a few rather than one each; see
				// DatagramSocket.__sendInPass. A failure comes back through
				// __datagramFailed, after this has returned.
				var target:Null<sys.net.Address> = __peerTarget();
				if (target == null) {
					__transport.send(__scratch, offset, length, __remoteAddress, __remotePort);
				} else {
					__transport.__sendInPass(__scratch, offset, length, target, this);
				}
				#end
			}
			return true;
		} catch (e:Dynamic) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, Std.string(e)));
			__dispose(true);
			return false;
		}
	}

	/**
		One datagram for the relay to forward. The peer is permitted first --
		a relay forwards to an address only once it has been told to expect it,
		and drops anything else without a word -- and bound to a channel when
		the relay was asked to use them; both cost a lookup once in place.
	**/
	@:noCompletion private function __sendRelayed(offset:Int, length:Int):Void {
		var now:Float = haxe.Timer.stamp();
		__relay.permit(__remoteAddress, now);
		__relay.bindChannel(__remoteAddress, __remotePort, now);
		__relay.sendTo(__scratch, __remoteAddress, __remotePort, offset, length);
	}

	@:noCompletion private inline function __currentAck():Null<Seq32> {
		return __connected ? __inSequence : null;
	}

	@:noCompletion private function __teardownTransportListener():Void {
		if (!__transportListenerReady || __transport == null) {
			return;
		}

		__transport.removeEventListener(DatagramSocketDataEvent.DATA, __onTransportData);
		__transportListenerReady = false;
	}

	/**
		Whether another frame may go out: what is still in the network -- sent,
		not acknowledged, and not reported held past a gap -- is held to the
		congestion window, as RFC 6675 counts it, and everything from the
		first frame not acknowledged to the newest is held to what the peer
		will buffer, `DELIVERY_WINDOW`.

		Counting held frames as in the network, as this did, stopped the
		sender at a gap: the window filled with frames already delivered,
		nothing new went out, so no acknowledgement came back to say what
		else was lost, and every lost resend waited for its timeout.
	**/
	@:noCompletion private function __windowExceeded():Bool {
		var outstanding:Int = __outSequence - __windowBase;
		return outstanding - __sackedCount >= Std.int(__congestion.window) || outstanding >= DELIVERY_WINDOW;
	}

	@:noCompletion private function __onTransportData(e:DatagramSocketDataEvent):Void {
		if (ReliableDatagramProtocol.isBundle(e.data)) {
			// Only from the peer as already known: it sends bundles once it
			// has heard from this side, so there is no port left to learn.
			if (__matchesRemoteEndpoint(e, null)) {
				__acceptBundle(e.data);
			}
			return;
		}

		var frame = ReliableDatagramProtocol.decode(e.data);
		// Before the endpoint check, which learns a reply port from the first
		// HANDSHAKE it sees: one answering an earlier attempt must not teach it.
		if (frame == null || (frame.type == HANDSHAKE && __answersAnotherAttempt(frame)) || !__matchesRemoteEndpoint(e, frame)) {
			return;
		}

		__acceptFrame(frame);
	}

	/**
		Takes each frame of a bundle in turn, as if each had come alone. An
		entry whose length runs past the end ends it; the frames before it
		stand.

		A bundle larger than `BUNDLE_LIMIT` is dropped whole. No sender makes
		one, and it is the bound on how many frames one datagram can make this
		session decode: a datagram of up to 64 KB could otherwise hold
		thousands of empty frames, each a decode and an allocation.
	**/
	@:noCompletion private function __acceptBundle(data:ByteArray):Void {
		if (data.length > ReliableDatagramProtocol.BUNDLE_LIMIT) {
			return;
		}
		var at:Int = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
		while (!__closed) {
			var length:Int = ReliableDatagramProtocol.bundleEntryLength(data, at);
			if (length < 0) {
				return;
			}
			var frame = ReliableDatagramProtocol.decodeRange(data, at + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE, length);
			at += ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + length;
			if (frame != null) {
				__acceptFrame(frame);
			}
		}
	}

	@:noCompletion private function __matchesRemoteEndpoint(e:DatagramSocketDataEvent, frame:ReliableDatagramFrame):Bool {
		if (e.srcAddress != __remoteAddress) {
			return false;
		}

		if (e.srcPort == __remotePort || (__remoteResponsePort > 0 && e.srcPort == __remoteResponsePort)) {
			return true;
		}

		if (frame != null && !__incoming && !__connected && frame.type == HANDSHAKE) {
			__remoteResponsePort = e.srcPort;
			return true;
		}

		return false;
	}

	@:noCompletion private inline function get_bound():Bool {
		return __transport != null && __transport.bound;
	}

	@:noCompletion private inline function get_bytesAvailable():UInt {
		return __mode == STREAM ? __input.bytesAvailable : 0;
	}

	@:noCompletion private inline function get_bytesPending():Int {
		return __mode == STREAM ? __output.length : 0;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __connected && !__closing;
	}

	@:noCompletion private inline function get_endian():Endian {
		return __endian;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __transport != null ? __transport.localAddress : "";
	}

	@:noCompletion private inline function get_localPort():Int {
		return __transport != null ? __transport.localPort : 0;
	}

	@:noCompletion private inline function get_mode():ReliableDatagramSocketMode {
		return __mode;
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return __remoteAddress;
	}

	@:noCompletion private inline function get_remotePort():Int {
		return __remotePort;
	}

	@:noCompletion private inline function get_timeout():Int {
		return __timeout;
	}

	@:noCompletion private function set_endian(value:Endian):Endian {
		__endian = value;
		__input.endian = value;
		__output.endian = value;
		return value;
	}

	@:noCompletion private function set_mode(value:ReliableDatagramSocketMode):ReliableDatagramSocketMode {
		if (__mode == value) {
			return value;
		}

		if (__connected || __incoming || (__remoteAddress != "" && __remotePort != 0)) {
			throw new IllegalOperationError("Socket mode must be set before connecting or accepting a session.");
		}

		if (__input.bytesAvailable > 0 || __output.length > 0) {
			throw new IllegalOperationError("Cannot change socket mode while stream buffers contain data.");
		}

		__mode = value;
		return value;
	}

	@:noCompletion private function set_timeout(value:Int):Int {
		if (value < 0) {
			throw new RangeError("Invalid socket timeout specified.");
		}

		__timeout = value;
		return value;
	}
}
#end
