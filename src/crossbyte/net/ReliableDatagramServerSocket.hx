package crossbyte.net;

// Not built for the browser: it listens, over UDP, neither of which a page can do.
#if !(js && !nodejs)

import crossbyte.Future;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net._internal.stun.StunQuery;
import crossbyte.net._internal.stun.TurnStream;
import crossbyte.net.ice.IceAgent;
import crossbyte.net._internal.RuntimeHandOff;
import crossbyte.net.ice.IceCandidate;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.TickEvent;
import crossbyte.events._internal.Arrivals;
import crossbyte.io.ByteArray;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.ResetBudget;
import crossbyte.net._internal.reliable.SipHash;
import crossbyte.net._internal.reliable.SessionCipher;
import haxe.ds.StringMap;
import crossbyte._internal.net.IPv6;
#if !nodejs
import crossbyte._internal.net.Resolver;
import sys.net.Host;
#end

@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.PreparedDatagram)
/**
	The `ReliableDatagramServerSocket` class accepts reliable UDP sessions from
	remote peers on top of a single bound `DatagramSocket`.
	Each accepted peer is represented by a `ReliableDatagramSocket` and is exposed
	through `ReliableDatagramSocketConnectEvent.CONNECT` once the reliable handshake
	completes.
	The accepted socket mode is controlled by `socketMode`, allowing the server to
	accept either datagram-style or stream-style sessions.

	A server is one datagram socket on one runtime. Unlike `ServerSocket`, it
	cannot be spread over several runtimes, with `reusePort` or otherwise: a
	session is its peer's address on that socket, and a NAT rebinding or a
	TURN relay could move a peer's datagrams to a socket that does not hold
	its session. To use more cores, run a server per runtime, each on a port
	of its own, and send each client to one of them.

	**Resuming a player.** A player whose address changes (a NAT that
	hands it a new port, a phone moving from Wi-Fi to a mobile network)
	sends from an address with no session, and is reset. `allowRebind`
	moves the session instead, where the server allows it and both ends are
	on 1.0. Where that cannot be (a peer from before 1.0, a server that
	leaves it off, and every TCP and WebSocket connection, which no change
	of address survives), the game resumes the player itself:

	- the server hands each player a resume token over its session, and
	  keeps the player's state under it;
	- a client that is reset, or times out, connects again with the token
	  as its `connect` payload;
	- `admit` checks the token (a lookup, since it is asked for every
	  CONNECT), and the handler of the new session puts the player's state
	  back on it, ending the session it left behind, which the server would
	  otherwise notice only at its `idleTimeout`.

	The token crosses the network in the clear, in the CONNECT, and anyone
	who saw it can send it: make it single-use, give a new one at every
	join, and forget it soon after the player leaves, as below. A quiet
	player does not need any of this to keep its address: a session's
	keepalive, every 15 seconds (`keepAliveInterval`), keeps a NAT's mapping
	for it open.

	```haxe
	import crossbyte.net.ReliableDatagramSocket;

	class Player {
		// What the game keeps of a player: its state, and the token it
		// may come back with.
		public var name:String;
		public var token:String = null;
		public var session:ReliableDatagramSocket = null;

		public function new(name:String) {
			this.name = name;
		}
	}
	```

	```haxe
	// Given server:ReliableDatagramServerSocket.
	import crossbyte.crypto.SecureRandom;
	import crossbyte.ds.ExpiringMap;
	import crossbyte.events.Event;
	import crossbyte.events.ReliableDatagramSocketConnectEvent;
	import crossbyte.io.ByteArray;

	// Tokens of the players here, and of those gone, for a minute.
	var here = new Map<String, Player>();
	var gone = new ExpiringMap<String, Player>(60);

	// A lookup, and nothing more: this is asked for every CONNECT.
	server.admit = function(address:String, port:Int, payload:ByteArray):Bool {
		var said:String = payload.readUTFBytes(payload.length);
		if (!StringTools.startsWith(said, "resume:")) {
			return true;
		}
		var token:String = said.substr(7);
		return here.exists(token) || gone.exists(token);
	};

	server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
		var session:ReliableDatagramSocket = e.socket;
		var said:String = session.connectPayload.readUTFBytes(session.connectPayload.length);
		var player:Player = null;
		if (StringTools.startsWith(said, "resume:")) {
			// Spent: a token resumes once.
			var token:String = said.substr(7);
			player = here.exists(token) ? here.get(token) : gone.get(token);
			here.remove(token);
			gone.remove(token);
		}
		if (player == null) {
			player = new Player(said);
		}
		// The session it left behind, at the address it left.
		var left:ReliableDatagramSocket = player.session;
		player.session = session;
		if (left != null) {
			left.abort();
		}

		var raw:haxe.io.Bytes = SecureRandom.getSecureRandomBytes(16);
		player.token = raw.toHex();
		here.set(player.token, player);
		var message = new ByteArray();
		message.writeUTFBytes("token:" + player.token);
		session.send(message);

		session.addEventListener(Event.CLOSE, function(_:Event):Void {
			// Ended, and not because the player came back on another.
			if (player.session == session) {
				player.session = null;
				here.remove(player.token);
				gone.set(player.token, player);
			}
		});
	});
	```

	And a client that comes back by itself, with the latest token it was
	given:

	```haxe
	// Given host:String, port:Int.
	import crossbyte.events.DatagramSocketDataEvent;
	import crossbyte.events.Event;
	import crossbyte.io.ByteArray;

	var token:String = null;
	var leaving:Bool = false;

	function join():Void {
		var socket = new ReliableDatagramSocket();
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var text:String = e.data.readUTFBytes(e.data.length);
			if (StringTools.startsWith(text, "token:")) {
				token = text.substr(6);
			}
		});
		// Reset, timed out, or the server gone: back in, as itself if it can.
		socket.addEventListener(Event.CLOSE, function(_:Event):Void {
			if (!leaving) {
				join();
			}
		});
		var hello = new ByteArray();
		hello.writeUTFBytes(token != null ? "resume:" + token : "player one");
		socket.connect(host, port, hello);
	}

	join();
	```

	**Encrypted sessions.** A session can seal every datagram after its
	CONNECT with a key the application gives both ends
	(`ReliableDatagramSocket.encryptionKey` on the client,
	`encryptionKeyFor` here): netcode.io's model, with QUIC's and DTLS
	1.3's nonce and replay window. CrossByte exchanges no keys and checks
	no certificates; for that, use DTLS (`crossbyte.net.rtc`) or TLS. The
	usual shape is a login service, reached over HTTPS, that signs the
	player in and answers with a connect token and a key; the client sends
	the token as its `connect` payload, and every game server derives the
	same key from the token with a secret only the servers hold, keeping
	nothing per token:

	```haxe
	import crossbyte.crypto.ConstantTime;
	import crossbyte.crypto.GenericHash;
	import crossbyte.crypto.HKDF;
	import crossbyte.crypto.SecureRandom;
	import haxe.io.Bytes;

	class ConnectTokens {
		// Connect tokens: made by the login service, checked by the game
		// servers, which share `secret` with it and with nobody else. A token
		// is 16 random bytes, the time it stops being good and the player's
		// name, under a MAC; the session's key is derived from the secret and
		// the token's random, a key of its own for every token.
		//
		// How long a token is good for, in seconds.
		public static inline var LIFETIME:Float = 30;

		// For the login service: a token for `player`, and the key its client
		// is to use.
		public static function issue(secret:Bytes, player:String):{token:Bytes, key:Bytes} {
			var name = Bytes.ofString(player);
			var signed:Int = 16 + 8 + name.length;
			var token = Bytes.alloc(signed + 16);
			token.blit(0, SecureRandom.getSecureRandomBytes(16), 0, 16);
			// time of day: the token is checked on other machines.
			token.setDouble(16, Sys.time() + LIFETIME);
			token.blit(24, name, 0, name.length);
			token.blit(signed, GenericHash.hash(token.sub(0, signed), macKey(secret), 16), 0, 16);
			return {token: token, key: sessionKey(secret, token)};
		}

		// For a game server: the player and key a token stands for; null for
		// one forged, cut short or out of date.
		public static function open(secret:Bytes, token:Bytes):Null<{player:String, key:Bytes}> {
			if (token.length < 16 + 8 + 16 || token.length > 16 + 8 + 64 + 16) {
				return null;
			}
			var signed:Int = token.length - 16;
			var mac:Bytes = GenericHash.hash(token.sub(0, signed), macKey(secret), 16);
			// time of day: as issue wrote it.
			if (!ConstantTime.equals(mac, token.sub(signed, 16)) || token.getDouble(16) < Sys.time()) {
				return null;
			}
			return {player: token.getString(24, signed - 24), key: sessionKey(secret, token)};
		}

		// Two keys from the one secret, neither of which can pass for the other.
		static function macKey(secret:Bytes):Bytes {
			return HKDF.sha256(secret, null, Bytes.ofString("connect-token mac"), 32);
		}

		static function sessionKey(secret:Bytes, token:Bytes):Bytes {
			return HKDF.sha256(secret, token.sub(0, 16), Bytes.ofString("session key"), 32);
		}
	}
	```

	The login service, once the player has signed in (over HTTPS, since
	the key in its answer is the session's secret):

	```haxe
	// Given secret:haxe.io.Bytes, player:String.
	var grant = ConnectTokens.issue(secret, player);
	var answer:String = haxe.Json.stringify({token: grant.token.toHex(), key: grant.key.toHex()});
	```

	A game server: `admit` drops a bad token without a word, and
	`encryptionKeyFor` gives a good one's session its key:

	```haxe
	// Given server:ReliableDatagramServerSocket, secret:haxe.io.Bytes.
	import crossbyte.io.ByteArray;

	server.admit = (address:String, port:Int, payload:ByteArray) -> ConnectTokens.open(secret, payload) != null;
	server.encryptionKeyFor = function(address:String, port:Int, payload:ByteArray):Null<haxe.io.Bytes> {
		var opened = ConnectTokens.open(secret, payload);
		return opened == null ? null : opened.key;
	};
	```

	And the client, with what the login service answered:

	```haxe
	// Given host:String, port:Int, token:String, key:String.
	import crossbyte.events.IOErrorEvent;
	import crossbyte.io.ByteArray;

	var socket = new ReliableDatagramSocket();
	socket.encryptionKey = haxe.io.Bytes.ofHex(key);
	// A refusal, or a key the server's does not match, ends the attempt
	// with an ioError that says which.
	socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> trace(e.text));
	socket.connect(host, port, ByteArray.fromBytes(haxe.io.Bytes.ofHex(token)));
	```

	A token crosses the network in the clear, in the CONNECT, so anyone who
	saw it can send it again within its 30 seconds, and gets nothing: the
	key is not in it, so a replayed token opens no session the replayer can
	use, and holds a pending slot until its attempt times out. A server
	that wants each token used once keeps the randoms of the last 30
	seconds (`crossbyte.ds.ExpiringMap`) and refuses one it has seen.

	What encryption protects, and what it does not: every message, and
	every acknowledgement, keepalive and FIN, is confidential and cannot be
	changed, replayed or forged undetected; the rebind proof is keyed with
	a key that is never sent (`allowRebind`). It does not hide who talks to
	whom, when, how often or how much (datagram sizes, timing, counts and
	packet numbers), nor the CONNECT and its token, which go in the clear;
	and there is no forward secrecy in this mode: whoever learns a key, or
	the servers' secret, can open what they recorded of the sessions it
	keyed. A reset from a server is not authenticated, so it does not end
	an encrypted session; a server that has lost one (restarted) is
	noticed at `idleTimeout`.

	@event close Dispatched when the server socket is closed.
	@event connect Dispatched when a session a peer opened completes its
	       handshake. A session this server dials, with `connect` or
	       `connectRelayed`, dispatches `Event.CONNECT` itself instead.
**/
class ReliableDatagramServerSocket extends EventDispatcher implements crossbyte.net._internal.DatagramReceiver implements crossbyte.core._internal.PassFlush {
	/**
		Indicates whether reliable UDP server sockets are supported by the current target.
	**/
	public static var isSupported(default, null):Bool = DatagramSocket.isSupported;

	/**
		Indicates whether the underlying UDP transport is currently bound.
	**/
	public var bound(get, never):Bool;

	/**
		Indicates whether the server is currently listening for reliable connection attempts.
	**/
	public var listening(default, null):Bool = false;

	/**
		The local IP address on which the server is bound.
	**/
	public var localAddress(get, never):String;

	/**
		The local UDP port on which the server is bound.
	**/
	public var localPort(get, never):Int;

	/**
		The mode applied to newly accepted `ReliableDatagramSocket` instances.
		Set this before calling `listen()`.
	**/
	public var socketMode:ReliableDatagramSocketMode = DATAGRAM;

	/**
		`ReliableDatagramSocket.keepAliveInterval` for each session this
		server accepts or dials, in seconds. Set it before the sessions it is
		for arrive; one already here keeps its own, which can be changed on it.
	**/
	public var keepAliveInterval:Float = ReliableDatagramSocket.DEFAULT_KEEP_ALIVE_INTERVAL;

	/**
		`ReliableDatagramSocket.idleTimeout` for each session this server
		accepts or dials, in seconds, as `keepAliveInterval` is.
	**/
	public var idleTimeout:Float = ReliableDatagramSocket.DEFAULT_IDLE_TIMEOUT;

	/**
		`ReliableDatagramSocket.ackDelay` for each session this server
		accepts or dials, in seconds (25 milliseconds unless changed), as
		`keepAliveInterval` is.

		@throws RangeError If set below zero or above
		        `ReliableDatagramSocket.MAX_ACK_DELAY`.
	**/
	public var ackDelay(default, set):Float = ReliableDatagramSocket.DEFAULT_ACK_DELAY;

