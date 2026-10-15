package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.io.ByteArray;
import crossbyte.rpc.RPCPatchTest.PatchPlayer;
import crossbyte.rpc.RPCPatchTest.PatchShip;
import crossbyte.rpc.RPCPatchTest.PatchTag;
import crossbyte.rpc.RPCPatchTest.PatchWide;
import crossbyte.rpc._internal.RPCSizes;
import crossbyte.utils.Hash;
import haxe.Int64;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
	The size a codec works out for a patch, and for a whole value, without
	writing it (what a budgeted map patch weighs an entry by) is the length
	its writer writes, over many random values of every kind of field: the
	bit section (masks past 32 fields, the full bit, quantized and ranged
	fields, Bools, presence bits), varints, strings of every width of
	character, bytes, absent fields of each kind in both layouts, arrays
	(fixed, of strings, of absent elements, of structures, runs of bits),
	maps, enums, nested structures patched field by field, and anonymous
	structures.

	Each value is checked three ways: as an `RPCPatch` writes it (its full
	bit, then its mask), as an entry of a map patch (no full bit, after its
	key), and whole, as `RPCCodec.write` writes it.
**/
class RPCPatchSizeTest extends utest.Test {
	static inline final ROUNDS:Int = 600;

	var seed:Int = 0;

	public function testNumbersAreSizedAsWritten():Void {
		seed = 1;
		check(RPCCodecs.of(SizeNumbers), randomNumbers, "SizeNumbers");
	}

	public function testTextIsSizedAsWritten():Void {
		seed = 2;
		check(RPCCodecs.of(SizeText), randomText, "SizeText");
	}

	public function testCollectionsAreSizedAsWritten():Void {
		seed = 3;
		check(RPCCodecs.of(SizeCollections), randomCollections, "SizeCollections");
	}

	public function testEnumsAreSizedAsWritten():Void {
		seed = 4;
		check(RPCCodecs.of(SizeEnums), randomEnums, "SizeEnums");
	}

	public function testNestedAndAnonymousStructuresAreSizedAsWritten():Void {
		seed = 5;
		check(RPCCodecs.of(SizeNest), randomNest, "SizeNest");
	}

	public function testTheBitLayoutIsSizedAsWritten():Void {
		seed = 6;
		check(RPCCodecs.of(SizeBits), randomBits, "SizeBits");
	}

	public function testAWideStructureInTheBitLayoutIsSizedAsWritten():Void {
		seed = 7;
		check(RPCCodecs.of(SizeWide), randomWide, "SizeWide");
	}

	public function testTheOtherSuitesStructuresAreSizedAsWritten():Void {
		seed = 8;
		check(RPCCodecs.of(PatchWide), randomPatchWide, "PatchWide");
		check(RPCCodecs.of(PatchPlayer), randomPatchPlayer, "PatchPlayer");
		check(RPCCodecs.of(PatchShip), randomPatchShip, "PatchShip");
	}

	/**
		A string's size, as `putString` writes it, for text of every kind: of
		one byte a character, two, three, four (a pair), and on the targets
		whose strings are UTF-16, half a pair alone.
	**/
	public function testAStringIsSizedAsItIsWritten():Void {
		seed = 9;
		final frame = new crossbyte.rpc._internal.RPCFrame(64);
		var wrong:Int = 0;
		var first:String = "";
		for (_ in 0...ROUNDS * 4) {
			final text:String = string();
			frame.beginScratch();
			frame.putString(text);
			if (frame.position != RPCSizes.string(text)) {
				if (wrong++ == 0) {
					first = 'written ${frame.position}, sized ${RPCSizes.string(text)}: ' + units(text);
				}
			}
		}
		Assert.equals(0, wrong, first);
	}

