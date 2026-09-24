import crossbyte.core.FixedStep;
import crossbyte.core.HostApplication;
import crossbyte.ds.BitSet;
import crossbyte.ds.InterestSet;
import crossbyte.ds.QuadTree;
import crossbyte.ds.QuadTree.QuadTreeNode;
import crossbyte.ds.SequenceRing;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteDelta;
import crossbyte.math.Rectangle;
import crossbyte.net.ConcurrencyLimiter;
import crossbyte.net.ConcurrencyPermit;
import crossbyte.net.FrameCodec;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import haxe.Timer;

/**
	An authoritative arena server and the bots that play in it, in one
	process: the game-server primitives working together rather than each
	alone.

	- `FixedStep` runs the simulation at 20 Hz, whatever rate the loop runs at.
	- A `QuadTree`, rebuilt every step, answers who is near whom.
	- An `InterestSet` per client says what came into its view and what left.
	- Each client's view is a table of slots, handed out as things enter
	  (`BitSet.nextClearBit`) and freed as they leave, so a snapshot keeps its
	  layout from one step to the next -- which is what gives `ByteDelta`
	  something to find.
	- A `SequenceRing` per client keeps what was sent, keyed by tick, and each
	  snapshot is encoded against the last one that client acknowledged, or
	  whole once that has aged out.
	- Logins go through a `ConcurrencyLimiter`, and connections through
	  `ServerSocket.admit`.

	Every snapshot carries a checksum of what the server built, and each bot
	checks what it decoded against it. A mismatch, a baseline a bot does not
	have, a bot that never gets in, or a bot that never sees itself: exit 1.

	The loop is the sample's own, which is the shape a game server with a
	loop of its own takes: a `HostApplication`, advanced by hand. Nothing here
	reaches past the public API.
**/
class ArenaSample extends HostApplication {
	// The world.
	public static inline var WORLD:Float = 2000;
	static inline var NPCS:Int = 300;
	static inline var NPC_SPEED:Float = 40;
	static inline var BOT_SPEED:Float = 90;
	static inline var VIEW_RADIUS:Float = 300;

	// What a client is sent. Eight bytes a slot: the id plus one (0 marks an
	// empty slot), a generation, and a position.
	public static inline var VIEW_SLOTS:Int = 64;
	public static inline var SLOT_BYTES:Int = 8;
	public static inline var HISTORY:Int = 64;

	// Admission: four logins at a time, the rest wait up to five seconds.
	static inline var LOGINS_AT_ONCE:Int = 4;
	static inline var LOGIN_QUEUE:Int = 64;
	static inline var LOGIN_WAIT:Float = 5;
	// Standing in for the database call a real login makes.
	static inline var LOGIN_STEPS:Int = 6;

	// The run.
	static inline var BOTS:Int = 16;
	static inline var SECONDS:Float = 8;

	static var seed:Int = 0x2545F491;

	static var sim:FixedStep;
	static var entities:Array<Entity> = [];
	static var tree:QuadTree<Entity>;
	static var found:Array<QuadTreeNode<Entity>> = [];
	static var sessions:Array<Session> = [];
	static var logins:ConcurrencyLimiter;
	static var openFrom:Map<String, Int> = new Map();
	static var stats:Stats = new Stats();

	public static function main():Void {
		var app = new ArenaSample();
		Sys.exit(app.run() ? 0 : 1);
	}

	public function new() {
		super();
	}

	function run():Bool {
		var server = startServer();
		crossByte.addEventListener(TickEvent.TICK, (event:TickEvent) -> {
			sim.advance(event.delta);
			while (sim.step()) {
				step();
			}
		});

		var bots:Array<Bot> = [for (_ in 0...BOTS) new Bot(server.localPort)];
		var extra:Socket = null;

		var last:Float = Timer.stamp();
		var deadline:Float = last + SECONDS;
		while (Timer.stamp() < deadline) {
			var now:Float = Timer.stamp();
			advance(now - last, 0.002);
			last = now;

			// Once everyone is in, one connection more from the same address
			// than `admit` allows, to show it turned away before it costs
			// anything.
			if (extra == null && stats.logins == BOTS) {
				extra = new Socket();
				extra.connect("127.0.0.1", server.localPort);
			}
		}

		var ok:Bool = report(bots);
		shutdown();
		return ok;
	}