	@:noCompletion private function set_ackDelay(value:Float):Float {
		if (!(value >= 0) || value > ReliableDatagramSocket.MAX_ACK_DELAY) {
			throw new RangeError('An acknowledgement delay is 0 to ${ReliableDatagramSocket.MAX_ACK_DELAY} seconds.');
		}
		return ackDelay = value;
	}

	@:noCompletion private var __closed:Bool = false;

	// A FIN, written once, for peers that send as though they had a session
	// here and have none.
	@:noCompletion private var __resetScratch:ByteArray;
	/** Half-open inbound sessions allowed at once. */
	public static inline var DEFAULT_MAX_PENDING_CONNECTIONS:Int = 256;

	/**
		Inbound sessions that may be waiting to finish a handshake at once,
		after which a CONNECT from an address with no session is dropped.
		Negative disables the check.

		A CONNECT costs the sender one datagram and costs this side a session
		holding two timers for `timeout` milliseconds, and UDP lets a sender
		write whatever it likes in the source field, so at that point nothing
		about the peer has been established. Without a ceiling one peer can
		spend a packet each on as many of these as it cares to, from addresses
		that never sent anything.

		Dropped rather than refused, because a refusal is itself a datagram to
		an address that may never have asked for one.

		CONNECTs from forged addresses could fill every slot on their own;
		`joinValidation` keeps them to `joinValidationThreshold` of them, and
		the rest for joins that show where they came from.
	**/
	public var maxPendingConnections:Int = DEFAULT_MAX_PENDING_CONNECTIONS;

	/** `joinValidationThreshold` unless changed. **/
	public static inline var DEFAULT_JOIN_VALIDATION_THRESHOLD:Int = 64;

	/**
		When a CONNECT from an address with no session must show it came from
		there before a session is opened for it: `UNDER_PRESSURE` unless
		changed, which is once `joinValidationThreshold` sessions are waiting
		to finish their handshakes; or `ALWAYS`, or `NEVER`.

		A session waiting for its handshake is held for the CONNECT's word
		alone (an address and port UDP lets a sender write for itself),
		so a few CONNECTs a second from forged addresses could keep all
		`maxPendingConnections` slots full, at about 13 a second for the
		default 256 held 20 seconds each, and no real player could join; an
		`admit` that checks tokens bound to the player's address stops that,
		and a server without them would have nothing. A join that must show where
		it came from is answered with a cookie instead, as a TCP stack
		answers with a SYN cookie: the server's keyed hash of the address,
		the port, the CONNECT's connection id and the time, for which it
		keeps nothing. Only a CONNECT that returns it within its time, from
		the address and port it was made for, goes on to `admit` and a
		session. A forged address never receives its cookie, so a flood of
		them holds no slot past the threshold, and a real join costs one
		more round trip. `maxPendingConnections` still bounds the sessions
		such joins open, and `admit` still decides on each.

		A cookie is no larger than the CONNECT it answers (a 1.0 peer pads
		its CONNECT to whatever may be sent back), so it gives a sender who
		names someone else's address nothing it could not send itself.

		While joins are validated, every CONNECT is answered with a cookie,
		without a limit, as SYN cookies, QUIC's Retry and DTLS's
		HelloVerifyRequest answer every attempt. So what a flood past the
		threshold costs the server is a keyed hash and a send per datagram
		(about 14 microseconds on Windows, where a CONNECT past
		`maxPendingConnections` is dropped for about 0.1), and that is the
		price of real players still joining during the flood. It
		is good for 10 to 20 seconds: the key it is made with is new every
		10 seconds, and the one before is still accepted. Within that time
		the same address, port and connection id can return it again, which
		opens nothing a CONNECT from there could not.

		A peer on 1.0 or later returns a cookie by itself. A peer from
		before 1.0 cannot: while joins are validated its CONNECTs are
		dropped, and it joins once fewer than the threshold are waiting
		(under `UNDER_PRESSURE`), or never (under `ALWAYS`). The keys come
		from the secure random source; on a target without one (neko,
		HashLink) from the ordinary one, which someone able to predict it
		could forge cookies with: hardening there, as the sequence numbers
		are, rather than a boundary.

		Read for each CONNECT, so a change takes effect at the next.
	**/
	public var joinValidation:JoinValidation = UNDER_PRESSURE;

	/**
		How many sessions may be waiting to finish their handshakes before a
		join must show where it came from, under `joinValidation`'s
		`UNDER_PRESSURE`: 64 unless changed, a quarter of the default
		`maxPendingConnections`, so a flood of forged CONNECTs holds at most
		that many slots and leaves the rest to joins that show they are
		real. 0 validates every join, as `ALWAYS` does. Keep it below
		`maxPendingConnections`, or the slots fill before it is reached.
	**/
	public var joinValidationThreshold:Int = DEFAULT_JOIN_VALIDATION_THRESHOLD;

	/**
		Whether a session follows its peer to a new address: off unless set.

		A session is found by its peer's address and port, so without this a
		player whose address changes is lost: a NAT that gives it a new port,
		a phone that moves from Wi-Fi to a mobile network. Its frames come
		from an address with no session, are answered with a reset, and the
		player is cut off and has to join again (or resume, as the class
		doc's "Resuming a player" shows).

		With this on, each session a peer on 1.0 or later opens is given a
		rebind key, 16 random bytes, in the server's HANDSHAKE (or, for an
		encrypted session, has one derived at both ends with its keys, which
		never crosses the network). When that
		peer's frames then arrive from an address with no session, the reset
		sent back carries a challenge: the server's keyed hash of the new
		address and port and the time, made like a join cookie, for which it
		keeps nothing. The peer's session, if it is live, does not close on
		it: it answers from its new address with a REBIND (its connection
		id, the challenge, and its keyed hash of the two with the session's
		key), and the server, finding all three right, moves the session
		there: in every map it is filed in, its relay path if it reached the
		peer through `relay`, and `remoteAddress` and `remotePort`, which
		read the new address from then on. The same session object goes on;
		what it sent while the peer could not be reached is sent again, as
		after any loss. In a test over a NAT that changed the client's port,
		traffic resumed a round trip after the client's first frame from the
		new port. Nothing on the client needs to be set: a 1.0 client always
		answers, and gives up after its `timeout` (20 s unless set), closing
		with an `ioError` that says the rebind failed. `admit` is not asked
		again; a rebind is the same session, at another address.

		Refused, with the session left where it was: a wrong proof; a
		challenge made for another address or port, or more than 10 to 20
		seconds old; a session not yet connected, or closing; and more than
		one move a second for a session. A REBIND for a session already at
		the address it came from moves nothing and is answered, harmlessly.
		The server checks at most 16 REBINDs a pass, so a flood of forged
		ones costs a lookup each and little more; a peer whose session is
		gone is told with a reset that carries no challenge.

		**Without encryption, the key is only as secret as the HANDSHAKE.**
		It crosses the network in the clear, so anyone on the path when the
		session began can later move it to an address of their own, taking
		over what the server sends the player. Turn this on with encryption
		(`ReliableDatagramSocket.encryptionKey`), where the proof is keyed
		with the session's own rebind key (derived with HKDF from the
		application's key and both ends' randoms, sent by neither side, so
		someone who saw the whole handshake still cannot make it), or for a
		game whose players' paths nobody hostile shares. Encrypted, the
		session's datagrams are sealed wherever it moves; the REBIND, the
		REBOUND and the reset's challenge stay in the clear, as they are without it, and
		say nothing a sealed datagram would hide. And every reset carries a
		challenge while this is on, made per reset within
		`maxResetsPerSecond`.

		Only reliable UDP can do this. A TCP connection, and a WebSocket over
		one, is its addresses and ports: when either changes the connection
		is gone, and the player reconnects and resumes, as the class doc
		shows. That is also the fallback here, for a peer from before 1.0 or
		a server without this.

		It costs nothing while off, and no session accepted while it was off
		gets a key; set it before `listen`. On, a session holds its 16-byte
		key and an entry in a map by connection id; nothing per packet. On a
		target with no secure random source (neko, HashLink) no session
		is given a key, since one guessed would let anyone move it.
	**/
	public var allowRebind(default, set):Bool = false;

	@:noCompletion private function set_allowRebind(value:Bool):Bool {
		if (!value) {
			// Nothing kept for a feature that is off.
			__byConnectionId = null;
		}
		return allowRebind = value;
	}

	// The sessions that may rebind, by their peers' connection ids: what a
	// REBIND names. Kept only while rebinding is allowed.
	@:noCompletion private var __byConnectionId:haxe.ds.IntMap<ReliableDatagramSocket> = null;

	// REBINDs checked this pass, and whether this server has asked to be
	// told when the pass ends.
	@:noCompletion private var __rebindChecks:Int = 0;

	/** The most REBINDs a server checks in one pass of its runtime's loop. **/
	@:noCompletion private static inline var MAX_REBIND_CHECKS_PER_PASS:Int = 16;

	/** The least time between two moves of one session, in seconds. **/
	@:noCompletion private static inline var MIN_REBIND_INTERVAL:Float = 1.0;

	/** What a rebind challenge's hash starts with, so it can pass for no other. **/
	@:noCompletion private static inline var CHALLENGE_DOMAIN:Int = 0x42;

	/** `maxResetsPerSecond` unless changed. **/
	public static inline var DEFAULT_MAX_RESETS_PER_SECOND:Int = 1000;

	/**
		How many resets every reliable datagram server in this process may
		send, together, in a second: 1,000 unless changed. Negative is no
		limit, and 0 sends none.

		A reset is the FIN a server answers a frame with when it holds no
		session for the address the frame came from (a peer whose session
		it closed, a server that restarted, a player whose address changed).
		Each is a datagram to an address that has proved
		nothing, since UDP lets a sender write whatever it likes in the
		source field; it is no larger than the frame that drew it, but one
		for every such frame, however many came, would let a server be made
		to send as many datagrams as it was sent to whoever an attacker
		named. Past the allowance a frame is dropped unanswered, and its
		sender, if it is a real peer, hears at its next frame, or at its own
		`idleTimeout`.

		One allowance for the process, shared by every server in it on every
		runtime: it holds up to one second's worth and fills at this rate, so
		a burst of resets after a restart goes out at once and a flood gets
		no more than this. At 1,000 that is at most about 35 KB a second of
		7-byte frames and their headers. Read whenever a reset is due, so a
		change takes effect at the next one.
	**/
	public static var maxResetsPerSecond:Int = DEFAULT_MAX_RESETS_PER_SECOND;

	/**
		The operating system's receive buffer, in bytes, for the one socket
		every session of this server reads from; see
		`DatagramSocket.receiveBufferSize`. At least
		`ReliableDatagramSocket.WINDOW_BUFFER_SIZE` where the system grants it,
		which is one window: a server whose peers send at once may want room
		for several.
	**/
	public var receiveBufferSize(get, set):Int;

	/**
		The operating system's send buffer, in bytes, for this server's socket;
		see `DatagramSocket.sendBufferSize`.
	**/
	public var sendBufferSize(get, set):Int;

	@:noCompletion private inline function get_receiveBufferSize():Int {
		return __socket != null ? __socket.receiveBufferSize : 0;
	}

	@:noCompletion private function set_receiveBufferSize(value:Int):Int {
		return __socket.receiveBufferSize = value;
	}

	@:noCompletion private inline function get_sendBufferSize():Int {
		return __socket != null ? __socket.sendBufferSize : 0;
	}

	@:noCompletion private function set_sendBufferSize(value:Int):Int {
		return __socket.sendBufferSize = value;
	}

	/**
		Decides whether a CONNECT from an address with no session opens one,
		from the address and what the sender's `connect` passed with it. Called
		before anything is allocated for it; return `false` and the datagram is
		dropped, as it is when `maxPendingConnections` is reached. The default
		admits everything.

		The payload is empty when the sender passed nothing, as a peer on an
		older build always does. It is read from its start, and whatever this
		reads, the admitted session's `connectPayload` begins at the start
		again. A CONNECT carrying more than one frame's worth is dropped
		without asking, since no `connect` can send one.

		The payload is valid only during the call, as an event's is: it is
		the datagram's own bytes, which the socket fills with the next one.
		Copy what you need; the admitted session keeps a copy of its own as
		`connectPayload`. See `Event`.

		Neither is proof of anything yet. The address is only a claim (UDP
		lets a sender write whatever it likes in the source field), so use it
		to drop traffic, not to accuse anyone: a block list or a `RateLimiter`
		keyed by address protects this side, but an address refused here may
		belong to someone who never sent a thing. And the payload crossed the
		network in the clear, so anyone who saw it can send it again: a token
		this checks should be one only this side could have issued, and short
		lived, or bound to the address it was issued to. This runs for every
		CONNECT from a new address, which is the packet a flood is made of
		(while joins are validated, see `joinValidation`, only for one that
		has returned its cookie, and so shown it receives at that address),
		so keep it cheap, or put a `RateLimiter` in front of anything that is
		not, such as checking a signature.

		A hook that throws refuses the CONNECT.
	**/
	public dynamic function admit(address:String, port:Int, payload:ByteArray):Bool {
		return true;
	}