	/**
		Sizing a patch allocates nothing (natively and on the jvm), whatever
		its fields hold: strings of any width, values that may be absent, the
		bit layout, enums with arguments, nested and anonymous structures,
		arrays. (A map's size is its keys walked, as its writer walks them.)
	**/
	public function testSizingAllocatesNothing():Void {
		if (!crossbyte.test.AllocationMeter.SUPPORTED) {
			Assert.pass();
			return;
		}
		seed = 10;
		final sizers:Array<Void->Void> = [
			sizer(RPCCodecs.of(SizeNumbers), randomNumbers),
			sizer(RPCCodecs.of(SizeText), randomText),
			sizer(RPCCodecs.of(SizeEnums), randomEnums),
			sizer(RPCCodecs.of(SizeNest), randomNest),
			sizer(RPCCodecs.of(SizeBits), randomBits),
			sizer(RPCCodecs.of(SizeWide), randomWide)
		];
		final op = () -> {
			for (each in sizers) {
				each();
			}
		};
		for (_ in 0...2000) {
			op();
		}
		final reading = crossbyte.test.AllocationMeter.measure(op, 500);
		Assert.isTrue(reading.perOperation == 0, 'sizing allocated $reading');
		Assert.isTrue(sized > 0);
	}

	/** What the sizers add up, kept so that no size goes unused. **/
	var sized:Int = 0;

	/** Sizes, in turn, each of 64 random patches and their values whole, into `sized`. **/
	function sizer<T>(codec:RPCCodec<T>, random:Null<T>->T):Void->Void {
		final wide:Bool = codec.fieldCount > 32;
		final bases:Array<T> = [];
		final currents:Array<T> = [];
		final masks:Array<Int> = [];
		final highs:Array<Int> = [];
		for (_ in 0...64) {
			final base:T = random(null);
			final current:T = random(base);
			bases.push(base);
			currents.push(current);
			masks.push(codec.__mask(base, current));
			highs.push(wide ? codec.__maskHigh(base, current) : 0);
		}
		final at:Array<Int> = [0];
		return () -> {
			final i:Int = at[0];
			at[0] = (i + 1) & 63;
			sized = (sized + codec.__patchSize(bases[i], currents[i], masks[i], highs[i], -1) + codec.__size(currents[i])) & 0xFFFFFF;
		};
	}

	// ------------------------------------------------------------ the check

	/**
		Over `ROUNDS` random pairs of values, a base (one in eight `null`)
		and a current one that keeps about half of its fields, each sized
		three ways against what is written.
	**/
	function check<T>(codec:RPCCodec<T>, random:Null<T>->T, name:String):Void {
		final wide:Bool = codec.fieldCount > 32;
		var wrong:Int = 0;
		var first:String = "";
		var checked:Int = 0;
		final out = new ByteArray();
		final baseMap = new IntMap<T>();
		final currentMap = new IntMap<T>();
		final baseStrings = new StringMap<T>();
		final currentStrings = new StringMap<T>();
		final mapPatch = new RPCMapPatch<T>(codec);
		final stringPatch = new RPCStringMapPatch<T>(codec);
		final note = (what:String, written:Int, sized:Int) -> {
			if (written != sized && wrong++ == 0) {
				first = '$name round $checked, $what: written $written, sized $sized';
			}
		};
		for (round in 0...ROUNDS) {
			checked = round;
			final base:Null<T> = below(8) == 0 ? null : random(null);
			final current:T = random(base);
			final from:T = base == null ? codec.__default() : base;
			final mask:Int = codec.__mask(from, current);
			final high:Int = wide ? codec.__maskHigh(from, current) : 0;

			// As an argument: its full bit, then its mask.
			out.length = 0;
			out.position = 0;
			new RPCPatch<T>(codec).diff(base, current).write(out);
			note("patch", out.length, codec.__patchSize(from, current, mask, high, base == null ? 1 : 0));

			// As a map patch's entry, after its key: no full bit.
			final key:Int = int();
			final keys = new IdList();
			keys.push(key);
			currentMap.clear();
			currentMap.set(key, current);
			baseMap.clear();
			if (base != null) {
				baseMap.set(key, base);
			}
			mapPatch.diffKeys(base == null ? null : baseMap, base == null ? null : keys, currentMap, keys);
			out.length = 0;
			out.position = 0;
			mapPatch.write(out);
			final carried:Bool = base == null || mask != 0 || high != 0;
			note("map entry", out.length, 3 + (carried ? RPCSizes.varInt(key) + codec.__patchSize(from, current, mask, high, -1) : 0));

			final text:String = string();
			currentStrings.clear();
			currentStrings.set(text, current);
			baseStrings.clear();
			if (base != null) {
				baseStrings.set(text, base);
			}
			stringPatch.diffKeys(base == null ? null : baseStrings, base == null ? null : [text], currentStrings, [text]);
			out.length = 0;
			out.position = 0;
			stringPatch.write(out);
			note("string map entry", out.length, 3 + (carried ? RPCSizes.string(text) + codec.__patchSize(from, current, mask, high, -1) : 0));

			// Whole.
			out.length = 0;
			out.position = 0;
			codec.write(current, out);
			note("whole", out.length, codec.__size(current));
		}
		Assert.equals(0, wrong, first);
	}