	// --- The server -------------------------------------------------------

	static function startServer():ServerSocket {
		sim = new FixedStep(1 / 20);
		tree = new QuadTree<Entity>(new Rectangle(0, 0, WORLD, WORLD), 8);
		logins = new ConcurrencyLimiter(LOGINS_AT_ONCE, LOGIN_QUEUE, LOGIN_WAIT);

		for (_ in 0...NPCS) {
			var npc = spawn();
			aim(npc, NPC_SPEED);
		}

		var server = new ServerSocket();
		// One connection per bot from an address, no more.
		server.admit = (address, _) -> {
			if ((openFrom.exists(address) ? openFrom.get(address) : 0) < BOTS) {
				return true;
			}
			stats.refusedAtAdmission++;
			return false;
		};
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> accept(cast event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		return server;
	}

	static function accept(socket:Socket):Void {
		var session = new Session(socket);
		sessions.push(session);
		openFrom.set(session.address, (openFrom.exists(session.address) ? openFrom.get(session.address) : 0) + 1);

		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			var incoming = new ByteArray();
			socket.readBytes(incoming);
			session.frames.feed(incoming);
			var message:Null<ByteArray> = session.frames.next();
			while (message != null) {
				receive(session, message);
				message = session.frames.next();
			}
		});
		socket.addEventListener(Event.CLOSE, _ -> leave(session));
	}

	static function receive(session:Session, message:ByteArray):Void {
		var type:MessageType = message.readUnsignedByte();
		switch (type) {
			case LOGIN:
				if (session.login == null) {
					// Granted now if a login slot is free, queued if not. Either way
					// the permit is kept, so a client that leaves while waiting
					// withdraws its place with the same release() that ends a login.
					session.login = logins.acquire(_ -> session.authenticating = LOGIN_STEPS, _ -> {
						stats.refusedLogins++;
						// A close from this side dispatches nothing here, so the
						// session is let go of directly.
						session.socket.close();
						leave(session);
					});
				}
			case INPUT:
				session.dx = message.readByte();
				session.dy = message.readByte();
			case ACK:
				var tick:Int = message.readInt();
				// Newer only: acks can arrive out of order on a transport that
				// allows it, and an older baseline is only a worse one.
				if (!session.acknowledged || tick - session.acknowledgedTick > 0) {
					session.acknowledged = true;
					session.acknowledgedTick = tick;
				}
			default:
		}
	}

	static function leave(session:Session):Void {
		// Once only: a refused login lets go directly, and a close may follow.
		if (!sessions.remove(session)) {
			return;
		}
		openFrom.set(session.address, openFrom.get(session.address) - 1);
		if (session.login != null) {
			// Waiting, logging in or long since logged in: release() is right
			// for all three.
			session.login.release();
		}
	}

	static function step():Void {
		var dt:Float = sim.interval;

		for (session in sessions) {
			if (session.authenticating > 0) {
				session.authenticating--;
				if (session.authenticating == 0) {
					welcome(session);
				}
			}
			if (session.avatar != null) {
				session.avatar.vx = session.dx * BOT_SPEED;
				session.avatar.vy = session.dy * BOT_SPEED;
			}
		}

		for (entity in entities) {
			entity.x += entity.vx * dt;
			entity.y += entity.vy * dt;
			if (entity.x < 0 || entity.x >= WORLD) {
				entity.vx = -entity.vx;
				entity.x = clamp(entity.x);
			}
			if (entity.y < 0 || entity.y >= WORLD) {
				entity.vy = -entity.vy;
				entity.y = clamp(entity.y);
			}
		}

		if (sim.tick % 20 == 0) {
			respawnOne();
		}

		tree.clear();
		for (entity in entities) {
			entity.node.x = entity.x;
			entity.node.y = entity.y;
			tree.insert(entity.node);
		}

		for (session in sessions) {
			if (session.avatar != null) {
				sendSnapshot(session);
			}
		}

		logins.sweep();
	}

	static function welcome(session:Session):Void {
		var avatar = spawn();
		session.avatar = avatar;
		// Authenticated: the next one in the queue may start.
		session.login.release();
		stats.logins++;

		var message = new ByteArray();
		message.writeByte(MessageType.WELCOME);
		message.writeShort(avatar.id);
		send(session.socket, message);
	}

	/**
		A new thing under an old id. Every client that could see the old one
		loses it now, and the id is forgotten, so that the newcomer -- a new
		generation in the same slot of the world -- is reported as entering
		rather than as having been there all along.
	**/
	static function respawnOne():Void {
		var npc = entities[random(NPCS)];
		npc.generation = (npc.generation + 1) & 0xFFFF;
		npc.x = random(Std.int(WORLD));
		npc.y = random(Std.int(WORLD));
		aim(npc, NPC_SPEED);

		for (session in sessions) {
			if (session.interest.forget(npc.id)) {
				freeSlot(session, npc.id);
			}
		}
		stats.respawns++;
	}

	static function sendSnapshot(session:Session):Void {
		var avatar = session.avatar;

		found.resize(0);
		tree.queryCircle(avatar.x, avatar.y, VIEW_RADIUS, found);
		// Nearest first, and no more than the view has slots for.
		if (found.length > VIEW_SLOTS) {
			found.sort((a, b) -> {
				var da:Float = (a.x - avatar.x) * (a.x - avatar.x) + (a.y - avatar.y) * (a.y - avatar.y);
				var db:Float = (b.x - avatar.x) * (b.x - avatar.x) + (b.y - avatar.y) * (b.y - avatar.y);
				return da < db ? -1 : (da > db ? 1 : 0);
			});
			found.resize(VIEW_SLOTS);
			stats.crowded++;
		}

		for (node in found) {
			session.interest.add(node.value.id);
		}
		// Left before entered, so a slot a departure frees can go straight to
		// an arrival.
		session.interest.commit(id -> {
			var slot:Int = session.usedSlots.nextClearBit(0);
			session.usedSlots.set(slot, true);
			session.slotOf.set(id, slot);
			stats.entered++;
		}, id -> {
			freeSlot(session, id);
			stats.left++;
		});

		var snapshot = new ByteArray();
		snapshot.length = VIEW_SLOTS * SLOT_BYTES;
		for (id => slot in session.slotOf) {
			var entity = entities[id];
			snapshot.position = slot * SLOT_BYTES;
			snapshot.writeShort(id + 1);
			snapshot.writeShort(entity.generation);
			snapshot.writeShort(Math.round(entity.x));
			snapshot.writeShort(Math.round(entity.y));
		}
		snapshot.position = 0;

		var tick:Int = sim.tick;
		session.sent.put(tick, snapshot);
		// The last snapshot this client confirmed having, if it is still here;
		// otherwise the whole thing.
		var baseline:Null<ByteArray> = session.acknowledged ? session.sent.get(session.acknowledgedTick) : null;

		var message = new ByteArray();
		message.writeByte(MessageType.SNAPSHOT);
		message.writeInt(tick);
		message.writeInt(baseline == null ? -1 : session.acknowledgedTick);
		message.writeInt(checksum(snapshot));
		ByteDelta.encode(snapshot, baseline, message);
		send(session.socket, message);

		stats.snapshots++;
		stats.fullBytes += snapshot.length;
		stats.sentBytes += message.length;
		if (baseline == null) {
			stats.whole++;
		}
	}

	static function freeSlot(session:Session, id:Int):Void {
		var slot:Null<Int> = session.slotOf.get(id);
		if (slot != null) {
			session.usedSlots.clear(slot);
			session.slotOf.remove(id);
		}
	}

	static function spawn():Entity {
		var entity = new Entity(entities.length, random(Std.int(WORLD)), random(Std.int(WORLD)));
		entities.push(entity);
		return entity;
	}

	static function aim(entity:Entity, speed:Float):Void {
		var angle:Float = random(360) * Math.PI / 180;
		entity.vx = Math.cos(angle) * speed;
		entity.vy = Math.sin(angle) * speed;
	}

	static inline function clamp(value:Float):Float {
		return value < 0 ? 0 : (value >= WORLD ? WORLD - 0.001 : value);
	}

	// --- Shared -----------------------------------------------------------

	public static function send(socket:Socket, message:ByteArray):Void {
		message.position = 0;
		socket.writeBytes(FrameCodec.encode(message));
		socket.flush();
	}

	/** Adler-32: sums only, so it reads the same on every target. **/
	public static function checksum(bytes:ByteArray):Int {
		var a:Int = 1;
		var b:Int = 0;
		for (i in 0...bytes.length) {
			a = (a + bytes[i]) % 65521;
			b = (b + a) % 65521;
		}
		return (b << 16) | a;
	}

	public static function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	static function report(bots:Array<Bot>):Bool {
		var decoded:Int = 0;
		var mismatches:Int = 0;
		var missing:Int = 0;
		var welcomed:Int = 0;
		var sawThemselves:Int = 0;
		var fewest:Int = 0x7FFFFFFF;
		for (bot in bots) {
			decoded += bot.snapshots;
			mismatches += bot.mismatches;
			missing += bot.missingBaselines;
			if (bot.id >= 0) {
				welcomed++;
			}
			if (bot.sawItself) {
				sawThemselves++;
			}
			if (bot.snapshots < fewest) {
				fewest = bot.snapshots;
			}
		}

		var ratio:Float = stats.fullBytes == 0 ? 0 : Math.round(stats.sentBytes / stats.fullBytes * 1000) / 10;
		Sys.println('arena: ${SECONDS}s, $BOTS bots, $NPCS npcs, ${sim.tick} steps at 20 Hz');
		Sys.println('  logins: ${stats.logins} of $BOTS, $LOGINS_AT_ONCE at a time; ${stats.refusedLogins} refused; ${stats.refusedAtAdmission} turned away at admission');
		Sys.println('  interest: ${stats.entered} entered, ${stats.left} left, ${stats.respawns} respawned under an old id, ${stats.crowded} views trimmed to $VIEW_SLOTS');
		Sys.println('  snapshots: ${stats.snapshots} sent (${stats.whole} whole), ${stats.sentBytes} bytes where whole ones would be ${stats.fullBytes} ($ratio%)');
		Sys.println('  bots: $decoded decoded (fewest $fewest), $mismatches checksum mismatches, $missing missing baselines, $sawThemselves of $BOTS saw themselves');

		var failures:Array<String> = [];
		if (welcomed != BOTS) failures.push('only $welcomed of $BOTS bots got in');
		if (mismatches > 0) failures.push('$mismatches snapshots decoded to something other than what was sent');
		if (missing > 0) failures.push('$missing snapshots named a baseline the bot did not have');
		if (sawThemselves != BOTS) failures.push('only $sawThemselves of $BOTS bots saw themselves');
		if (fewest < 40) failures.push('a bot decoded only $fewest snapshots');
		if (stats.refusedAtAdmission != 1) failures.push('admit turned away ${stats.refusedAtAdmission} connections, not the one extra');
		if (stats.sentBytes >= stats.fullBytes) failures.push('deltas were no smaller than whole snapshots');

		for (failure in failures) {
			Sys.println('FAILED: $failure');
		}
		if (failures.length == 0) {
			Sys.println('OK: every snapshot every bot decoded matched what the server built.');
		}
		return failures.length == 0;
	}
}