	/**
		The 32-byte key a session this server accepts is encrypted with, or
		null (the default) for a session in the clear: asked once for each
		CONNECT `admit` lets in, with the same address, port and payload, the
		payload read from its start again. See
		`ReliableDatagramSocket.encryptionKey` for what encryption protects,
		and what it does not.

		CrossByte does no key exchange: the application decides each
		session's key and gives the client the same one, typically through a
		login service that hands the client a key and a connect token over
		HTTPS. The token is the client's `connect` payload, and this derives
		the key from it (with `crossbyte.crypto.HKDF` and a secret only the
		servers hold), or unwraps it (`crossbyte.crypto.Aead`). "Encrypted
		sessions", in the class doc above, shows the login service, the
		server and the client.

		It fails closed, either way round. A CONNECT asking for encryption
		that this answers with null, and one asking for none that this gives
		a key, open no session: the peer is told why with a refusal, which a
		peer on this version reports as an `ioError` naming the reason, and
		an older one times out. Return a key for
		every session of a server that only takes encrypted ones.

		Like `admit`, this runs for every CONNECT from a new address that
		gets this far, so keep it cheap: derive, don't look anything up that
		can stall. The payload is valid only during the call, as `admit`'s
		is. A hook that throws, or returns a key that is not 32 bytes,
		refuses the CONNECT without a word, as `admit` returning `false`
		does. The key is copied; the hook may wipe its own.

		On a target where sessions cannot be encrypted
		(`ReliableDatagramSocket.isEncryptionSupported`) a key refuses the
		CONNECT, as one asked for and not given does.
	**/
	public dynamic function encryptionKeyFor(address:String, port:Int, payload:ByteArray):Null<haxe.io.Bytes> {
		return null;
	}

	/**
		The congestion policy for a session this server accepts or dials,
		given the peer's address and port: a new `CongestionControl` each,
		which is TCP's Reno, unless this is replaced. A server that knows some
		of its peers are on lossy links (a mobile network, say) can give
		those a `LossTolerantCongestionControl` and everyone else the default.
		`null` means the default.

		Called once a session, before its handshake. Return a new instance
		each time: a policy keeps the state of the one session it serves. For
		an accepted session a hook that throws refuses the CONNECT, as `admit`
		does; for one dialled by address the throw reaches the caller of
		`connect`, and for one dialled by name (asked about once the name is
		looked up), it is reported as that session's `ioError`, and the
		session closed.
		A session's policy can also be changed later, through
		`ReliableDatagramSocket.congestionControl`, once the peer has said
		in its `connectPayload` what kind of link it is on, for instance.
	**/
	public dynamic function congestionControlFor(address:String, port:Int):CongestionControl {
		return new CongestionControl();
	}

	@:noCompletion private var __connections:StringMap<ReliableDatagramSocket>;

	// Sessions dialled by name whose names are still being looked up. They
	// have no endpoint to be filed under in `__connections` until the answer
	// comes, and are kept here meanwhile so that close() reaches them.
	@:noCompletion private var __dialling:Array<ReliableDatagramSocket> = null;

	// Keys of accepted sessions that have not finished handshaking. Counted
	// alongside rather than measured, because measuring means walking the
	// map on every CONNECT, which is the packet a flood sends most of.
	@:noCompletion private var __pending:StringMap<Bool>;
	@:noCompletion private var __pendingCount:Int = 0;

	// One outstanding reflexive-address query, if any. Held here rather than in
	// a client of its own because the question is about this socket's port, and
	// only this class can ask from it.
	/**
		The question outstanding, if one is: its transaction, its schedule, and
		how to read a reply. See `StunQuery`, which the other two places that
		ask a STUN server share.
	**/
	@:noCompletion private var __stunQuery:StunQuery;

	@:noCompletion private var __stunFuture:Future<ReflexiveAddress>;
	@:noCompletion private var __stunTick:TickEvent->Void;

	// An attached agent, and the tick that moves its clock. Separate from the
	// reflexive query above: that one asks a server a single question, this one
	// runs an exchange with a peer for as long as it takes.
	@:noCompletion private var __ice:IceAgent;

	/**
		The runtime this server's ticks run on (an attached agent's, a
		relay's, a waiting question's), which its socket took when it began
		receiving, as each of them needs it to have, rather than whichever
		runtime is current, so a close from another thread can take them
		off.
	**/
	@:noCompletion private function __tickRuntime():CrossByte {
		var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
		return runtime != null ? runtime : CrossByte.current();
	}

	/**
		Takes one of this server's tick listeners off its runtime, from
		wherever this is called: it does not throw on a thread with no
		runtime, as asking for the current one did.
	**/
	@:noCompletion private function __untick(listener:TickEvent->Void):Void {
		var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
		if (runtime == null) {
			runtime = CrossByte.__currentOrNull();
		}
		if (runtime != null) {
			runtime.removeEventListener(TickEvent.TICK, listener);
		}
	}

	@:noCompletion private var __iceTick:TickEvent->Void;
	@:noCompletion private var __socket:DatagramSocket;

	/**
		Offered every datagram that arrives, before anything else here looks at
		it, with where it came from; return `true` to take it, and nothing else
		sees it. Null by default, which costs nothing.

		For a protocol of the application's own sharing this port (a relay
		client it drives itself, a probe, a second framing), whose datagrams
		would otherwise go to the reliable decoder and be dropped as noise.
		`sendDatagram` is the way out.

		`data` is valid only during the call, as an event's payload is,
		whether the hook takes the datagram or not: the socket fills the same
		`ByteArray` with the next one. To handle it later, copy the bytes out
		(`data.readBytes(mine)`) before returning. See `Event`.

		A hook that throws drops the datagram.
	**/
	public var onDatagram:Null<(data:ByteArray, address:String, port:Int) -> Bool> = null;

	/**
		The TURN relay this server reaches peers through, once `allocateRelay`
		has asked for one; null before that, and once it is released or lost.
	**/
	public var relay(default, null):Null<TurnClient> = null;

	/**
		The address the relay lent, as an ICE candidate: what to tell a peer
		that can reach this server only through the relay. Null until the relay
		has lent one.
	**/
	public var relayedCandidate(default, null):Null<IceCandidate> = null;

	#if !(macro || (js && !nodejs))
	/**
		For a relay `allocateRelay` reaches over TLS: the authority its
		certificate must chain to, where that is not one the system trusts:
		a private relay's own. Read when `allocateRelay` is called. See
		`TurnClient.certAuthority`.
	**/
	public var relayCertAuthority:Null<Certificate> = null;
	#end

	/**
		For a relay `allocateRelay` reaches over TLS: whether its certificate
		is checked, which it is unless this is turned off. Turn it off for a
		test against a relay with a throwaway certificate, never otherwise,
		and prefer `relayCertAuthority` even then. Read when `allocateRelay`
		is called. See `TurnClient.verifyCert`.
	**/
	public var relayVerifyCert:Bool = true;

	@:noCompletion private var __relayTick:TickEvent->Void = null;

	/** The connection `relay` reaches its server over, when that is TCP; null over UDP. **/
	@:noCompletion private var __relayStream:TurnStream = null;

	/** How the attached agent sends from `relayedCandidate`. **/
	@:noCompletion private var __relaySend:(ByteArray, String, Int) -> Void = null;

	/**
		Creates a new reliable datagram server socket.
	**/
	public function new() {
		super();

		__connections = new StringMap();
		__pending = new StringMap();
		__socket = new DatagramSocket();
		ReliableDatagramSocket.__reserveWindow(__socket);
	}

	/**
		Binds the server to a local UDP address and port.
		@param localPort The local port to bind to. Use `0` to allow the operating system to choose a free port.
		@param localAddress The local address to bind to. Use `"0.0.0.0"` to bind on all IPv4 interfaces.
		@throws IOError If the server has already been closed or the bind fails.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__socket.bind(localPort, localAddress);
	}

	/**
		Stops listening, ends every reliable session at once, as
		`ReliableDatagramSocket.abort()` does, and closes the underlying UDP
		transport.

		Each session sends what it had gathered, then a FIN that ends its
		peer's session the moment it arrives; what was still waiting for the
		window, or lost and not yet sent again, is dropped. The sessions share
		this server's socket, which goes with this call, so none can wait for
		its peer. For a graceful shutdown `close()` the sessions first and
		close the server once each has dispatched `close`.

		It may be called from any thread: from one that is not the server's
		runtime's, it is handed to the runtime, as `CrossByte.post` hands work
		over, and happens there after this returns, so the ticks it ran
		come off the runtime they were on.
	**/
	public function close():Void {
		if (__closed) {
			return;
		}

		var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
		if (RuntimeHandOff.offThread(runtime) && runtime.post(close)) {
			return;
		}

		__closed = true;
		listening = false;
		try {
			if (__socket.__receiver == this) {
				__socket.__setReceiver(null);
			}
		} catch (_:Dynamic) {}

		__settleStun(null, "The server socket closed before the STUN server replied.");
		detachIceAgent();

		var connections:Array<ReliableDatagramSocket> = [];
		for (connection in __connections) {
			connections.push(connection);
		}
		// And those still looking their peer's name up, which are this
		// server's as much, though filed under no endpoint yet.
		if (__dialling != null) {
			for (connection in __dialling) {
				connections.push(connection);
			}
			__dialling = null;
		}
		__connections = new StringMap();
		__byHost = new StringMap();
		__byHostCount = new StringMap();
		__pending = new StringMap();
		__pendingCount = 0;
		__byConnectionId = null;

		// Aborted, not just disposed: abort() tells the peer, so a client of
		// a server that shuts down hears at once rather than sending into a
		// closed port until its own timeout. And not closed gracefully,
		// which would wait on the socket this call is about to close.
		for (connection in connections) {
			try {
				connection.abort();
			} catch (_:Dynamic) {}
		}

		// After the sessions, whose FINs a relayed one sends through it, and
		// before the socket, which carries the relay's own goodbye.
		if (relay != null) {
			var released = relay;
			__dropRelay();
			released.close();
		}

		try {
			__socket.close();
		} catch (_:Dynamic) {}
		dispatchEvent(new Event(Event.CLOSE));
	}

	/**
		Begins listening for reliable UDP connection attempts on the bound transport.
		Incoming handshakes that complete successfully dispatch
		`ReliableDatagramSocketConnectEvent.CONNECT`.
		@throws IOError If the server is closed or has not been bound yet.
	**/
	public function listen():Void {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (!bound) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (listening) {
			return;
		}

		listening = true;
		// Handed each datagram directly, with no event made for it.
		__socket.__setReceiver(this);
		__socket.receive();
	}

	/**
		Opens a reliable session to `address`:`port` from the port this server is
		already bound to.

		The distinction from `ReliableDatagramSocket.connect` is the local port.
		That call makes its own transport and so leaves from an arbitrary port;
		this one leaves from the one peers already reach this server on. For a
		peer-to-peer mesh that difference is the whole thing: hole punching
		works only when the port a peer dials out from is the port it is
		reachable on, and a NAT will only hold that mapping open for one socket.

		The returned session is registered with this server, so its replies
		arrive through the same data pump that feeds accepted sessions, and it
		takes `socketMode` as an accepted one does. It is not announced with
		`ReliableDatagramSocketConnectEvent.CONNECT`, which is for sessions a
		peer opened (the caller holds this one already), and dispatches
		`Event.CONNECT` itself when the handshake completes, as a
		`ReliableDatagramSocket` that called `connect()` does. Listen for that
		on the returned session.

		Requires `listen()`: the server's pump is what routes the replies, so a
		session dialled from a bound-but-not-listening server would send its
		handshake and never hear the answer.

		`address` may be a name everywhere but Node, and it is not looked up
		on the runtime's thread: the session is returned at once, and filed
		under the address the name resolves to, its handshake begun, when the
		answer comes. Until then its `remoteAddress` reads empty; its timeout
		counts the lookup. What this call throws for an address it reports on
		such a session instead, as an `ioError` event followed by the
		session's close: a name that does not resolve, an endpoint that has a
		session here already, and a `congestionControlFor` that throws. On a
		thread with no CrossByte runtime a name is looked up in the call.

		@param address The peer's address, or a name.
		@param timeoutMs The session's `timeout`, in milliseconds: how long
		       the handshake may take. 20 seconds unless given; 0 sets no
		       deadline, as it does for the session's own `timeout`, and the
		       attempt goes on until the peer answers or the session is
		       closed.
		@param payload Sent with every CONNECT, as `ReliableDatagramSocket.connect`
		       sends it: copied now, and at most one frame
		       (`ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE` with a key).
		@param encryptionKey The session's key, as
		       `ReliableDatagramSocket.encryptionKey` takes it, for a session
		       encrypted from its first sealed datagram; null for one in the
		       clear. Copied now.
		@throws IOError if this server is closed, unbound, or not listening.
		@throws ArgumentError if the address is malformed, or, on Node, a
		name, or if a session to this endpoint already exists, or the key is
		not 32 bytes.
		@throws crossbyte.errors.IllegalOperationError if given a key on a
		target that cannot encrypt (`ReliableDatagramSocket.isEncryptionSupported`).
		@throws RangeError if `payload` is larger than one frame, or
		`timeoutMs` is negative.
	**/
	public function connect(address:String, port:Int, timeoutMs:Int = ReliableDatagramSocket.DEFAULT_TIMEOUT, ?payload:ByteArray,
			?encryptionKey:haxe.io.Bytes):ReliableDatagramSocket {
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__checkTimeout(timeoutMs);
		__checkKey(encryptionKey);

		if (!bound) {
			throw new IOError("Cannot dial from a server socket that is not bound.");
		}

		if (!listening) {
			throw new IOError("Cannot dial from a server socket that is not listening: replies are routed by the listen pump, so nothing would deliver them.");
		}

		var outgoing:ByteArray = ReliableDatagramSocket.__connectPayloadOf(payload, encryptionKey != null);

		var resolved:String;

		#if nodejs
		// Same rule the socket's own connect() states: a session is matched
		// against the address replies arrive from, and resolving a name on Node
		// needs a callback this call cannot wait for.
		if (!IPv6.isNumericAddress(address)) {
			throw new ArgumentError("A reliable datagram session needs a numeric address on Node, not a name: the session is matched against the address replies arrive from, and resolving a name there needs a callback this call cannot wait for.");
		}

		resolved = address;
		#else
		// Without a runtime on this thread there is nothing to hand an answer
		// back to, so a name is looked up here.
		if (Resolver.needsLookup(address) && Resolver.runtimeHere() != null) {
			return __dialByName(address, port, timeoutMs, outgoing, encryptionKey);
		}

		try {
			// Compressed, as the address arrives from the socket and as a dial
			// by name files it: the jvm spells ::1 as 0:0:0:0:0:0:0:1, and a
			// session filed that way would never be found by the peer's replies.
			resolved = IPv6.compress(new Host(address).toString());
		} catch (_:Dynamic) {
			throw new ArgumentError("One of the parameters is invalid");
		}
		#end

		var key:String = __endpointKey(resolved, port);

		// Refused rather than replaced. A second session to an endpoint that
		// already has one would take over its routing entry and strand the
		// first, which is a difficult thing to notice from the outside.
		if (__connections.exists(key)) {
			throw new ArgumentError("A reliable datagram session to " + key + " already exists on this server.");
		}

		var socket = ReliableDatagramSocket.__createDialed(__socket, resolved, port, this, socketMode, timeoutMs, outgoing,
			congestionControlFor(resolved, port), null, encryptionKey);
		__file(resolved, port, socket);
		return socket;
	}

