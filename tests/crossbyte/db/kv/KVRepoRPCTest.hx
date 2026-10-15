package crossbyte.db.kv;

import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.errors.ArgumentError;
import crossbyte.rpc.Float32;
import crossbyte.rpc.RPCCodecs;
import crossbyte.rpc.RPCStruct;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/** A ship as one build of a game keeps it. **/
class KVShip implements RPCStruct {
	public var id:Int = 0;
	public var name:String = "";
	public var hp:Float32 = 0;

	public function new() {}
}

/** The same ship a later build keeps, with a field more. **/
class KVShipWithShield implements RPCStruct {
	public var id:Int = 0;
	public var name:String = "";
	public var hp:Float32 = 0;
	public var shield:Int = 0;

	public function new() {}
}

/**
	`KVRepo` with an `RPCStruct` class's codec, on every target, PHP among
	them: the value as the RPC lane's binary, its layout kept beside it, and
	a record of another layout, written before a field was added, refused.
**/
class KVRepoRPCTest extends utest.Test {
	public function testAnRPCStructGoesAsItsBinary():Void {
		var store = new MemoryKVStore();
		var codec = KVCodecs.rpc(RPCCodecs.of(KVShip));
		Assert.equals(RPCCodecs.of(KVShip).layout, codec.schema);

		var ships = new KVRepo<KVShip>(store, "ships/", codec);
		var ship = new KVShip();
		ship.id = 7;
		ship.name = "Kestrel";
		ship.hp = 0.5;
		ships.put("7", ship);

		var record = Require.notNull(store.get("ships/7"));
		Assert.equals(codec.schema, record.schema, "the layout is kept beside the value");

		var read = Require.notNull(ships.get("7")).value;
		Assert.equals(7, read.id);
		Assert.equals("Kestrel", read.name);
		Assert.equals(0.5, (read.hp : Float));
	}

	public function testARecordOfAnotherLayoutIsRefused():Void {
		// Written by one build, read by the next, whose ship has a field
		// more: its bytes would read as a ship with the wrong fields, so the
		// record is refused, naming it.
		var store = new MemoryKVStore();
		var old = new KVRepo<KVShip>(store, "ships/", KVCodecs.rpc(RPCCodecs.of(KVShip)));
		var ship = new KVShip();
		ship.id = 1;
		old.put("1", ship);

		var current = new KVRepo<KVShipWithShield>(store, "ships/", KVCodecs.rpc(RPCCodecs.of(KVShipWithShield)));
		Assert.notEquals(RPCCodecs.of(KVShip).layout, RPCCodecs.of(KVShipWithShield).layout);
		var refused:KVError = Require.notNull(KVStoreChecks.kvError(() -> current.get("1")));
		Assert.equals(KVErrorKind.SchemaMismatch, refused.kind);
		Assert.equals("ships/1", refused.key);
		Assert.isTrue(refused.message.indexOf("ships/1") >= 0, refused.message);
		Assert.notNull(KVStoreChecks.kvError(() -> current.scan()), "a page holding it is refused too");

		// A value written without a codec has schema 0, which is not a layout.
		store.put("ships/raw", bytes("x"));
		Assert.equals(KVErrorKind.SchemaMismatch, Require.notNull(KVStoreChecks.kvError(() -> old.get("raw"))).kind);

		// Written again by the current build, it reads, and the old build
		// refuses it in turn.
		var upgraded = new KVShipWithShield();
		upgraded.id = 1;
		upgraded.shield = 3;
		current.put("1", upgraded);
		Assert.equals(3, Require.notNull(current.get("1")).value.shield);
		Assert.equals(KVErrorKind.SchemaMismatch, Require.notNull(KVStoreChecks.kvError(() -> old.get("1"))).kind);
	}

	public function testBytesThatAreNoShipAreRefused():Void {
		var store = new MemoryKVStore();
		var codec = KVCodecs.rpc(RPCCodecs.of(KVShip));
		var ships = new KVRepo<KVShip>(store, "ships/", codec);
		// The right schema over bytes that are not a ship: cut short, and
		// with bytes past its end.
		var ship = new KVShip();
		ship.name = "Kestrel";
		var whole:Bytes = codec.encode(ship);
		store.put("ships/short", whole.sub(0, whole.length - 3), codec.schema);
		var longer = Bytes.alloc(whole.length + 2);
		longer.blit(0, whole, 0, whole.length);
		store.put("ships/long", longer, codec.schema);

		Assert.equals(KVErrorKind.Undecodable, Require.notNull(KVStoreChecks.kvError(() -> ships.get("short"))).kind);
		Assert.equals(KVErrorKind.Undecodable, Require.notNull(KVStoreChecks.kvError(() -> ships.get("long"))).kind);
		Assert.raises(() -> KVCodecs.rpc(null), ArgumentError);
	}
}