	// ------------------------------------------------------------ random values

	function randomNumbers(base:Null<SizeNumbers>):SizeNumbers {
		final v = new SizeNumbers();
		final b:SizeNumbers = base == null ? new SizeNumbers() : base;
		v.i = keep() ? b.i : int();
		v.big = keep() ? b.big : Int64.make(int(), int());
		v.flag = keep() ? b.flag : below(2) == 0;
		v.f = keep() ? b.f : float();
		v.single = keep() ? b.single : float();
		v.i8 = keep() ? b.i8 : below(256) - 128;
		v.u8 = keep() ? b.u8 : below(256);
		v.i16 = keep() ? b.i16 : below(65536) - 32768;
		v.u16 = keep() ? b.u16 : below(65536);
		v.vu = keep() ? b.vu : int();
		v.vi = keep() ? b.vi : int();
		v.u = keep() ? b.u : int();
		v.level = keep() ? b.level : (below(2) == 0 ? SizeLevel.Low : SizeLevel.High);
		v.maybeInt = keep() ? b.maybeInt : (below(3) == 0 ? null : int());
		v.maybeVu = keep() ? b.maybeVu : (below(3) == 0 ? null : (int() : VarUInt));
		v.maybeVi = keep() ? b.maybeVi : (below(3) == 0 ? null : (int() : VarInt));
		v.maybeFloat = keep() ? b.maybeFloat : (below(3) == 0 ? null : float());
		v.maybeFlag = keep() ? b.maybeFlag : (below(3) == 0 ? null : below(2) == 0);
		v.maybeBig = keep() ? b.maybeBig : (below(3) == 0 ? null : Int64.make(int(), int()));
		return v;
	}

	function randomText(base:Null<SizeText>):SizeText {
		final v = new SizeText();
		final b:SizeText = base == null ? new SizeText() : base;
		v.text = keep() ? b.text : string();
		v.data = keep() ? b.data : bytes();
		v.name = keep() ? b.name : (string() : SizeName);
		v.maybeText = keep() ? b.maybeText : (below(3) == 0 ? null : string());
		v.maybeData = keep() ? b.maybeData : (below(3) == 0 ? null : bytes());
		return v;
	}

	function randomCollections(base:Null<SizeCollections>):SizeCollections {
		final v = new SizeCollections();
		final b:SizeCollections = base == null ? new SizeCollections() : base;
		v.ints = keep() ? b.ints : [for (_ in 0...count()) int()];
		v.texts = keep() ? b.texts : [for (_ in 0...count()) string()];
		v.maybes = keep() ? b.maybes : [for (_ in 0...count()) below(3) == 0 ? null : int()];
		v.points = keep() ? b.points : [for (_ in 0...count()) point()];
		v.items = keep() ? b.items : [for (_ in 0...count()) item()];
		v.flags = keep() ? b.flags : [for (_ in 0...count()) flags()];
		v.maybeBits = keep() ? b.maybeBits : [for (_ in 0...count()) maybeBits()];
		if (keep()) {
			v.byId = b.byId;
		} else {
			for (_ in 0...count()) {
				v.byId.set(int(), string());
			}
		}
		if (keep()) {
			v.counts = b.counts;
		} else {
			for (_ in 0...count()) {
				v.counts.set(string(), int());
			}
		}
		if (keep()) {
			v.items2 = b.items2;
		} else {
			for (_ in 0...count()) {
				v.items2.set(int(), item());
			}
		}
		if (keep()) {
			v.maybeCounts = b.maybeCounts;
		} else {
			for (_ in 0...count()) {
				v.maybeCounts.set(string(), below(3) == 0 ? null : int());
			}
		}
		v.maybeTexts = keep() ? b.maybeTexts : (below(3) == 0 ? null : [for (_ in 0...count()) string()]);
		v.opts = keep() ? b.opts : [for (_ in 0...count()) optFixed()];
		v.maybeOpt = keep() ? b.maybeOpt : (below(3) == 0 ? null : optFixed());
		return v;
	}