enum abstract MessageType(Int) from Int to Int {
	var LOGIN = 1;
	var INPUT = 2;
	var ACK = 3;
	var WELCOME = 10;
	var SNAPSHOT = 11;
}

class Entity {
	public var id:Int;
	public var generation:Int = 0;
	public var x:Float;
	public var y:Float;
	public var vx:Float = 0;
	public var vy:Float = 0;
	public var node:QuadTreeNode<Entity>;

	public function new(id:Int, x:Float, y:Float) {
		this.id = id;
		this.x = x;
		this.y = y;
		this.node = new QuadTreeNode<Entity>(x, y, this);
	}
}

/** What the server keeps for one connection. **/
class Session {
	public var socket:Socket;
	public var address:String;
	public var frames:FrameCodec = new FrameCodec();
	public var login:ConcurrencyPermit = null;
	public var authenticating:Int = 0;
	public var avatar:Entity = null;
	public var dx:Int = 0;
	public var dy:Int = 0;

	public var interest:InterestSet = new InterestSet();
	public var slotOf:Map<Int, Int> = new Map();
	public var usedSlots:BitSet = new BitSet(ArenaSample.VIEW_SLOTS);
	public var sent:SequenceRing<ByteArray> = new SequenceRing<ByteArray>(ArenaSample.HISTORY);
	public var acknowledged:Bool = false;
	public var acknowledgedTick:Int = 0;