	/**
		Sends `message` to every session this server has connected (those
		peers opened and those it dialled) or, given `sessions`, to each of
		those that is connected: one message made ready once (see
		`PreparedDatagram`), which each session frames, paces, bundles and
		sends again as `ReliableDatagramSocket.sendPrepared` would, from the
		same bytes, holding no copy of its own. Who receives (a room, a
		team, an area of interest) is the application's to say with
		`sessions`.

		Nothing is thrown for one session. One not connected, closing, or in
		`STREAM` mode is passed over; one the message takes past its
		`maxOutputBufferSize` under the `THROW` `outputOverflowPolicy` is
		sent it and not thrown for (its `bufferedAmount` says what waits),
		and one under `CLOSE` is ended, as `send` would end it. A session
		that closes during the broadcast is passed over, and the others are
		each sent the message once.

		`sessions` may hold sessions of other servers, and sockets that
		connected on their own: each is sent the message as `sendPrepared`
		sends it, on the calling thread. A prepared message is never changed
		once made, so sessions on other runtimes may be sent it at the same
		time, each from its own.

		@param message The message, made with `PreparedDatagram.of`.
		@param sessions Who to send it to; every session this server has
		       connected when `null`.
		@param delivery `RELIABLE` unless given. An unreliable or sequenced
		       message must fit one frame of every session it goes to.
		@throws ArgumentError If `message` is `null`.
		@throws RangeError If `delivery` is unreliable or sequenced and the
		        message is larger than one frame of a session it would go
		        to (1,200 bytes, 1,179 for an encrypted one), before it is
		        sent to any.
	**/
	public function broadcast(message:PreparedDatagram, ?sessions:Array<ReliableDatagramSocket>, delivery:DeliveryMode = DeliveryMode.RELIABLE):Void {
		if (message == null) {
			throw new ArgumentError("broadcast needs a message.");
		}
		var source:Array<ReliableDatagramSocket> = sessions != null ? sessions : __sessionList;
		var count:Int = source.length;
		// Too large for a session it would go to: said before any is sent it.
		if (delivery != DeliveryMode.RELIABLE && message.length > ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE) {
			for (i in 0...count) {
				var session:ReliableDatagramSocket = source[i];
				if (__takesPrepared(session) && message.length > session.maxPayloadSize) {
					throw new RangeError('An unreliable message must fit one frame of each session it goes to: ${session.maxPayloadSize} bytes for '
						+ '${session.encrypted ? "an encrypted" : "a"} session, and this one is ${message.length}; split it, or send it RELIABLE.');
				}
			}
		}

		// From a list of this call's own: a session closing as it is sent to
		// (past its output limit, or a close listener closing another)
		// comes off the server's list, whose last session takes its place,
		// and would be sent to twice or passed over. The list is kept for the
		// next broadcast; one inside another, from a close listener, takes a
		// copy.
		var nested:Bool = __broadcasting;
		var list:Array<ReliableDatagramSocket> = nested ? source.copy() : __broadcastList;
		if (!nested) {
			for (i in 0...count) {
				list[i] = source[i];
			}
			__broadcasting = true;
		}
		try {
			for (i in 0...count) {
				var session:ReliableDatagramSocket = list[i];
				if (__takesPrepared(session)) {
					session.__sendPreparedNow(message, delivery);
					if (delivery == DeliveryMode.RELIABLE) {
						session.__enforceOutputLimit(false);
					}
				}
			}
		} catch (e:Dynamic) {
			__broadcastDone(nested, count);
			Arrivals.rethrow(e);
		}
		__broadcastDone(nested, count);
	}

	/** Whether a session can be sent a prepared message now, as `sendPrepared` would refuse to. **/
	@:noCompletion private static inline function __takesPrepared(session:Null<ReliableDatagramSocket>):Bool {
		return session != null && !session.__closed && !session.__closing && session.__connected && session.__transport != null
			&& session.__mode == DATAGRAM;
	}

	@:noCompletion private inline function __broadcastDone(nested:Bool, count:Int):Void {
		if (!nested) {
			// Let go of, so a session that closed is not kept by the list.
			var list:Array<ReliableDatagramSocket> = __broadcastList;
			for (i in 0...count) {
				list[i] = null;
			}
			__broadcasting = false;
		}
	}

	// Every session filed here, each at the index it holds
	// (`ReliableDatagramSocket.__listedAt`): what a broadcast walks, rather
	// than the map, which would have it build a list of the keys (natively
	// a copy of all of them) every broadcast. And the list a broadcast walks,
	// kept from one to the next, and whether one is walking it.
	@:noCompletion private var __sessionList:Array<ReliableDatagramSocket> = [];
	@:noCompletion private var __broadcastList:Array<ReliableDatagramSocket> = [];
	@:noCompletion private var __broadcasting:Bool = false;

	/** Takes a session out of `__sessionList`, its last taking its place. **/
	@:noCompletion private function __delist(socket:ReliableDatagramSocket):Void {
		var at:Int = socket.__listedAt;
		socket.__listedAt = -1;
		if (at < 0 || at >= __sessionList.length || __sessionList[at] != socket) {
			return;
		}
		var last:ReliableDatagramSocket = __sessionList.pop();
		if (last != socket) {
			__sessionList[at] = last;
			last.__listedAt = at;
		}
		__shareReads();
	}