	function randomEnums(base:Null<SizeEnums>):SizeEnums {
		final v = new SizeEnums();
		final b:SizeEnums = base == null ? new SizeEnums() : base;
		v.tag = keep() ? b.tag : tag();
		v.color = keep() ? b.color : color();
		v.maybeTag = keep() ? b.maybeTag : (below(3) == 0 ? null : tag());
		v.maybeColor = keep() ? b.maybeColor : (below(3) == 0 ? null : color());
		v.colors = keep() ? b.colors : [for (_ in 0...count()) color()];
		v.tags = keep() ? b.tags : [for (_ in 0...count()) tag()];
		return v;
	}

	function randomNest(base:Null<SizeNest>):SizeNest {
		final v = new SizeNest();
		final b:SizeNest = base == null ? new SizeNest() : base;
		v.inner = keep() ? b.inner : inner(b.inner);
		if (keep()) {
			v.deep = b.deep;
		} else {
			v.deep.inner = keep() ? b.deep.inner : inner(b.deep.inner);
			v.deep.n = keep() ? b.deep.n : below(65536);
		}
		v.eight = keep() ? b.eight : eight(b.eight);
		v.maybeInner = keep() ? b.maybeInner : (below(3) == 0 ? null : inner(null));
		v.shape = keep() ? b.shape : {x: int(), label: string()};
		v.maybeShape = keep() ? b.maybeShape : (below(3) == 0 ? null : {x: int(), note: below(2) == 0 ? null : string()});
		return v;
	}

	function randomBits(base:Null<SizeBits>):SizeBits {
		final v = new SizeBits();
		final b:SizeBits = base == null ? new SizeBits() : base;
		v.x = keep() ? b.x : quantizable();
		v.fine = keep() ? b.fine : below(1000001) / 1000000;
		v.turn = keep() ? b.turn : below(2001) / 1000 - 1;
		v.kind = keep() ? b.kind : below(4);
		v.i8 = keep() ? b.i8 : below(256) - 128;
		v.u8 = keep() ? b.u8 : below(256);
		v.i16 = keep() ? b.i16 : below(2001) - 1000;
		v.u16 = keep() ? b.u16 : below(65536);
		v.wideRange = keep() ? b.wideRange : Hash.ushr32(int(), 1);
		v.on = keep() ? b.on : below(2) == 0;
		v.maybeOn = keep() ? b.maybeOn : (below(3) == 0 ? null : below(2) == 0);
		v.maybeQ = keep() ? b.maybeQ : (below(3) == 0 ? null : below(1001) / 100);
		v.maybeR = keep() ? b.maybeR : (below(3) == 0 ? null : below(10));
		v.text = keep() ? b.text : string();
		v.maybeText = keep() ? b.maybeText : (below(3) == 0 ? null : string());
		v.count = keep() ? b.count : int();
		v.maybeCount = keep() ? b.maybeCount : (below(3) == 0 ? null : (int() : VarUInt));
		v.inner = keep() ? b.inner : inner(b.inner);
		return v;
	}

	function randomWide(base:Null<SizeWide>):SizeWide {
		final v = new SizeWide();
		final b:SizeWide = base == null ? new SizeWide() : base;
		for (i in 0...40) {
			final name:String = "f" + (i < 10 ? "0" : "") + i;
			// Through a Dynamic set one way or the other: a conditional of the
			// two kinds of value does not verify on the jvm.
			var value:Dynamic = null;
			if (keep()) {
				value = Reflect.field(b, name);
			} else {
				switch (i % 4) {
					case 0:
						value = below(1001);
					case 1:
						value = int();
					case 2:
						value = below(3) == 0 ? null : string();
					case _:
						value = below(3) == 0 ? null : below(2) == 0;
				}
			}
			Reflect.setField(v, name, value);
		}
		return v;
	}