	public function new(socket:Socket) {
		this.socket = socket;
		this.address = socket.remoteAddress;
	}
}

/** A headless client: logs in, wanders, and checks every snapshot it decodes. **/
class Bot {
	public var id:Int = -1;
	public var snapshots:Int = 0;
	public var mismatches:Int = 0;
	public var missingBaselines:Int = 0;
	public var sawItself:Bool = false;

	var socket:Socket = new Socket();
	var frames:FrameCodec = new FrameCodec();
	var received:SequenceRing<ByteArray> = new SequenceRing<ByteArray>(ArenaSample.HISTORY);

	public function new(port:Int) {
		socket.addEventListener(Event.CONNECT, _ -> {
			var login = new ByteArray();
			login.writeByte(MessageType.LOGIN);
			ArenaSample.send(socket, login);
		});
		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			var incoming = new ByteArray();
			socket.readBytes(incoming);
			frames.feed(incoming);
			var message:Null<ByteArray> = frames.next();
			while (message != null) {
				receive(message);
				message = frames.next();
			}
		});
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> {});
		socket.connect("127.0.0.1", port);
	}

	function receive(message:ByteArray):Void {
		var type:MessageType = message.readUnsignedByte();
		switch (type) {
			case WELCOME:
				id = message.readUnsignedShort();
			case SNAPSHOT:
				var tick:Int = message.readInt();
				var baselineTick:Int = message.readInt();
				var expected:Int = message.readInt();

				var baseline:Null<ByteArray> = null;
				if (baselineTick != -1) {
					baseline = received.get(baselineTick);
					if (baseline == null) {
						missingBaselines++;
						return;
					}
				}

				var snapshot:ByteArray = ByteDelta.decode(message, baseline, ArenaSample.VIEW_SLOTS * ArenaSample.SLOT_BYTES);
				if (ArenaSample.checksum(snapshot) != expected) {
					mismatches++;
					return;
				}
				received.put(tick, snapshot);
				snapshots++;

				var ack = new ByteArray();
				ack.writeByte(MessageType.ACK);
				ack.writeInt(tick);
				ArenaSample.send(socket, ack);

				for (slot in 0...ArenaSample.VIEW_SLOTS) {
					snapshot.position = slot * ArenaSample.SLOT_BYTES;
					if (snapshot.readUnsignedShort() == id + 1) {
						sawItself = true;
					}
				}

				// Now and then, a new direction.
				if (snapshots % 10 == 0) {
					var input = new ByteArray();
					input.writeByte(MessageType.INPUT);
					input.writeByte(ArenaSample.random(3) - 1);
					input.writeByte(ArenaSample.random(3) - 1);
					ArenaSample.send(socket, input);
				}
			default:
		}
	}
}

class Stats {
	public var logins:Int = 0;
	public var refusedLogins:Int = 0;
	public var refusedAtAdmission:Int = 0;
	public var entered:Int = 0;
	public var left:Int = 0;
	public var respawns:Int = 0;
	public var crowded:Int = 0;
	public var snapshots:Int = 0;
	public var whole:Int = 0;
	public var sentBytes:Int = 0;
	public var fullBytes:Int = 0;

	public function new() {}
}