	/**
		Refuses a key for a dialled session that is not one, or on a target
		that cannot encrypt, as `ReliableDatagramSocket.encryptionKey` does,
		before anything is made for it.
	**/
	@:noCompletion private static function __checkKey(key:Null<haxe.io.Bytes>):Void {
		if (key == null) {
			return;
		}
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			throw new crossbyte.errors.IllegalOperationError('Reliable UDP sessions cannot be encrypted on ${ReliableDatagramSocket.__targetName()}; see ReliableDatagramSocket.isEncryptionSupported.');
		}
		if (key.length != SessionCipher.KEY_SIZE) {
			throw new ArgumentError('An encryption key is ${SessionCipher.KEY_SIZE} bytes, and this one is ${key.length}.');
		}
	}

	/**
		Refuses a negative timeout for a dialled session, as its `timeout`
		does, before anything is made for it.
	**/
	@:noCompletion private static inline function __checkTimeout(timeoutMs:Int):Void {
		if (timeoutMs < 0) {
			throw new RangeError("Invalid socket timeout specified.");
		}
	}

	#if !nodejs
	/**
		`connect()` to a name: the session is made and returned now, and the
		name looked up off the runtime's thread (see `Resolver`); the session
		is filed under the address it resolves to, and its handshake begun,
		when the answer comes.

		Not looked up in the call, where every session this server carries
		would wait on the resolver (a second, for a name that does not
		exist). What the call would refuse by throwing it reports on the
		session, which it has already handed over: a name that
		does not resolve, an endpoint with a session here already, and a
		`congestionControlFor` that throws, each asked about only once the
		address is known.
	**/
	@:noCompletion private function __dialByName(name:String, port:Int, timeoutMs:Int, outgoing:ByteArray, encryptionKey:Null<haxe.io.Bytes>):ReliableDatagramSocket {
		var socket = ReliableDatagramSocket.__createDialed(__socket, null, port, this, socketMode, timeoutMs, outgoing, null, null, encryptionKey);
		if (__dialling == null) {
			__dialling = [];
		}
		__dialling.push(socket);

		Resolver.resolve(name, function(host:Null<Host>, failure:Null<String>):Void {
			// Closed meanwhile (the session, the server with it, or the
			// attempt at its deadline), and taken off the list then.
			if (__dialling == null || !__dialling.remove(socket)) {
				return;
			}

			if (host == null) {
				__refuseDialled(socket, "Could not connect to " + name + ": the name did not resolve (" + failure + ")");
				return;
			}

			// As the address arrives from the socket, so the session is found
			// by it.
			var resolved:String = IPv6.compress(host.toString());
			var key:String = __endpointKey(resolved, port);
			if (__connections.exists(key)) {
				__refuseDialled(socket, "Could not connect to " + name + ": a reliable datagram session to " + key + " already exists on this server.");
				return;
			}

			var congestion:CongestionControl = null;
			try {
				congestion = congestionControlFor(resolved, port);
			} catch (e:Dynamic) {
				__refuseDialled(socket, "Could not connect to " + name + ": congestionControlFor threw " + Std.string(e));
				return;
			}

			__file(resolved, port, socket);
			socket.__beginDialled(resolved, congestion);
		});

		return socket;
	}

	/**
		Tells a session dialled by name why it cannot go ahead, and closes it.
		Its address is never set, so closing it disturbs no session filed under
		the endpoint it would have had.
	**/
	@:noCompletion private static function __refuseDialled(socket:ReliableDatagramSocket, reason:String):Void {
		socket.dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, reason));
		socket.__dispose(true);
	}
	#end

	/**
		Asks a STUN server what address and port this server appears as from
		outside.

		The answer is about *this* socket, which is the only reason this lives
		here rather than in a client of its own. A NAT holds one mapping per
		socket, so a reflexive address discovered on some other port describes
		somewhere nobody can reach this server, and the port peers dial is
		this one. `StunClient` binds its own socket and answers the more general
		"what is my public address"; this answers "where can I be reached", and
		for a peer-to-peer mesh only the second one is actionable.

		The request goes out through the bound socket and the reply is picked
		out of ordinary inbound traffic by its transaction id, so an ongoing
		query costs no extra socket and does not disturb any session.

		One at a time: a second call while one is outstanding is refused rather
		than queued, because the two would race for the same reply.

		`server` may be a name. It is looked up off the runtime's thread
		before the question is asked, within `timeoutMs`, and a name that does
		not resolve fails the question as soon as that is known. On Node, Node
		looks the name up for each request itself, and one that does not
		resolve leaves the question to its deadline.

		`timeoutMs` is how long to keep asking. 0 or less sets no deadline, as
		it does for a connection's `timeout`: the question is asked until it
		is answered or this server closes, since nothing else ends a question
		over UDP that nobody answers.

		@return The address and port this socket appears as, or a failure. A
		       question that cannot be asked is not thrown but returned
		       failed already: for a server closed, unbound or not listening,
		       its `cause` an `IOError`; for a `server` left empty, an
		       `ArgumentError`; and with no cause for a second question while
		       one is outstanding, or a target with no secure random source.
	**/
	public function discoverPublicAddress(server:String, port:Int = 3478, timeoutMs:Int = 3000):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		if (__closed || !bound || !listening) {
			@:privateAccess future.__fail("A reflexive address can only be discovered from a bound, listening server socket.",
				new IOError("Operation attempted on invalid socket."));
			return future;
		}

		if (server == null || server == "") {
			@:privateAccess future.__fail("A STUN server address is required.", new ArgumentError("server"));
			return future;
		}

		if (__stunFuture != null) {
			@:privateAccess future.__fail("A reflexive address query is already outstanding on this server socket.", null);
			return future;
		}

		// The transaction id is what the reply will be believed by, and a weak
		// one would let an off-path party who can guess it answer with an
		// address of its choosing. Refusing beats falling back: this target
		// still runs the reliable protocol (its sequence seeds degrade
		// deliberately, being hardening rather than the security boundary)
		// but discovery's answer is only worth having if it cannot be forged.
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			@:privateAccess future.__fail("Discovering a public address needs a cryptographically secure random source for the "
				+ "STUN transaction id, which this target does not have.", null);
			return future;
		}

		var query = new StunQuery(haxe.Timer.stamp(), timeoutMs);
		__stunQuery = query;
		__stunFuture = future;

		var runtime:CrossByte = __tickRuntime();

		// Where the question goes: `server`, or for a name the address it
		// resolves to, null until then. Looked up here rather than by the
		// send, so a name that does not resolve fails this question at once,
		// not as an ioError on the socket every session shares, which tells
		// this question nothing.
		var target:Null<String> = server;
		#if !nodejs
		if (Resolver.needsLookup(server)) {
			target = null;
		}
		#end

		function ask():Void {
			var payload:ByteArray = query.request.encode();
			__socket.send(payload, 0, payload.length, target, port);
		}

		__stunTick = function(_:TickEvent):Void {
			if (__stunFuture == null) {
				return;
			}

			var now:Float = haxe.Timer.stamp();

			if (query.expired(now)) {
				// UDP reports nothing when it is dropped, so a silent network
				// and a wrong server address look identical from here; the
				// deadline is the only thing that ends this, short of a close.
				// Only a question with a deadline gets here.
				var damage:Null<String> = query.damage();
				__settleStun(null, (damage != null ? "No usable reply" : "No reply") + " from the STUN server at " + server + ":" + port + " within "
					+ query.timeoutMs + "ms" + (damage != null ? ": " + damage + "." : "."));
				return;
			}

			// Nothing to ask again before the name is looked up.
			if (target != null && query.shouldRetransmit(now)) {
				try {
					ask();
				} catch (e:Dynamic) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
				}
			}
		};

		runtime.addEventListener(TickEvent.TICK, __stunTick);

		#if !nodejs
		if (target == null) {
			Resolver.resolve(server, function(host:Null<Host>, failure:Null<String>):Void {
				// Settled meanwhile (at its deadline, or with the server),
				// or a later question asked since.
				if (__stunQuery != query) {
					return;
				}

				if (host == null) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: the name did not resolve (" + failure + ")");
					return;
				}

				target = host.toString();
				try {
					ask();
				} catch (e:Dynamic) {
					__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
				}
			});
			return future;
		}
		#end

		try {
			ask();
		} catch (e:Dynamic) {
			__settleStun(null, "Could not ask " + server + ":" + port + " for a reflexive address: " + Std.string(e));
		}

		return future;
	}

	/**
		The address a peer at `destination` would reach this server on, without
		leaving the local network.

		The other candidate a peer can offer, and the one `discoverPublicAddress`
		cannot produce. Two peers behind the same NAT discover reflexive
		addresses on its outside, and dialling those means asking the NAT to
		route a packet back in to the network it came from (hairpinning), which
		plenty of consumer equipment does not do. They are usually sitting on the
		same subnet, one hop apart, and the address that works is the local one.

		Unlike the reflexive answer this needs nothing on the network and no
		server: it is a routing table lookup, and the socket it asks with sends
		no packet. `destination` need not even be reachable.

		The port is not part of the answer, and that absence is the point. A
		reflexive address comes back with a translated port because a NAT
		assigned one; nothing translates a local address, so the port a peer
		should dial is `localPort` and no query is needed to learn it.

		@param destination The peer's address, numeric. Which one it is matters:
		a peer on this subnet and a peer across the internet are reached on
		different interfaces, and this answers for the one named.
		@return The local address, or a failure. For a server closed, unbound
		or not listening (whose `localPort` is not settled, so the answer
		would have nothing to pair with), the future is returned failed
		already, its `cause` an `IOError`, rather than this throwing.
	**/
	public function localAddressFor(destination:String):Future<String> {
		if (__closed || !bound || !listening) {
			var future = new Future<String>();
			@:privateAccess future.__fail("A local address can only be reported for a bound, listening server socket.",
				new IOError("Operation attempted on invalid socket."));
			return future;
		}

		return LocalAddress.forDestination(destination);
	}

	/**
		Runs an ICE agent over the socket this server already listens on.

		This is the join between the two halves. The agent knows how to find a
		path and nothing about sockets; the server holds the one socket that can
		be used to look. Attaching wires the three things the agent needs: its
		checks go out through this socket, STUN arriving here is handed to it,
		and its clock is driven from the runtime tick.

		It has to be *this* socket. A NAT keeps one mapping per socket, so a
		check sent from anywhere else opens a hole for a port the peer was never
		told about, and the path it proves would not be the path the session
		then uses.

		Checks are separated from ordinary traffic before the reliable decode,
		because a STUN message is not a reliable frame and would otherwise be
		dropped as noise; and, in the other direction, anything the agent does
		not recognise is passed straight on, since a peer keeps checking while
		its session is already carrying data.

		```haxe
		// Given server:ReliableDatagramServerSocket, controlling:Bool.
		import crossbyte.net.ice.IceAgent;

		var agent = new IceAgent(controlling);
		server.attachIceAgent(agent);

		agent.connected.then(function(pair) {
			var session = server.connect(pair.remote.address, pair.remote.port);
		}, function(reason) {
			trace("no path to the peer: " + reason);
		});
		```

		The agent still needs its candidates and the peer's credentials, and
		`start`, as `IceAgent` describes. `connected` fails when every pair
		has, and when no pair has been selected `agent.timeout` seconds after
		`start` (`IceAgent.DEFAULT_TIMEOUT`, 80, unless set), so code that
		dials on it hears when it never will.

		@param agent The agent to run. Its `onSend` is replaced.
		@throws IOError if this server is closed, unbound, or not listening:
		the socket has to exist before anything can be sent from it.
		@throws ArgumentError if an agent is already attached. Two agents on one
		socket would each answer the other's checks.
	**/
	public function attachIceAgent(agent:IceAgent):Void {
		if (agent == null) {
			throw new ArgumentError("An agent is required.");
		}

		if (__closed || !bound || !listening) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		if (__ice != null) {
			throw new ArgumentError("An ICE agent is already attached to this server socket.");
		}

		__ice = agent;

		agent.onSend = function(payload:ByteArray, address:String, port:Int):Void {
			if (__closed) {
				return;
			}

			try {
				__socket.send(payload, 0, payload.length, address, port);
			} catch (_:Dynamic) {
				// A check to an address that cannot be routed is an ordinary
				// outcome of trying every candidate, not a fault. The agent's
				// own retransmission budget is what decides that pair is dead.
			}
		};

		__iceTick = function(_:TickEvent):Void {
			agent.poll(haxe.Timer.stamp());
		};

		__tickRuntime().addEventListener(TickEvent.TICK, __iceTick);

		// A relay already lending an address: the agent checks from it too.
		if (relayedCandidate != null && __relaySend != null) {
			agent.addLocalCandidate(relayedCandidate, __relaySend);
		}
	}

	/**
		Stops running an attached agent, leaving the socket otherwise untouched.

		The agent itself is not closed: a caller may want to inspect what it
		found. Detaching only stops this server driving it.

		It may be called from any thread, as `close()` may, and is handed to
		the runtime the same way. Made elsewhere, it took the agent's tick
		off the runtime from the wrong thread.
	**/
	public function detachIceAgent():Void {
		var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
		if (__iceTick != null && RuntimeHandOff.offThread(runtime) && runtime.post(detachIceAgent)) {
			return;
		}

		if (__iceTick != null) {
			__untick(__iceTick);

			__iceTick = null;
		}

		if (__ice != null) {
			__ice.onSend = function(_, _, _):Void {};
			__ice = null;
		}
	}

	/**
		Sends one datagram from the port this server listens on, as it is:
		not a reliable frame, not through the relay.

		For whatever `onDatagram` takes in: a protocol of the application's own
		on this port has to answer from it.

		@throws IOError If the server is closed or not bound, or the send fails.
	**/
	public function sendDatagram(bytes:ByteArray, offset:Int, length:Int, address:String, port:Int):Void {
		if (__closed || !bound) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__socket.send(bytes, offset, length, address, port);
	}

	/**
		Asks a TURN relay for an address, through the port this server listens
		on, and reaches through it the peers hole punching cannot.

		For most pairs of peers hole punching on these sockets works. For a
		peer behind a symmetric NAT or a carrier's CGNAT (a fresh mapping
		per destination, so the address one peer learns of the other is
		never the one it would reach) it does not, and this is the relay to
		fall back to: its answers reach the client rather than the reliable
		decoder or an attached agent, and a session can send through it.

		Once the relay lends an address:
		- `relayedCandidate` is that address, for the peer to be told of;
		- `connectRelayed` opens a session that reaches its peer through the
		  relay, and a peer's CONNECT that arrives through it opens one that
		  answers the same way;
		- an attached `IceAgent` checks from the relayed candidate too, so a
		  pair through the relay is found like any other: dial the peer with
		  `connectRelayed` when the pair ICE chose is the relayed one;
		- the relay's requests, refreshes and permissions run on the runtime's
		  tick, and a relay that goes away closes the sessions that ran through
		  it, each with an `ioError` saying so.

		A peer that has not been sent anything yet can reach this server
		through the relay only once `permitRelayedPeer` has been given its
		address, as RFC 8656 has it: the relay drops the rest.

		@param useChannels See `TurnClient.useChannels`.
		@param transport How the relay is reached: UDP when left out, or TCP
		or TLS for a network that lets nothing else out: what it relays is
		UDP either way, and a session's datagrams are the same datagrams. A
		TLS relay's certificate is checked; see `relayCertAuthority` and
		`relayVerifyCert`.
		@return The relayed address, or a failure: one whose `cause` is a
		`TurnError` when the relay refused or never answered. A request that
		cannot be made is not thrown but returned failed already: for a
		server closed, unbound or not listening, its `cause` an `IOError`;
		with the server, username or password missing, an `ArgumentError`;
		and with no cause for a target with no secure random source, or a
		server that holds a relay already.
	**/
	public function allocateRelay(server:String, port:Int = 3478, username:String, password:String, useChannels:Bool = false,
			?transport:TurnTransport):Future<ReflexiveAddress> {
		var future = new Future<ReflexiveAddress>();

		if (__closed || !bound || !listening) {
			@:privateAccess future.__fail("A relay can only be allocated from a bound, listening server socket.",
				new IOError("Operation attempted on invalid socket."));
			return future;
		}

		if (server == null || server == "" || username == null || password == null) {
			@:privateAccess future.__fail("A TURN server address, username and password are required.", new ArgumentError("server"));
			return future;
		}

		if (!TurnClient.isSupported) {
			@:privateAccess future.__fail("A relay needs a cryptographically secure random source for its transaction ids, which this target does not have.",
				null);
			return future;
		}

		if (relay != null) {
			@:privateAccess future.__fail("This server socket already has a relay; releaseRelay first.", null);
			return future;
		}

		var client = new TurnClient(server, port, username, password, transport);
		client.useChannels = useChannels;
		client.verifyCert = relayVerifyCert;
		#if !(macro || (js && !nodejs))
		client.certAuthority = relayCertAuthority;
		#end
		relay = client;

		if (client.transport != UDP) {
			// Everything to and from the relay over a connection of its own.
			__relayStream = new TurnStream(client);
		} else {
			client.onSend = function(payload:ByteArray, address:String, sendPort:Int):Void {
				if (__closed) {
					return;
				}

				try {
					__socket.send(payload, 0, payload.length, address, sendPort);
				} catch (_:Dynamic) {
					// A lost request is retransmitted; one that can never be
					// sent ends in the relay's own timeout.
				}
			};
		}

		client.onData = function(payload:ByteArray, address:String, peerPort:Int):Void {
			if (client == relay) {
				__onRelayedData(client, payload, address, peerPort);
			}
		};

		client.onLost = function(reason:String):Void {
			__relayLost(client, reason);
		};

		// A peer address the relay will not forward to: pairs from the relayed
		// candidate to it are dead, and the agent is told so.
		client.onPermissionRefused = function(peerAddress:String, code:Int, reason:String):Void {
			if (client == relay && __ice != null && relayedCandidate != null) {
				__ice.refusePairs(relayedCandidate, peerAddress);
			}
		};

		client.allocated.then(function(relayed:ReflexiveAddress):Void {
			if (client != relay || __closed) {
				return;
			}

			relayedCandidate = new IceCandidate(RELAYED, relayed.address, relayed.port);
			__relaySend = function(payload:ByteArray, address:String, peerPort:Int):Void {
				if (client == relay) {
					__sendRelayed(client, payload, 0, payload.length, address, peerPort);
				}
			};

			if (__ice != null) {
				__ice.addLocalCandidate(relayedCandidate, __relaySend);
			}

			@:privateAccess future.__resolve(relayed);
		}, function(error:String):Void {
			if (client == relay) {
				__dropRelay();
			}

			@:privateAccess future.__fail(error, client.failure);
		});

		__relayTick = function(_:TickEvent):Void {
			client.poll(haxe.Timer.stamp());
		};

		__tickRuntime().addEventListener(TickEvent.TICK, __relayTick);
		client.allocate(haxe.Timer.stamp());
		return future;
	}

	/**
		Lets a peer at `address` reach this server through the relay.

		A relay forwards nothing from a peer it has not been told to expect. A
		peer this server sends to (a session dialled with `connectRelayed`, a
		check the agent sent) is permitted on the way; one that is to dial
		first has to be named here, from whatever the signalling said.

		@throws IOError When there is no relay holding an address.
		@throws ArgumentError When `address` is not an IPv4 address.
	**/
	public function permitRelayedPeer(address:String):Void {
		if (relay == null || !relay.active) {
			throw new IOError("There is no relay to permit a peer on: allocateRelay first, and wait for it.");
		}

		relay.permit(address, haxe.Timer.stamp());
	}

	/**
		Opens a reliable session to a peer through the relay: `connect`, with
		every datagram the session sends forwarded by the relay and the peer's
		arriving the same way.

		For a peer no direct path reaches. `address` and `port` are where the
		relay is to send: the peer's own relayed address, or whatever address
		of its a pair ICE chose through the relay names.

		@param timeoutMs As for `connect`: 20 seconds unless given, and 0 for
		       no deadline.
		@param payload As for `connect`.
		@param encryptionKey As for `connect`: the session's key, or null for
		       a session in the clear. The relay forwards sealed datagrams
		       it cannot read.
		@throws IOError If this server is closed or not listening, or there is
		no relay holding an address.
		@throws ArgumentError If `address` is not an IPv4 address, or a session
		to this endpoint already exists.
		@throws RangeError if `payload` is larger than one frame, or
		`timeoutMs` is negative.
	**/
	public function connectRelayed(address:String, port:Int, timeoutMs:Int = ReliableDatagramSocket.DEFAULT_TIMEOUT,
			?payload:ByteArray, ?encryptionKey:haxe.io.Bytes):ReliableDatagramSocket {
		if (__closed || !bound || !listening) {
			throw new IOError("Cannot dial from a server socket that is not bound and listening.");
		}

		__checkTimeout(timeoutMs);
		__checkKey(encryptionKey);

		if (relay == null || !relay.active) {
			throw new IOError("There is no relay to connect through: allocateRelay first, and wait for it.");
		}

		if (address == null || StunMessage.ipv4Octets(address) == null) {
			throw new ArgumentError("A relay forwards to an IPv4 address, and \"" + address + "\" is not one.");
		}

		var outgoing:ByteArray = ReliableDatagramSocket.__connectPayloadOf(payload, encryptionKey != null);
		var key:String = __endpointKey(address, port);

		if (__connections.exists(key)) {
			throw new ArgumentError("A reliable datagram session to " + key + " already exists on this server.");
		}

		// The permission first, so the relay forwards the first CONNECT.
		relay.permit(address, haxe.Timer.stamp());

		var socket = ReliableDatagramSocket.__createDialed(__socket, address, port, this, socketMode, timeoutMs, outgoing,
			congestionControlFor(address, port), relay, encryptionKey);
		__file(address, port, socket);
		return socket;
	}

	/**
		Frees the relay's allocation, ending first each session that reached
		its peer through it, at once, as `ReliableDatagramSocket.abort()`
		does, each with a FIN, while the relay can still carry one.

		It may be called from any thread, as `close()` may, and is handed to
		the runtime the same way, so the relay's tick comes off its own
		runtime, and an `allocateRelay` still waiting fails there, with its
		handlers run on that runtime's thread.
	**/
	public function releaseRelay():Void {
		var released = relay;

		if (released == null) {
			return;
		}

		var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
		if (RuntimeHandOff.offThread(runtime) && runtime.post(function():Void {
			// Not one allocated since.
			if (relay == released) {
				releaseRelay();
			}
		})) {
			return;
		}

		for (connection in __relayedSessions(released)) {
			try {
				connection.abort();
			} catch (_:Dynamic) {}
		}

		__dropRelay();
		released.close();
	}

	/** The sessions reaching their peers through `through`. **/
	@:noCompletion private function __relayedSessions(through:TurnClient):Array<ReliableDatagramSocket> {
		var found:Array<ReliableDatagramSocket> = [];

		for (connection in __connections) {
			if (connection.__relay == through) {
				found.push(connection);
			}
		}

		return found;
	}

	/**
		Stops driving the relay and forgets it; closing the client is the
		caller's. A connection it was reached over is closed here, which a
		relay takes as the end of the allocation whatever was said on it.
	**/
	@:noCompletion private function __dropRelay():Void {
		if (__relayTick != null) {
			__untick(__relayTick);

			__relayTick = null;
		}

		if (__relayStream != null) {
			var stream = __relayStream;
			__relayStream = null;
			stream.close();
		}

		relay = null;
		relayedCandidate = null;
		__relaySend = null;
	}

	/**
		The relay lost its allocation. The sessions that ran through it end
		with it, each told why and none sent a FIN: what would carry it is
		what just went.
	**/
	@:noCompletion private function __relayLost(client:TurnClient, reason:String):Void {
		if (client != relay) {
			return;
		}

		__dropRelay();

		for (connection in __relayedSessions(client)) {
			connection.dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "The relay this session reached its peer through went away: " + reason));
			connection.__dispose(true);
		}
	}

	/**
		One datagram for the relay to forward to a peer, permitting the peer
		first. A channel, where the relay was asked to use them, is the
		client's own business: `sendTo` asks for one with the first datagram
		to a peer, and `poll` renews it.
	**/
	@:noCompletion private function __sendRelayed(client:TurnClient, bytes:ByteArray, offset:Int, length:Int, address:String, port:Int):Void {
		client.permit(address, haxe.Timer.stamp());
		client.sendTo(bytes, address, port, offset, length);
	}

	/**
		What the relay forwarded, put back where it would have arrived: a check
		to the agent, told it came in on the relayed candidate so its answer
		goes back the same way, and anything else to the sessions, marked as
		having come through the relay.
	**/
	@:noCompletion private function __onRelayedData(client:TurnClient, payload:ByteArray, address:String, port:Int):Void {
		if (__closed || payload.length == 0) {
			return;
		}

		if (payload[0] < 4 && __ice != null) {
			var message = StunMessage.decode(payload);

			if (message != null && __ice.receive(payload, address, port, haxe.Timer.stamp(), relayedCandidate, message)) {
				return;
			}
		}

		payload.position = 0;
		__handleDatagram(payload, address, port, client);
	}

	@:noCompletion private function __settleStun(address:Null<ReflexiveAddress>, error:String):Void {
		var future = __stunFuture;

		if (future == null) {
			return;
		}

		__stunFuture = null;
		__stunQuery = null;

		if (__stunTick != null) {
			__untick(__stunTick);

			__stunTick = null;
		}

		if (address != null) {
			@:privateAccess future.__resolve(address);
		} else {
			@:privateAccess future.__fail(error, null);
		}
	}

	/**
		Whether this datagram was the reply to an outstanding STUN query.

		Checked before the reliable-protocol decode, because a STUN message is
		not one of those and would otherwise be dropped as noise.
	**/
	@:noCompletion private function __takeStunReply(message:StunMessage):Bool {
		if (__stunFuture == null || __stunQuery == null) {
			return false;
		}

		// Not STUN, or an answer to somebody else's question, stays somebody
		// else's: the transaction check is what stops an unrelated sender
		// handing this server an address it would then publish to every peer.
		switch (__stunQuery.interpretMessage(message)) {
			case NOT_OURS:
				return false;
			case ANSWERED(address):
				__settleStun(address, null);
			case REFUSED(reason):
				__settleStun(null, "The STUN server refused the request" + (reason != null ? ": " + reason : "."));
			case ANSWERED_WITHOUT_ADDRESS:
				__settleStun(null, "The STUN server replied without a mapped address, so this socket's public address is still unknown.");
			case UNUSABLE(reason):
				__settleStun(null, "The STUN server's answer could not be used: " + reason + ".");
		}

		return true;
	}

	@:noCompletion private inline function __endpointKey(address:String, port:Int):String {
		return address + ":" + port;
	}

	// The sessions again, by address and then by port: what a datagram is
	// matched by, with no key built for it. `__connections`, by the joined
	// key, is what everything else reads; the two change together, through
	// `__file` and `__unfile`.
	@:noCompletion private var __byHost:StringMap<haxe.ds.IntMap<ReliableDatagramSocket>> = new StringMap();
	// How many sessions each host in `__byHost` has, so whether a host has
	// any left is not asked of its map: asking a map whether it is empty
	// copies all of it natively, on every close, for every session behind
	// the same address (a carrier NAT puts many players behind one).
	@:noCompletion private var __byHostCount:StringMap<Int> = new StringMap();

	/** Files `socket` under its endpoint, in both maps. **/
	@:noCompletion private function __file(address:String, port:Int, socket:ReliableDatagramSocket):Void {
		__connections.set(__endpointKey(address, port), socket);
		var ports = __byHost.get(address);
		if (ports == null) {
			ports = new haxe.ds.IntMap();
			__byHost.set(address, ports);
		}
		if (!ports.exists(port)) {
			var count:Null<Int> = __byHostCount.get(address);
			__byHostCount.set(address, count == null ? 1 : count + 1);
		}
		ports.set(port, socket);
		if (socket.__listedAt < 0) {
			socket.__listedAt = __sessionList.length;
			__sessionList.push(socket);
			__shareReads();
		}
	}

	/** Its socket reads a share for each session in a pass; see `DatagramSocket.__readFor`. **/
	@:noCompletion private inline function __shareReads():Void {
		if (__socket != null) {
			@:privateAccess __socket.__readFor(__sessionList.length);
		}
	}

	/** Takes whatever is filed under an endpoint out of both maps. **/
	@:noCompletion private function __unfile(address:String, port:Int):Void {
		__connections.remove(__endpointKey(address, port));
		var ports = __byHost.get(address);
		if (ports != null && ports.remove(port)) {
			var count:Null<Int> = __byHostCount.get(address);
			if (count == null || count <= 1) {
				__byHost.remove(address);
				__byHostCount.remove(address);
			} else {
				__byHostCount.set(address, count - 1);
			}
		}
	}

	/** The session filed under an endpoint, found without building its key. **/
	@:noCompletion private inline function __sessionAt(address:String, port:Int):Null<ReliableDatagramSocket> {
		var ports = __byHost.get(address);
		return ports != null ? ports.get(port) : null;
	}

	/** For tests: a datagram handed over as the socket hands one, from an event made for it. **/
	@:noCompletion private function __onData(e:DatagramSocketDataEvent):Void {
		__receiveDatagram(e.data, e.srcAddress, e.srcPort);
	}

	/**
		Every datagram the socket reads, handed over directly; see
		`DatagramReceiver`.
	**/
	@:noCompletion public function __receiveDatagram(data:ByteArray, address:String, port:Int):Void {
		// The datagram is the sessions' to take its payload from, unless
		// something else has decoded it (a hook of the application's, or
		// the STUN decode below, which reads it in place).
		var owned:Bool = true;

		// First, whatever the application routes itself.
		if (onDatagram != null) {
			var taken:Bool = true;
			owned = false;

			try {
				taken = onDatagram(data, address, port);
			} catch (_:Dynamic) {}

			if (taken) {
				return;
			}

			data.position = 0;
		}

		// Then by the first byte, as RFC 7983 has one port shared: below 4 is
		// STUN and 64 to 127 a relay's ChannelData, where a reliable frame
		// starts with 0xCB and is never either, so a session's datagrams go
		// straight past all of this.
		if (data.length > 0) {
			var first:Int = data[0];

			if (first < 4 && (__stunFuture != null || relay != null || __ice != null)) {
				// Decoded once, and shown to each that might want it in turn.
				var message = StunMessage.decode(data);

				if (message != null) {
					// A reply to this server's own question about its address.
					if (__takeStunReply(message)) {
						return;
					}

					// The relay's: its answers, and what it forwards as Data
					// indications. Before the agent, which takes every STUN
					// message there is, the relay's answers included.
					if (relay != null && relay.receive(data, address, port, haxe.Timer.stamp(), message)) {
						return;
					}

					// A check from a peer, or an answer to one of the agent's
					// own. It reports whether it did, so everything else falls
					// through to the sessions rather than being swallowed by a
					// component that had no use for it.
					if (__ice != null && __ice.receive(data, address, port, haxe.Timer.stamp(), null, message)) {
						return;
					}
				}
				owned = false;
			} else if (first >= 0x40 && first <= 0x7F && relay != null) {
				if (relay.receive(data, address, port, haxe.Timer.stamp())) {
					return;
				}
				owned = false;
			}

			data.position = 0;
		}

		__handleDatagram(data, address, port, null, owned);
	}

	// The frame each datagram is decoded into; see
	// `ReliableDatagramSocket.__decodedFrame`.
	@:noCompletion private var __decodedFrame:ReliableDatagramFrame = null;

	/**
		A datagram for the sessions: from the socket, or unwrapped from the
		relay.

		@param via The relay it came through, which a session it opens answers
		through; null for one straight off the socket.
		@param owned Whether nobody else reads `data` during this call, so a
		frame may take it for its payload, moved down within it. Either way
		`data` is valid only during the call: a session copies what it
		keeps: a frame past a gap, a fragment, a CONNECT's payload.
	**/
	@:noCompletion private function __handleDatagram(data:ByteArray, address:String, port:Int, via:Null<TurnClient>, owned:Bool = false):Void {
		var connection:ReliableDatagramSocket = __sessionAt(address, port);

		// Sealed: for the encrypted session at this address to open. From an
		// address with none, it is a peer to tell its session is gone, as for
		// a bundle, or, with `allowRebind`, to challenge.
		if (data.length > 0) {
			var first:Int = (data : haxe.io.Bytes).get(0);
			if (first == SessionCipher.SEALED || first == SessionCipher.SEALED_HELLO) {
				if (connection == null) {
					__resetStranger(null, address, port, via);
				} else if (connection.__cipher != null) {
					connection.__receiveSealed(data);
				}
				return;
			}
		}

		// Several frames at once, and only ever from a session already here:
		// a peer bundles once it has heard this side, so a bundle from an
		// address with no session has nothing in it to open one with, only
		// a peer to tell its session is gone.
		if (ReliableDatagramProtocol.isBundle(data)) {
			if (connection == null) {
				__resetStranger(null, address, port, via);
			} else if (connection.__cipher != null) {
				// In the clear, to a session that takes only sealed ones.
				connection.__plainDropped++;
			} else {
				connection.__acceptBundle(data);
			}
			return;
		}

		if (__decodedFrame == null) {
			__decodedFrame = new ReliableDatagramFrame(ACK, 0, null, false);
		}
		// A payload that cannot be `data` itself is copied into the server's
		// own, filled again for each, unless it is out.
		var copy:ByteArray = null;
		if (!owned && Arrivals.REUSE && !__copyOut) {
			copy = __copy;
			if (copy == null) {
				copy = __copy = new ByteArray();
			}
		}
		var frame = ReliableDatagramProtocol.decodeInto(data, 0, data.length, owned, __decodedFrame, false, copy);
		if (frame == null) {
			// Neither a frame nor sealed, to a session that takes only sealed
			// datagrams: counted there.
			if (connection != null && connection.__cipher != null) {
				connection.__plainDropped++;
			}
			return;
		}

		// A payload copied out of `data` for this frame is this call's to
		// finish with; one that is `data` itself is the socket's.
		var payload:ByteArray = frame.payload;
		if (payload == null || payload == data) {
			__handleFrame(frame, connection, address, port, via);
			return;
		}
		var pooled:Bool = payload == copy;
		if (pooled) {
			__copyOut = true;
		}
		try {
			__handleFrame(frame, connection, address, port, via);
		} catch (e:Dynamic) {
			__handled(payload, pooled);
			Arrivals.rethrow(e);
		}
		__handled(payload, pooled);
	}

	// What its encrypted sessions seal into and open into, shared by all of
	// them (one runtime, one datagram at a time) rather than a buffer of
	// each; the second taken afresh while it is out. See
	// `ReliableDatagramSocket.__sealBuffer`.
	@:noCompletion private var __sealed:ByteArray = null;
	@:noCompletion private var __opened:ByteArray = null;
	@:noCompletion private var __openedOut:Bool = false;

	// The payload a frame is copied out into when it cannot take the
	// datagram itself (an application's onDatagram, or the relay, saw it
	// first): one for the server, filled again for each; and whether it is
	// out, when a frame gets one of its own.
	@:noCompletion private var __copy:ByteArray = null;
	@:noCompletion private var __copyOut:Bool = false;

	// The frames every session of this server keeps until its peer
	// acknowledges them, and the buffers its messages are copied into; see
	// `FramePool`. Made when the first session sends.
	@:noCompletion private var __frames:crossbyte.net._internal.reliable.FramePool = null;

	// Where its sessions write a HANDSHAKE's payload and an ACK's before the
	// frame copies it out: see `ReliableDatagramSocket.__echoBuffer`.
	@:noCompletion private var __echoScratch:ByteArray = null;
	@:noCompletion private var __sackScratch:ByteArray = null;

	@:noCompletion private function __framePool():crossbyte.net._internal.reliable.FramePool {
		if (__frames == null) {
			__frames = new crossbyte.net._internal.reliable.FramePool();
		}
		return __frames;
	}

	@:noCompletion private inline function __handled(payload:ByteArray, pooled:Bool):Void {
		if (pooled) {
			Arrivals.release(payload);
			__copyOut = false;
		} else {
			Arrivals.done(payload);
		}
	}

	/** One frame of `__handleDatagram`'s, for the session it is from, or for none yet. **/
	@:noCompletion private function __handleFrame(frame:ReliableDatagramFrame, connection:Null<ReliableDatagramSocket>, address:String, port:Int,
			via:Null<TurnClient>):Void {
		// A REBIND names its session by connection id, wherever it comes from.
		if (frame.type == ReliableDatagramFrameType.PATH && (frame.payload : haxe.io.Bytes).get(0) == ReliableDatagramProtocol.PATH_REBIND) {
			__acceptRebind(frame, connection, address, port, via);
			return;
		}

		if (connection != null) {
			// In the clear, to an encrypted session: only what is never
			// sealed is taken there, a CONNECT below.
			if (connection.__cipher != null && frame.type != ReliableDatagramFrameType.CONNECT) {
				connection.__acceptPlain(frame);
				return;
			}
			if (frame.type != ReliableDatagramFrameType.CONNECT || !__isAnotherAttempt(connection, frame)) {
				connection.__acceptFrame(frame);
				return;
			}

			// A CONNECT with a new id, from the address and port of a session
			// already here: not from the peer that session was made for, which
			// sends its own id every time. Either that peer restarted and this
			// session is left over (and would take every CONNECT the new one
			// sends, answer none, and be kept alive by them) or somebody is
			// claiming the address. The old peer is asked, and the CONNECT that
			// finds no answer due replaces the session.
			if (!__replaceable(connection)) {
				return;
			}

			// Not closed: a FIN goes to the address, where the new attempt
			// would take it as the end of its own.
			connection.__dispose(true);
			connection = null;
		}

		if (frame.type != ReliableDatagramFrameType.CONNECT) {
			// A cookie or a rebind's answer is a server's to send, not to
			// take, and from an address with no session it is a stranger's.
			__resetStranger(frame, address, port, via);
			return;
		}

		if (!listening) {
			return;
		}

		// Read before the hooks run: the frame is the one every datagram is
		// decoded into, and a hook that pumps the runtime has the next one
		// decoded over it.
		var connectionId:Int = frame.sequence;
		var bundles:Bool = frame.bundles;
		var extended:Bool = frame.extended;
		var canRebind:Bool = extended && (frame.features & ReliableDatagramProtocol.FEATURE_REBIND) != 0;

		var encrypting:Bool = extended && frame.hasRandom;

		// No connect() sends more than a frame, and each pending session
		// keeps what its CONNECT carried, so a larger one is not held.
		var payload:ByteArray = frame.payload;
		if (payload.length > (encrypting ? ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE : ReliableDatagramProtocol.MAX_PAYLOAD_SIZE)) {
			return;
		}

		// Shown to come from where it says, or asked to show it: see
		// `joinValidation`. A cookie that does not check out is no cookie,
		// and the CONNECT is taken as one without.
		if (!(frame.hasCookie && __cookieChecks(frame.cookieHigh, frame.cookieLow, address, port, connectionId)) && __joinsMustShowAddress()) {
			// A peer from before 1.0 cannot answer a cookie, and its CONNECT
			// is too short for one to be sent back: dropped, as at
			// `maxPendingConnections`. A 1.0 CONNECT is padded past a cookie.
			if (extended) {
				__sendCookie(connectionId, address, port, via);
			}
			return;
		}

		if (maxPendingConnections >= 0 && __pendingCount >= maxPendingConnections) {
			return;
		}

		// The peer's random, copied out of the frame before the hooks run.
		var peerRandom:Null<haxe.io.Bytes> = null;
		if (encrypting) {
			peerRandom = haxe.io.Bytes.alloc(ReliableDatagramProtocol.RANDOM_SIZE);
			peerRandom.blit(0, frame.random, 0, ReliableDatagramProtocol.RANDOM_SIZE);
		}

		var admitted:Bool = false;
		try {
			admitted = admit(address, port, payload);
		} catch (_:Dynamic) {}
		if (!admitted) {
			return;
		}

		// The session's key, if it has one; and no session where only one
		// side would encrypt: see `encryptionKeyFor`.
		payload.position = 0;
		var key:Null<haxe.io.Bytes> = null;
		try {
			key = encryptionKeyFor(address, port, payload);
		} catch (_:Dynamic) {
			return;
		}
		if (key != null && key.length != SessionCipher.KEY_SIZE) {
			return;
		}
		var cipher:Null<SessionCipher> = null;
		if (encrypting || key != null) {
			if (!encrypting) {
				// A CONNECT from before 1.0 is too short to be answered with
				// more than it brought: dropped.
				if (extended) {
					__refuse(connectionId, ReliableDatagramProtocol.REFUSE_ENCRYPTION_REQUIRED, address, port, via);
				}
				return;
			}
			if (key == null || !ReliableDatagramSocket.isEncryptionSupported) {
				__refuse(connectionId, ReliableDatagramProtocol.REFUSE_NO_KEY, address, port, via);
				return;
			}
			cipher = new SessionCipher(key);
			// Refused only for a random equal to the one just made: a CONNECT
			// carrying this side's own, which nobody can know in advance.
			if (!cipher.derive(peerRandom)) {
				cipher.dispose();
				return;
			}
		}

		var congestion:CongestionControl = null;
		try {
			congestion = congestionControlFor(address, port);
		} catch (_:Dynamic) {
			if (cipher != null) {
				cipher.dispose();
			}
			return;
		}

		payload.position = 0;
		// A key to rebind with, for a peer that can, while it is allowed.
		var rebindKey:Null<haxe.io.Bytes> = canRebind ? __newRebindKey(connectionId, cipher) : null;
		// Through the relay, when that is how the CONNECT came: the peer is
		// somewhere nothing but the relay reaches. The session keeps a copy
		// of the payload, which is the datagram's.
		connection = ReliableDatagramSocket.__createAccepted(__socket, address, port, this, socketMode, payload, congestion, connectionId, via,
			rebindKey, cipher);
		connection.__peerTakesBundles = bundles;
		if (rebindKey != null) {
			__byConnectionId.set(connectionId, connection);
		}
		__file(address, port, connection);
		__pending.set(__endpointKey(address, port), true);
		__pendingCount++;
	}

	/**
		Whether a CONNECT is from another attempt than the one `connection` was
		made for: both carry ids, and they differ. A CONNECT from an older
		build carries none, and is taken by the session as any CONNECT is.
	**/
	@:noCompletion private static inline function __isAnotherAttempt(connection:ReliableDatagramSocket, frame:ReliableDatagramFrame):Bool {
		var id:Int = frame.sequence;
		return id != 0 && connection.__peerConnectionId != 0 && id != connection.__peerConnectionId;
	}

	/**
		Whether a session sent a CONNECT with a new id may be replaced: asked
		its old peer whether it is still there, gave it the time to answer,
		and heard nothing. The first such CONNECT asks, and the one that finds
		the answer overdue and missing replaces it: a restarted peer is let
		back in on its next attempt, a few seconds on. A peer still there
		answers, and keeps its session however many CONNECTs someone sends in
		its name; asking again at most once a window, so they cannot make this
		side send much.
	**/
	@:noCompletion private function __replaceable(connection:ReliableDatagramSocket):Bool {
		var now:Float = haxe.Timer.stamp();

		if (connection.__challengedAt >= 0) {
			if (now - connection.__challengedAt < connection.__challengeWindow()) {
				return false;
			}
			if (!connection.__heardSinceChallenge) {
				return true;
			}
		}

		connection.__challenge(now);
		return false;
	}

	/** Whether a CONNECT from an address with no session must show it receives there; see `joinValidation`. **/
	@:noCompletion private inline function __joinsMustShowAddress():Bool {
		return switch (joinValidation) {
			case ALWAYS: true;
			case NEVER: false;
			default: __pendingCount >= joinValidationThreshold;
		}
	}

	// The keys cookies (and rebind challenges) are made with: the one in
	// use, and the one before it, which is still accepted. Made when first
	// needed, and turned over every `__pathKeyPeriod` seconds; a cookie says
	// which of the two made it in its top bit, the turnover's parity.
	@:noCompletion private var __pathKey:SipHash = null;
	@:noCompletion private var __pathKeyBefore:SipHash = null;
	@:noCompletion private var __pathGeneration:Int = 0;
	@:noCompletion private var __pathKeyMadeAt:Float = 0;

	/** How long a key is in use; a cookie made with it is good for once to twice this. **/
	@:noCompletion private static inline var PATH_KEY_PERIOD:Float = 10.0;

	@:noCompletion private var __pathKeyPeriod:Float = PATH_KEY_PERIOD;

	// What a key hashes, written here, and the answer: nothing allocated per
	// CONNECT or per reset.
	@:noCompletion private var __macInput:haxe.io.Bytes = null;
	@:noCompletion private var __macHigh:Int = 0;
	@:noCompletion private var __macLow:Int = 0;

	// The frames this server sends about an address (cookies, rebinds'
	// answers), written here.
	@:noCompletion private var __pathScratch:ByteArray = null;

	/** What each kind of keyed hash starts with, so one can never pass for another. **/
	@:noCompletion private static inline var COOKIE_DOMAIN:Int = 0x43;

	/** The keys as they are at `now`: made, or turned over once their time is up. **/
	@:noCompletion private function __pathKeys(now:Float):Void {
		if (__pathKey == null) {
			__pathKey = __newPathKey();
			__pathKeyBefore = __newPathKey();
			__pathKeyMadeAt = now;
			return;
		}
		var age:Float = now - __pathKeyMadeAt;
		if (age < 0) {
			// The time of day, set back (hl, neko, the interpreter): the key
			// in use starts its period again.
			__pathKeyMadeAt = now;
			return;
		}
		if (age < __pathKeyPeriod) {
			return;
		}
		if (age < __pathKeyPeriod * 2) {
			__pathKeyBefore = __pathKey;
			__pathKey = __newPathKey();
			__pathGeneration++;
		} else {
			// Both are past their time: neither is accepted any more, and the
			// parity is kept, so a cookie two turnovers old reads as the
			// current key's and fails against it.
			__pathKeyBefore = __newPathKey();
			__pathKey = __newPathKey();
			__pathGeneration += 2;
		}
		__pathKeyMadeAt = now;
	}

	@:noCompletion private static function __newPathKey():SipHash {
		var key = haxe.io.Bytes.alloc(SipHash.KEY_SIZE);
		if (crossbyte.crypto.SecureRandom.isSupported) {
			try {
				var random:ByteArray = crossbyte.crypto.SecureRandom.getSecureRandomBytes(SipHash.KEY_SIZE);
				key.blit(0, random, 0, SipHash.KEY_SIZE);
				return new SipHash(key);
			} catch (_:Dynamic) {}
		}
		// No secure source (neko, HashLink, the interpreter): the ordinary
		// one, as the sequence numbers fall back to; see `joinValidation`.
		for (i in 0...SipHash.KEY_SIZE) {
			key.set(i, Std.random(256));
		}
		return new SipHash(key);
	}

	/**
		The keyed hash of `domain`, `port`, `value` and `address` under `key`,
		left in `__macHigh` and `__macLow`.
	**/
	@:noCompletion private function __mac(key:SipHash, domain:Int, address:String, port:Int, value:Int):Void {
		var length:Int = 7 + address.length;
		if (__macInput == null || __macInput.length < length) {
			__macInput = haxe.io.Bytes.alloc(length < 64 ? 64 : length);
		}
		var input:haxe.io.Bytes = __macInput;
		input.set(0, domain);
		input.set(1, (port >>> 8) & 0xFF);
		input.set(2, port & 0xFF);
		input.set(3, value >>> 24);
		input.set(4, (value >>> 16) & 0xFF);
		input.set(5, (value >>> 8) & 0xFF);
		input.set(6, value & 0xFF);
		// An address is ASCII: digits, dots, colons, hex, and a zone's name.
		for (i in 0...address.length) {
			input.set(7 + i, StringTools.fastCodeAt(address, i) & 0xFF);
		}
		key.hash(input, 0, length);
		__macHigh = key.high;
		__macLow = key.low;
	}

	/**
		Whether a cookie is the one this server made for a CONNECT with
		`connectionId` from `address`:`port`, with the key in use or the one
		before it.
	**/
	@:noCompletion private function __cookieChecks(high:Int, low:Int, address:String, port:Int, connectionId:Int):Bool {
		__pathKeys(haxe.Timer.stamp());
		var parity:Int = high >>> 31;
		__mac(parity == (__pathGeneration & 1) ? __pathKey : __pathKeyBefore, COOKIE_DOMAIN, address, port, connectionId);
		// Every bit compared, whichever differs first.
		return (((__macHigh & 0x7FFFFFFF) ^ (high & 0x7FFFFFFF)) | (__macLow ^ low)) == 0;
	}

	/**
		Answers a CONNECT with its cookie: a PATH frame, 16 bytes, echoing the
		connection id, sent back the way the CONNECT came. Nothing is kept.
	**/
	@:noCompletion private function __sendCookie(connectionId:Int, address:String, port:Int, via:Null<TurnClient>):Void {
		__pathKeys(haxe.Timer.stamp());
		__mac(__pathKey, COOKIE_DOMAIN, address, port, connectionId);
		var high:Int = (__macHigh & 0x7FFFFFFF) | ((__pathGeneration & 1) << 31);
		var scratch:ByteArray = __pathFrame(ReliableDatagramFrameType.PATH, connectionId, ReliableDatagramProtocol.PATH_COOKIE);
		var bytes:haxe.io.Bytes = scratch;
		var at:Int = ReliableDatagramProtocol.HEADER_SIZE + 1;
		__setInt(bytes, at, high);
		__setInt(bytes, at + 4, __macLow);
		__sendScratch(ReliableDatagramProtocol.COOKIE_FRAME_SIZE, address, port, via);
	}

	/**
		A rebind key for the session a peer with `connectionId` is opening,
		filed by that id; null (the session cannot rebind) while rebinding
		is not allowed, with no secure random source, or when another session
		that may rebind has the same id, which 32 random bits make rare.
	**/
	@:noCompletion private function __newRebindKey(connectionId:Int, ?cipher:SessionCipher):Null<haxe.io.Bytes> {
		if (!allowRebind || connectionId == 0 || !crossbyte.crypto.SecureRandom.isSupported) {
			return null;
		}
		if (__byConnectionId == null) {
			__byConnectionId = new haxe.ds.IntMap();
		} else if (__byConnectionId.exists(connectionId)) {
			return null;
		}
		// An encrypted session's is derived with its keys, at both ends, and
		// never sent.
		if (cipher != null) {
			return cipher.rebindKey;
		}
		try {
			var random:ByteArray = crossbyte.crypto.SecureRandom.getSecureRandomBytes(ReliableDatagramProtocol.REBIND_KEY_SIZE);
			var key = haxe.io.Bytes.alloc(ReliableDatagramProtocol.REBIND_KEY_SIZE);
			key.blit(0, random, 0, ReliableDatagramProtocol.REBIND_KEY_SIZE);
			return key;
		} catch (_:Dynamic) {
			return null;
		}
	}

	/** The challenge a reset to `address`:`port` carries: never 0, which is a reset with none. **/
	@:noCompletion private function __challengeFor(address:String, port:Int):Int {
		__pathKeys(haxe.Timer.stamp());
		return __challengeWith(__pathKey, __pathGeneration & 1, address, port);
	}

	@:noCompletion private function __challengeWith(key:SipHash, parity:Int, address:String, port:Int):Int {
		__mac(key, CHALLENGE_DOMAIN, address, port, 0);
		var challenge:Int = (__macHigh & 0x7FFFFFFF) | (parity << 31);
		return challenge == 0 ? 1 : challenge;
	}

	/** Whether `challenge` is one this server made for `address`:`port`, with the key in use or the one before. **/
	@:noCompletion private function __challengeChecks(challenge:Int, address:String, port:Int):Bool {
		__pathKeys(haxe.Timer.stamp());
		var parity:Int = challenge >>> 31;
		var key:SipHash = parity == (__pathGeneration & 1) ? __pathKey : __pathKeyBefore;
		return (__challengeWith(key, parity, address, port) ^ challenge) == 0;
	}

	/**
		A REBIND: a peer whose address changed, answering the challenge this
		server's reset sent to the new one, with its connection id and its
		proof. See `allowRebind` for what is checked, and why each refusal
		is answered as it is. Everything is read off the frame first: it is
		the one every datagram is decoded into.
	**/
	@:noCompletion private function __acceptRebind(frame:ReliableDatagramFrame, connection:Null<ReliableDatagramSocket>, address:String, port:Int,
			via:Null<TurnClient>):Void {
		var payload:ByteArray = frame.payload;
		if (payload.length < 1 + ReliableDatagramProtocol.CHALLENGE_SIZE + ReliableDatagramProtocol.REBIND_PROOF_SIZE) {
			return;
		}
		var id:Int = frame.sequence;
		var bytes:haxe.io.Bytes = payload;
		var challenge:Int = __getInt(bytes, 1);
		var proofHigh:Int = __getInt(bytes, 5);
		var proofLow:Int = __getInt(bytes, 9);

		var session:Null<ReliableDatagramSocket> = __byConnectionId != null ? __byConnectionId.get(id) : null;
		if (!allowRebind || session == null || session.__closed || session.__closing || !session.__connected) {
			// Nothing here to move. A peer sending from an address with no
			// session is told so, as any stranger is, by a reset that
			// carries no challenge, which it takes as the end.
			if (connection == null) {
				__resetStranger(null, address, port, via, false);
			}
			return;
		}

		if (session == connection) {
			// At that address already: its REBOUND was lost, or it never
			// moved. Answered again, and nothing moves.
			session.__sendRebound(challenge);
			return;
		}

		// Another session's address, or past what a pass checks.
		if (connection != null || !__mayCheckRebind()) {
			return;
		}

		if (!__challengeChecks(challenge, address, port)) {
			// Made for another address or port, or past its time: a fresh one,
			// for whoever is at this address, as any reset there would carry.
			__resetStranger(null, address, port, via, true);
			return;
		}

		if (!session.__rebindProofChecks(challenge, proofHigh, proofLow)) {
			return;
		}

		var now:Float = haxe.Timer.stamp();
		if (session.__reboundAt >= 0 && now - session.__reboundAt < MIN_REBIND_INTERVAL) {
			return;
		}

		__moveSession(session, address, port, via);
		session.__rebound(challenge, now);
	}

	/**
		Whether another REBIND may be checked this pass (a keyed hash for
		the challenge and another for the proof), counting it if so. The
		count starts again when the runtime's pass ends.
	**/
	@:noCompletion private function __mayCheckRebind():Bool {
		if (__rebindChecks == 0) {
			var runtime:Null<CrossByte> = @:privateAccess __socket.__cbInstance;
			if (runtime != null && !@:privateAccess runtime.__didExit) {
				@:privateAccess runtime.__queuePassFlush(this);
			}
		}
		if (__rebindChecks >= MAX_REBIND_CHECKS_PER_PASS) {
			return false;
		}
		__rebindChecks++;
		return true;
	}

	/** The runtime's call at the end of a pass in which REBINDs were checked. **/
	@:noCompletion public function __flushPass():Void {
		__rebindChecks = 0;
	}

	/**
		Files `session` under the address and port its peer is at now, out of
		everything it was filed under at the old one (the endpoint maps, the
		host's count, the pending set), and through `via`, the relay it now
		reaches its peer through, or none.
	**/
	@:noCompletion private function __moveSession(session:ReliableDatagramSocket, address:String, port:Int, via:Null<TurnClient>):Void {
		var wasPending:Bool = __pending.remove(__endpointKey(session.__remoteAddress, session.__remotePort));
		__unfile(session.__remoteAddress, session.__remotePort);
		session.__remoteAddress = address;
		session.__remotePort = port;
		session.__remoteResponsePort = 0;
		session.__relay = via;
		__file(address, port, session);
		if (wasPending) {
			__pending.set(__endpointKey(address, port), true);
		}
	}

	@:noCompletion private static inline function __getInt(bytes:haxe.io.Bytes, at:Int):Int {
		return (bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8) | bytes.get(at + 3);
	}

	/** A frame's header and its first payload byte, written into `__pathScratch`. **/
	@:noCompletion private function __pathFrame(type:ReliableDatagramFrameType, sequence:Int, kind:Int):ByteArray {
		if (__pathScratch == null) {
			__pathScratch = new ByteArray();
			__pathScratch.length = 64;
		}
		var written:Int = ReliableDatagramProtocol.encodeInto(__pathScratch, type, sequence, null, 0, 0, false, 0, false, false);
		(__pathScratch : haxe.io.Bytes).set(written, kind);
		return __pathScratch;
	}

	/**
		Tells the sender of a CONNECT why no session is opened for it, with a
		`PATH_REFUSE`: encryption asked for and no key, or a key and none
		asked for. Within the process's allowance of resets
		(`maxResetsPerSecond`), and never larger than the 1.0 CONNECT it
		answers.
	**/
	@:noCompletion private function __refuse(connectionId:Int, reason:Int, address:String, port:Int, via:Null<TurnClient>):Void {
		if (!ResetBudget.take(maxResetsPerSecond, haxe.Timer.stamp())) {
			return;
		}
		var scratch:ByteArray = __pathFrame(ReliableDatagramFrameType.PATH, connectionId, ReliableDatagramProtocol.PATH_REFUSE);
		(scratch : haxe.io.Bytes).set(ReliableDatagramProtocol.HEADER_SIZE + 1, reason);
		__sendScratch(ReliableDatagramProtocol.REFUSE_FRAME_SIZE, address, port, via);
	}

	/** `length` bytes of `__pathScratch` to a peer, back the way it reached this server. **/
	@:noCompletion private function __sendScratch(length:Int, address:String, port:Int, via:Null<TurnClient>):Void {
		try {
			if (via != null) {
				__sendRelayed(via, __pathScratch, 0, length, address, port);
			} else {
				__socket.send(__pathScratch, 0, length, address, port);
			}
		} catch (_:Dynamic) {}
	}

	@:noCompletion private static inline function __setInt(bytes:haxe.io.Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	/**
		Tells a peer sending as though it had a session here that it has none,
		with a FIN, which ends the session on its side at once.

		Without it a peer whose session this side had closed or never had
		(the server restarted, or gave the session up) would go on sending
		into nothing until its own timeout ran out. A FIN is the size of the
		smallest frame that can draw one, so answering gains a sender nothing
		it could not send itself. Never sent for a FIN that ends a session at
		once, which is what this sends: two sides that each thought the other
		a stranger would answer each other for good. A graceful FIN is
		answered, since its sender waits for an acknowledgement nothing here
		will give, often from a session that took the FIN and went, its
		answer lost on the way.

		Sent only within the process's allowance, `maxResetsPerSecond`,
		however many frames come from strangers.
	**/
	@:noCompletion private function __resetStranger(frame:Null<ReliableDatagramFrame>, address:String, port:Int, via:Null<TurnClient>,
			withChallenge:Bool = true):Void {
		if (frame != null && frame.type == ReliableDatagramFrameType.FIN && !frame.graceful) {
			return;
		}

		// Within the process's allowance, which every server shares; see
		// `maxResetsPerSecond`.
		if (!ResetBudget.take(maxResetsPerSecond, haxe.Timer.stamp())) {
			return;
		}

		if (__resetScratch == null) {
			__resetScratch = new ByteArray();
			__resetScratch.length = ReliableDatagramProtocol.HEADER_SIZE;
		}

		// Where a session may follow its peer, the challenge it answers from
		// its new address, in the sequence field a reset leaves at 0: the
		// reset is no larger for it. See `allowRebind`.
		var challenge:Int = withChallenge && allowRebind ? __challengeFor(address, port) : 0;
		var length:Int = ReliableDatagramProtocol.encodeInto(__resetScratch, ReliableDatagramFrameType.FIN, challenge, null, 0, 0, false, 0, false,
			false);
		try {
			// Back the way it came: a frame from a peer only the relay reaches
			// is answered through the relay.
			if (via != null) {
				__sendRelayed(via, __resetScratch, 0, length, address, port);
			} else {
				__socket.send(__resetScratch, 0, length, address, port);
			}
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __onSocketClosed(socket:ReliableDatagramSocket):Void {
		var key:String = __endpointKey(socket.remoteAddress, socket.remotePort);
		__unfile(socket.remoteAddress, socket.remotePort);
		__delist(socket);
		__releasePending(key);
		if (__byConnectionId != null && socket.__offersRebind && __byConnectionId.get(socket.__peerConnectionId) == socket) {
			__byConnectionId.remove(socket.__peerConnectionId);
		}
		// One closed while its peer's name was looked up was filed only
		// here; its answer, when it comes, finds it gone.
		if (__dialling != null) {
			__dialling.remove(socket);
		}
	}

	// Removal answers whether it was still pending, so this stays exact
	// however a session leaves: handshake done, timed out, or closed under it.
	@:noCompletion private function __releasePending(key:String):Void {
		if (__pending.remove(key)) {
			__pendingCount--;
		}
	}

	@:noCompletion private function __onSocketConnected(socket:ReliableDatagramSocket):Void {
		// The peer answered, so the address is its own and the slot is free
		// again. Done before the outgoing check below, which returns early.
		__releasePending(__endpointKey(socket.remoteAddress, socket.remotePort));

		// Only sessions a peer opened to us. A session `connect()` dialled is
		// registered here too, because that is how its replies get routed, but
		// it was initiated rather than accepted, and whoever dialled it
		// already holds it: announcing it as a new arrival would have every
		// caller wire it up twice.
		if (!socket.__incoming) {
			return;
		}

		dispatchEvent(new ReliableDatagramSocketConnectEvent(ReliableDatagramSocketConnectEvent.CONNECT, socket));
	}

	@:noCompletion private inline function get_bound():Bool {
		return !__closed && __socket.bound;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __socket.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __socket.localPort;
	}
}
#end