	function randomPatchWide(base:Null<PatchWide>):PatchWide {
		final v = new PatchWide();
		final b:PatchWide = base == null ? new PatchWide() : base;
		for (i in 0...40) {
			final name:String = "f" + (i < 10 ? "0" : "") + i;
			var value:Dynamic = null;
			if (keep()) {
				value = Reflect.field(b, name);
			} else {
				value = int();
			}
			Reflect.setField(v, name, value);
		}
		return v;
	}

	function randomPatchPlayer(base:Null<PatchPlayer>):PatchPlayer {
		final v = new PatchPlayer();
		final b:PatchPlayer = base == null ? new PatchPlayer() : base;
		v.id = keep() ? b.id : int();
		v.name = keep() ? b.name : string();
		if (keep()) {
			v.position = b.position;
		} else {
			v.position.x = keep() ? b.position.x : float();
			v.position.y = keep() ? b.position.y : float();
			v.position.z = keep() ? b.position.z : float();
		}
		v.cells = keep() ? b.cells : [for (_ in 0...count()) int()];
		v.tag = keep() ? b.tag : (below(2) == 0 ? PatchTag.Plain : PatchTag.Tagged(int(), string()));
		if (keep()) {
			v.labels = b.labels;
		} else {
			for (_ in 0...count()) {
				v.labels.set(string(), int());
			}
		}
		v.spare = keep() ? b.spare : (below(3) == 0 ? null : bytes());
		v.maybe = keep() ? b.maybe : (below(3) == 0 ? null : int());
		return v;
	}

	function randomPatchShip(base:Null<PatchShip>):PatchShip {
		final v = new PatchShip();
		final b:PatchShip = base == null ? new PatchShip() : base;
		v.x = keep() ? b.x : float();
		v.y = keep() ? b.y : float();
		v.vx = keep() ? b.vx : float();
		v.vy = keep() ? b.vy : float();
		v.aimSteps = keep() ? b.aimSteps : below(65536);
		v.controls = keep() ? b.controls : below(256);
		v.engineLocked = keep() ? b.engineLocked : below(2) == 0;
		v.engineHeat = keep() ? b.engineHeat : float();
		return v;
	}

	function point():SizePoint {
		final p = new SizePoint();
		p.x = int();
		p.y = float();
		return p;
	}

	function optFixed():SizeOptFixed {
		final o = new SizeOptFixed();
		o.a = int();
		o.b = below(2) == 0 ? null : int();
		o.c = below(2) == 0 ? null : below(2) == 0;
		return o;
	}

	function item():SizeItem {
		final it = new SizeItem();
		it.id = int();
		it.label = below(3) == 0 ? null : string();
		it.count = below(3) == 0 ? null : int();
		return it;
	}

	function flags():SizeFlags {
		final f = new SizeFlags();
		f.kind = below(6);
		f.on = below(2) == 0;
		f.level = below(101) / 100;
		return f;
	}

	function maybeBits():SizeMaybeBits {
		final m = new SizeMaybeBits();
		m.a = below(7) - 3;
		m.b = below(3) == 0 ? null : below(101);
		m.on = below(3) == 0 ? null : below(2) == 0;
		return m;
	}

	function inner(from:Null<SizeInner>):SizeInner {
		final i = new SizeInner();
		final b:SizeInner = from == null ? new SizeInner() : from;
		i.a = keep() ? b.a : int();
		i.s = keep() ? b.s : string();
		i.p = keep() ? b.p : (below(3) == 0 ? null : float());
		return i;
	}

	function eight(from:SizeEight):SizeEight {
		final e = new SizeEight();
		e.a = keep() ? from.a : below(2) == 0;
		e.b = keep() ? from.b : below(256);
		e.c = keep() ? from.c : int();
		e.d = keep() ? from.d : float();
		e.e = keep() ? from.e : below(65536);
		e.f = keep() ? from.f : string();
		e.g = keep() ? from.g : (below(3) == 0 ? null : int());
		e.h = keep() ? from.h : below(256) - 128;
		return e;
	}

