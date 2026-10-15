package crossbyte.db.kv;

import crossbyte.db.kv.KVStoreChecks.bytes;
import crossbyte.errors.ArgumentError;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

typedef KVProfile = {
	var name:String;
	var level:Int;
	var tags:Array<String>;
}

/**
	`KVRepo` over the memory store, on every target: typed values under a
	prefix, and the refusals of a record written in another format (another
	JSON schema) or in bytes that are no value. The `RPCStruct` codec is
	`KVRepoRPCTest`'s.
**/
class KVRepoTest extends utest.Test {
	public function testJsonValuesGoUnderTheirPrefix():Void {
		var store = new MemoryKVStore();
		var profiles = new KVRepo<KVProfile>(store, "profiles/", KVCodecs.json());
		var saved = profiles.put("alice", {name: "Alice", level: 1, tags: ["new"]});
		Assert.equals("alice", saved.key);
		Assert.equals(1.0, saved.revision);
		Assert.notNull(store.get("profiles/alice"), "kept under the prefix in the store");

		var read = Require.notNull(profiles.get("alice"));
		Assert.equals("alice", read.key);
		Assert.equals("Alice", read.value.name);
		Assert.equals(1, read.value.level);
		Assert.same(["new"], read.value.tags);

		Require.notNull(profiles.compareAndSet("alice", {name: "Alice", level: 2, tags: []}, saved.revision));
		Assert.isNull(profiles.compareAndSet("alice", {name: "Alice", level: 3, tags: []}, saved.revision));
		Assert.equals(2, Require.notNull(profiles.get("alice")).value.level);
		Assert.isNull(profiles.get("bob"));
		Assert.isFalse(profiles.compareAndDelete("alice", 1));
		Assert.isTrue(profiles.delete("alice"));
		Assert.isNull(profiles.get("alice"));
	}

	public function testScansAreTheRepositorysOwn():Void {
		var store = new MemoryKVStore();
		var users = new KVRepo<String>(store, "users/", KVCodecs.text());
		var groups = new KVRepo<String>(store, "groups/", KVCodecs.text());
		store.put("usersx", bytes("not a user"));

		for (name in ["carol", "alice", "bob", "dave"]) {
			users.put(name, name.toUpperCase());
		}

		groups.put("admins", "ADMINS");

		var first = users.scan({limit: 2});
		Assert.same(["alice", "bob"], [for (item in first.items) item.key]);
		Assert.same(["ALICE", "BOB"], [for (item in first.items) item.value]);
		Assert.equals("bob", first.next, "the next page starts after a key of the repository's own");

		var second = users.scan({limit: 2, startAfter: first.next});
		Assert.same(["carol", "dave"], [for (item in second.items) item.key]);
		Assert.isNull(second.next);
		Assert.same(["bob", "carol"], [for (item in users.scan({startAt: "b", endBefore: "d"}).items) item.key]);
		Assert.same(["carol"], [for (item in users.scan({prefix: "c"}).items) item.key]);
		Assert.same(["admins"], [for (item in groups.scan().items) item.key]);

		Assert.raises(() -> users.scan({includeTombstones: true}), ArgumentError);
	}

	public function testAJsonSchemaRaisedRefusesTheOldShape():Void {
		var store = new MemoryKVStore();
		var v1 = new KVRepo<KVProfile>(store, "p/", KVCodecs.json(1));
		v1.put("a", {name: "A", level: 1, tags: []});
		var v2 = new KVRepo<KVProfile>(store, "p/", KVCodecs.json(2));
		var refused:KVError = Require.notNull(KVStoreChecks.kvError(() -> v2.get("a")));
		Assert.equals(KVErrorKind.SchemaMismatch, refused.kind);
		Assert.equals("p/a", refused.key);
		Assert.equals(1, Require.notNull(v1.get("a")).value.level);
	}

	public function testBytesThatAreNoValueAreRefused():Void {
		var store = new MemoryKVStore();
		var profiles = new KVRepo<KVProfile>(store, "profiles/", KVCodecs.json());
		store.put("profiles/broken", bytes("{\"name\":"));
		Assert.equals(KVErrorKind.Undecodable, Require.notNull(KVStoreChecks.kvError(() -> profiles.get("broken"))).kind);

		// The same bytes are a value of a codec that reads any.
		var raw = new KVRepo<Bytes>(store, "profiles/", KVCodecs.bytes());
		Assert.equals("{\"name\":", Require.notNull(raw.get("broken")).value.toString());

		// Text that is not UTF-8, where the decoder tells: natively and on the
		// jvm it reads leniently instead. On PHP it read as the bytes it was.
		#if (js || hl || eval || php)
		var names = new KVRepo<String>(store, "names/", KVCodecs.text());
		store.put("names/cut", Bytes.ofHex("41e282"));
		Assert.equals(KVErrorKind.Undecodable, Require.notNull(KVStoreChecks.kvError(() -> names.get("cut"))).kind);
		#end
	}

	public function testRefusesWhatItCannotUse():Void {
		var store = new MemoryKVStore();
		Assert.raises(() -> new KVRepo<String>(null, "a/", KVCodecs.text()), ArgumentError);
		Assert.raises(() -> new KVRepo<String>(store, "a/", null), ArgumentError);
		Assert.raises(() -> new KVRepo<String>(store, "a" + String.fromCharCode(0), KVCodecs.text()), ArgumentError);

		// The whole key is the store's to refuse.
		var tight = new KVRepo<String>(new MemoryKVStore({maxKeyBytes: 7}), "abcde/", KVCodecs.text());
		tight.put("f", "fits");
		Assert.raises(() -> tight.put("fg", "does not"), ArgumentError);
	}
}