	function tag():SizeTag {
		return switch (below(5)) {
			case 0: SizeTag.Bare;
			case 1: SizeTag.Fixed(int(), float());
			case 2: SizeTag.Text(string(), int());
			case 3: SizeTag.Maybe(below(2) == 0 ? null : int(), below(2) == 0 ? null : string());
			case _: SizeTag.Held(point(), item());
		};
	}

	function color():SizeColor {
		return switch (below(3)) {
			case 0: SizeColor.Red;
			case 1: SizeColor.Green;
			case _: SizeColor.Blue;
		};
	}

	// ------------------------------------------------------------ randomness

	/** 32 random bits, the same on every target. **/
	function int():Int {
		seed = Hash.wrap32(seed + 1);
		final r:Int = Hash.fmix32(seed);
		// Now and then a value at the edge of a varint's width, or of an Int.
		return switch (Hash.ushr32(r, 27)) {
			case 0: EDGES[Hash.ushr32(Hash.fmix32(r), 1) % EDGES.length];
			case 1: Hash.ushr32(r, 20) - 2048;
			case 2: r & 0x7F;
			case _: r;
		};
	}

	static final EDGES:Array<Int> = [
		0, 1, -1, 63, 64, -64, -65, 127, 128, 8191, 8192, -8192, -8193, 16383, 16384, 1048575, 1048576, 2097151, 2097152, 134217727,
		134217728, 268435455, 268435456, 0x7FFFFFFF, -0x7FFFFFFF - 1, -0x7FFFFFFF, 0x40000000, -0x40000000
	];

	/** A number below `bound`. **/
	function below(bound:Int):Int {
		seed = Hash.wrap32(seed + 1);
		return Hash.ushr32(Hash.fmix32(seed), 1) % bound;
	}

	/** About half the time: keep the base's value. **/
	inline function keep():Bool {
		return below(2) == 0;
	}

	/** A short count, now and then past 127. **/
	function count():Int {
		return below(16) == 0 ? 120 + below(20) : below(6);
	}

	/** A Float, of a few magnitudes, NaN and the infinities among them. **/
	function float():Float {
		return switch (below(10)) {
			case 0: 0.0;
			case 1: Math.NaN;
			case 2: below(2) == 0 ? Math.POSITIVE_INFINITY : Math.NEGATIVE_INFINITY;
			case 3: int() / 1;
			case _: (below(2000001) - 1000000) / 1000;
		};
	}

	/** A Float a quantized field takes: anything but NaN, past its bounds too. **/
	function quantizable():Float {
		final value:Float = float();
		return value != value ? 0.5 : value;
	}

	function bytes():Bytes {
		final made = Bytes.alloc(below(8) == 0 ? 120 + below(300) : below(10));
		for (i in 0...made.length) {
			made.set(i, below(256));
		}
		return made;
	}

	/**
		Text of one to four bytes a character, short and long (past 127
		bytes, its count two bytes; past 32 and 256 units, where natively and
		on the jvm another writer takes it), and on targets whose strings are
		UTF-16, half a surrogate pair alone.
	**/
	function string():String {
		final length:Int = switch (below(8)) {
			case 0: 0;
			case 1: 30 + below(10);
			case 2: 120 + below(200);
			case _: below(12);
		};
		final ascii:Bool = below(3) == 0;
		final out = new StringBuf();
		for (_ in 0...length) {
			out.add(ascii ? String.fromCharCode(32 + below(95)) : piece());
		}
		return out.toString();
	}

	function piece():String {
		return switch (below(8)) {
			case 0: String.fromCharCode(0xE9);
			case 1: String.fromCharCode(0x7FF);
			case 2: String.fromCharCode(0x20AC);
			case 3: "\u{1F600}";
			#if !(php || neko)
			// Half a pair: on these targets a string is UTF-16 units.
			case 4: "\u{1F600}".substr(0, 1);
			case 5: "\u{1F600}".substr(1, 1);
			#end
			case _: String.fromCharCode(32 + below(95));
		};
	}

	static function units(text:String):String {
		return [for (i in 0...text.length) StringTools.hex(StringTools.fastCodeAt(text, i), 4)].join(" ");
	}
}

/** Every number kind in the byte layout, and each that may be absent. **/
class SizeNumbers implements RPCStruct {
	public var i:Int = 0;
	public var big:Int64 = Int64.make(0, 0);
	public var flag:Bool = false;
	public var f:Float = 0;
	public var single:Float32 = 0;
	public var i8:Int8 = 0;
	public var u8:UInt8 = 0;
	public var i16:Int16 = 0;
	public var u16:UInt16 = 0;
	public var vu:VarUInt = 0;
	public var vi:VarInt = 0;
	public var u:UInt = 0;
	public var level:SizeLevel = SizeLevel.Low;
	public var maybeInt:Null<Int> = null;
	public var maybeVu:Null<VarUInt> = null;
	public var maybeVi:Null<VarInt> = null;
	public var maybeFloat:Null<Float> = null;
	public var maybeFlag:Null<Bool> = null;
	public var maybeBig:Null<Int64> = null;

	public function new() {}
}

enum abstract SizeLevel(Int) {
	var Low = 1;
	var High = 300;
}

abstract SizeName(String) from String to String {}

class SizeText implements RPCStruct {
	public var text:String = "";
	public var data:Bytes = Bytes.alloc(0);
	public var name:SizeName = "";
	public var maybeText:Null<String> = null;
	public var maybeData:Null<Bytes> = null;

	public function new() {}
}

/** Two numbers: of a fixed size, put and got at a place. **/
class SizePoint implements RPCStruct {
	public var x:Int = 0;
	public var y:Float32 = 0;

	public function new() {}
}

/** A varint and two fields that may be absent: of no fixed size. **/
class SizeItem implements RPCStruct {
	public var id:VarUInt = 0;
	public var label:Null<String> = null;
	public var count:Null<Int> = null;

	public function new() {}
}

/** Fields of fixed sizes, two of them may be absent: of no fixed size itself. **/
class SizeOptFixed implements RPCStruct {
	public var a:Int = 0;
	public var b:Null<Int> = null;
	public var c:Null<Bool> = null;

	public function new() {}
}

/** All bits: an array of it is one run of them. **/
class SizeFlags implements RPCStruct {
	@:range(0, 5) public var kind:Int = 0;
	public var on:Bool = false;
	@:quantize(0, 1, 6) public var level:Float = 0;

	public function new() {}
}

/** All bits, some that may be absent. **/
class SizeMaybeBits implements RPCStruct {
	@:range(-3, 3) public var a:Int = 0;
	@:range(0, 100) public var b:Null<Int> = null;
	public var on:Null<Bool> = null;

	public function new() {}
}

class SizeCollections implements RPCStruct {
	public var ints:Array<Int> = [];
	public var texts:Array<String> = [];
	public var maybes:Array<Null<Int>> = [];
	public var points:Array<SizePoint> = [];
	public var items:Array<SizeItem> = [];
	public var flags:Array<SizeFlags> = [];
	public var maybeBits:Array<SizeMaybeBits> = [];
	public var byId:Map<Int, String> = new Map();
	public var counts:Map<String, Int> = new Map();
	public var items2:Map<Int, SizeItem> = new Map();
	public var maybeCounts:Map<String, Null<Int>> = new Map();
	public var maybeTexts:Null<Array<String>> = null;
	public var opts:Array<SizeOptFixed> = [];
	public var maybeOpt:Null<SizeOptFixed> = null;

	public function new() {}
}

enum SizeTag {
	Bare;
	Fixed(a:Int, b:Float32);
	Text(label:String, n:VarUInt);
	Maybe(x:Null<Int>, y:Null<String>);
	Held(p:SizePoint, item:SizeItem);
}

enum SizeColor {
	Red;
	Green;
	Blue;
}

class SizeEnums implements RPCStruct {
	public var tag:SizeTag = SizeTag.Bare;
	public var color:SizeColor = SizeColor.Red;
	public var maybeTag:Null<SizeTag> = null;
	public var maybeColor:Null<SizeColor> = null;
	public var colors:Array<SizeColor> = [];
	public var tags:Array<SizeTag> = [];

	public function new() {}
}

class SizeInner implements RPCStruct {
	public var a:VarInt = 0;
	public var s:String = "";
	public var p:Null<Float32> = null;

	public function new() {}
}

class SizeDeep implements RPCStruct {
	public var inner:SizeInner = new SizeInner();
	public var n:UInt16 = 0;

	public function new() {}
}

typedef SizeShape = {
	var x:Int;
	var label:String;
}

typedef SizeMaybeShape = {
	var x:VarInt;
	@:optional var note:Null<String>;
}

/** Eight fields: a mask of a whole byte, so one bit more in a nested patch is a byte more. **/
class SizeEight implements RPCStruct {
	public var a:Bool = false;
	public var b:UInt8 = 0;
	public var c:VarInt = 0;
	public var d:Float32 = 0;
	public var e:UInt16 = 0;
	public var f:String = "";
	public var g:Null<Int> = null;
	public var h:Int8 = 0;

	public function new() {}
}

class SizeNest implements RPCStruct {
	public var inner:SizeInner = new SizeInner();
	public var eight:SizeEight = new SizeEight();
	public var deep:SizeDeep = new SizeDeep();
	public var maybeInner:Null<SizeInner> = null;
	public var shape:SizeShape = {x: 0, label: ""};
	public var maybeShape:Null<SizeMaybeShape> = null;

	public function new() {}
}

/** The bit layout: quantized and ranged fields of every width, Bools, fields that may be absent, byte fields, and a nested structure. **/
class SizeBits implements RPCStruct {
	@:quantize(-1000, 1000, 16) public var x:Float = 0;
	@:quantize(0, 1, 31) public var fine:Float = 0;
	@:quantize(-1, 1, 7) public var turn:Float32 = 0;
	@:range(0, 3) public var kind:Int = 0;
	@:range(-128, 127) public var i8:Int8 = 0;
	@:range(0, 255) public var u8:UInt8 = 0;
	@:range(-1000, 1000) public var i16:Int16 = 0;
	@:range(0, 65535) public var u16:UInt16 = 0;
	@:range(7, 7) public var constant:Int = 7;
	@:range(0, 2147483647) public var wideRange:Int = 0;
	public var on:Bool = false;
	public var maybeOn:Null<Bool> = null;
	@:quantize(0, 10, 5) public var maybeQ:Null<Float> = null;
	@:range(0, 9) public var maybeR:Null<Int> = null;
	public var text:String = "";
	public var maybeText:Null<String> = null;
	public var count:Int = 0;
	public var maybeCount:Null<VarUInt> = null;
	public var inner:SizeInner = new SizeInner();

	public function new() {}
}

/** Forty fields in the bit layout: two masks. **/
class SizeWide implements RPCStruct {
	@:range(0, 1000) public var f00:Int = 0;
	public var f01:VarInt = 0;
	public var f02:Null<String> = null;
	public var f03:Null<Bool> = null;
	@:range(0, 1000) public var f04:Int = 0;
	public var f05:VarInt = 0;
	public var f06:Null<String> = null;
	public var f07:Null<Bool> = null;
	@:range(0, 1000) public var f08:Int = 0;
	public var f09:VarInt = 0;
	public var f10:Null<String> = null;
	public var f11:Null<Bool> = null;
	@:range(0, 1000) public var f12:Int = 0;
	public var f13:VarInt = 0;
	public var f14:Null<String> = null;
	public var f15:Null<Bool> = null;
	@:range(0, 1000) public var f16:Int = 0;
	public var f17:VarInt = 0;
	public var f18:Null<String> = null;
	public var f19:Null<Bool> = null;
	@:range(0, 1000) public var f20:Int = 0;
	public var f21:VarInt = 0;
	public var f22:Null<String> = null;
	public var f23:Null<Bool> = null;
	@:range(0, 1000) public var f24:Int = 0;
	public var f25:VarInt = 0;
	public var f26:Null<String> = null;
	public var f27:Null<Bool> = null;
	@:range(0, 1000) public var f28:Int = 0;
	public var f29:VarInt = 0;
	public var f30:Null<String> = null;
	public var f31:Null<Bool> = null;
	@:range(0, 1000) public var f32:Int = 0;
	public var f33:VarInt = 0;
	public var f34:Null<String> = null;
	public var f35:Null<Bool> = null;
	@:range(0, 1000) public var f36:Int = 0;
	public var f37:VarInt = 0;
	public var f38:Null<String> = null;
	public var f39:Null<Bool> = null;

	public function new() {}
}
