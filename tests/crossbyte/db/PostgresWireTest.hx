package crossbyte.db;

import crossbyte.db.postgres.PostgresParameter;
import crossbyte.db.postgres._internal.PostgresWire;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;
import crossbyte.test.Require;

/**
 * The byte protocol between the driver and the libpq bridge, tested without a
 * server because it is pure encoding — and because it is the half of the
 * parameter work that can be proven on a machine with no PostgreSQL on it.
 *
 * The cases that matter are the ones the previous path got wrong: a value with
 * a NUL byte in it, a value that is not valid UTF-8, and the difference between
 * SQL NULL and an empty value.
 */
class PostgresWireTest extends utest.Test {
	public function testNullIsDistinctFromAnEmptyValue():Void {
		var withNull:Bytes = PostgresWire.encodeParameters([Null]);
		var withEmpty:Bytes = PostgresWire.encodeParameters([Text("")]);

		// -1 against 0. Collapsing these makes a NULL and an empty string the
		// same row, which only shows up much later in a WHERE clause.
		Assert.equals(-1, __intAt(withNull, 8));
		Assert.equals(0, __intAt(withEmpty, 8));
		Assert.equals(12, withNull.length);
		Assert.equals(12, withEmpty.length);
	}

	public function testBinaryParameterCarriesNulBytesIntact():Void {
		var payload:Bytes = Bytes.ofHex("00FF00001A00");
		var encoded:Bytes = PostgresWire.encodeParameters([Binary(payload)]);

		Assert.equals(1, __intAt(encoded, 0));
		Assert.equals(PostgresWire.FORMAT_BINARY, __intAt(encoded, 4));
		Assert.equals(payload.length, __intAt(encoded, 8));

		// The whole point. Escaping this into SQL text truncates it at byte
		// zero, so a ciphertext blob became a one-byte blob without an error.
		Assert.equals(payload.toHex(), encoded.sub(12, payload.length).toHex());
	}

	public function testTextParameterIsSentVerbatim():Void {
		// Neither quoted nor escaped: it never enters the statement text, so
		// doing either would corrupt the value rather than protect anything.
		var awkward:String = "o'brien; DROP TABLE accounts --";
		var encoded:Bytes = PostgresWire.encodeParameters([Text(awkward)]);
		var expected:Bytes = Bytes.ofString(awkward);

		Assert.equals(PostgresWire.FORMAT_TEXT, __intAt(encoded, 4));
		Assert.equals(expected.length, __intAt(encoded, 8));
		Assert.equals(expected.toHex(), encoded.sub(12, expected.length).toHex());
	}

	public function testParametersKeepTheirOrder():Void {
		var encoded:Bytes = PostgresWire.encodeParameters([Text("a"), Null, Binary(Bytes.ofHex("41"))]);

		Assert.equals(3, __intAt(encoded, 0));
		// $1 text "a"
		Assert.equals(PostgresWire.FORMAT_TEXT, __intAt(encoded, 4));
		Assert.equals(1, __intAt(encoded, 8));
		// $2 null
		Assert.equals(-1, __intAt(encoded, 17));
		// $3 binary
		Assert.equals(PostgresWire.FORMAT_BINARY, __intAt(encoded, 21));
		Assert.equals(1, __intAt(encoded, 25));
	}

	public function testResultDecodesRowsFieldsAndCounts():Void {
		var block = new ResultBlock();
		block.ok(3, 7, ["id", "payload"]);
		block.row([Bytes.ofString("1"), Bytes.ofHex("00AA00")]);
		block.row([Bytes.ofString("2"), null]);

		var result = PostgresWire.decodeResult(block.finish());

		Assert.same(["id", "payload"], result.fields);
		Assert.equals(3, result.affectedRows);
		Assert.equals(7, result.lastInsertRowID);
		Assert.equals(2, result.rows.length);
		Assert.equals("1", result.rows[0][0].toString());
		// Survives as bytes. JSON could not represent this at all.
		Assert.equals("00aa00", result.rows[0][1].toHex());
		Assert.isNull(result.rows[1][1]);
	}

	public function testResultCarriesValuesThatAreNotValidUtf8():Void {
		var invalid:Bytes = Bytes.ofHex("C3281FFE");
		var block = new ResultBlock();
		block.ok(1, 0, ["blob"]);
		block.row([invalid]);

		var result = PostgresWire.decodeResult(block.finish());

		Assert.equals(invalid.toHex(), result.rows[0][0].toHex());
	}

	public function testErrorBlockRaisesTheServerMessage():Void {
		var out = new BytesBuffer();
		__writeInt(out, PostgresWire.STATUS_ERROR);
		var message:Bytes = Bytes.ofString('relation "nope" does not exist');
		__writeInt(out, message.length);
		out.addBytes(message, 0, message.length);

		var raised:String = null;

		try {
			PostgresWire.decodeResult(out.getBytes());
		} catch (e:Dynamic) {
			raised = Std.string(e);
		}

		Require.notNull(raised);
		Assert.isTrue(raised.indexOf("does not exist") >= 0);
	}

	public function testTruncatedBlockRaisesRatherThanReadingPastTheEnd():Void {
		var block = new ResultBlock();
		block.ok(0, 0, ["id"]);
		block.row([Bytes.ofString("1")]);
		var full:Bytes = block.finish();

		// A bridge and a decoder that disagree is a native out-of-bounds read
		// if this is not checked, which is a crash rather than an exception.
		for (cut in 1...6) {
			Assert.raises(() -> PostgresWire.decodeResult(full.sub(0, full.length - cut)));
		}

		Assert.raises(() -> PostgresWire.decodeResult(Bytes.alloc(0)));
		Assert.raises(() -> PostgresWire.decodeResult(null));
	}

	public function testHugeLengthCannotOverflowTheBoundsCheck():Void {
		// The cursor guarded reads with `position + count > length`, which
		// overflows Int for a large count and wraps negative -- and a negative
		// is not greater than the length, so the check passed and the read ran
		// off the end of the buffer. Measured before the fix: this exact block,
		// twenty bytes long, segfaulted the process. The class exists to make
		// a disagreement between bridge and decoder an exception; the one
		// arithmetic that could defeat it lived inside the check itself.
		var raw = new BytesBuffer();
		__int(raw, PostgresWire.STATUS_OK);
		__int(raw, 0);
		__int(raw, 0);
		__int(raw, 1);
		__int(raw, 2147483647);

		Assert.raises(() -> PostgresWire.decodeResult(raw.getBytes()));
	}

	public function testRowCountCannotAllocateWithoutConsumingTheBlock():Void {
		// A row of no columns reads nothing, so with fieldCount at zero the
		// row loop was bounded by the count alone rather than by the block
		// containing anything: twenty bytes claiming twenty million rows built
		// twenty million of them in 1.4 seconds, and the count could have said
		// two billion. Every other shape limits itself, because each column
		// costs at least its four-byte length and the cursor runs out.
		var raw = new BytesBuffer();
		__int(raw, PostgresWire.STATUS_OK);
		__int(raw, 0);
		__int(raw, 0);
		__int(raw, 0);
		__int(raw, 20000000);

		Assert.raises(() -> PostgresWire.decodeResult(raw.getBytes()));
	}

	public function testNegativeCountsAreRefused():Void {
		// Haxe iterates 0...negative zero times, so these decoded as an empty
		// result rather than as the malformed block they are.
		var fields = new BytesBuffer();
		__int(fields, PostgresWire.STATUS_OK);
		__int(fields, 0);
		__int(fields, 0);
		__int(fields, -1);
		Assert.raises(() -> PostgresWire.decodeResult(fields.getBytes()));

		var rows = new BytesBuffer();
		__int(rows, PostgresWire.STATUS_OK);
		__int(rows, 0);
		__int(rows, 0);
		__int(rows, 0);
		__int(rows, -5);
		Assert.raises(() -> PostgresWire.decodeResult(rows.getBytes()));
	}

	private static function __int(out:BytesBuffer, value:Int):Void {
		out.addByte(value & 0xFF);
		out.addByte((value >> 8) & 0xFF);
		out.addByte((value >> 16) & 0xFF);
		out.addByte((value >> 24) & 0xFF);
	}

	public function testByteaHexRoundTrips():Void {
		var payload:Bytes = Bytes.ofHex("00DEADBEEF00");

		Assert.equals("\\x00deadbeef00", PostgresWire.encodeByteaHex(payload));
		Assert.equals(payload.toHex(), PostgresWire.decodeByteaHex(Bytes.ofString("\\x00deadbeef00")).toHex());
		// Upper case is equally valid coming back.
		Assert.equals(payload.toHex(), PostgresWire.decodeByteaHex(Bytes.ofString("\\x00DEADBEEF00")).toHex());
		Assert.equals("\\x", PostgresWire.encodeByteaHex(null));
		Assert.equals(0, PostgresWire.decodeByteaHex(Bytes.ofString("\\x")).length);
	}

	public function testByteaDecodeLeavesTextAlone():Void {
		// A text column may legitimately begin "\x", and mangling it into bytes
		// would corrupt a perfectly ordinary string.
		var notHex:Bytes = Bytes.ofString("\\xzz");
		Assert.equals(notHex.toHex(), PostgresWire.decodeByteaHex(notHex).toHex());

		var oddLength:Bytes = Bytes.ofString("\\xabc");
		Assert.equals(oddLength.toHex(), PostgresWire.decodeByteaHex(oddLength).toHex());

		var plain:Bytes = Bytes.ofString("hello");
		Assert.equals(plain.toHex(), PostgresWire.decodeByteaHex(plain).toHex());
		Assert.isNull(PostgresWire.decodeByteaHex(null));
	}

	private static function __intAt(data:Bytes, offset:Int):Int {
		return data.get(offset) | (data.get(offset + 1) << 8) | (data.get(offset + 2) << 16) | (data.get(offset + 3) << 24);
	}

	private static function __writeInt(out:BytesBuffer, value:Int):Void {
		out.addByte(value & 0xFF);
		out.addByte((value >> 8) & 0xFF);
		out.addByte((value >> 16) & 0xFF);
		out.addByte((value >> 24) & 0xFF);
	}
}

/**
 * Builds a result block the way the bridge does, so the decoder is tested
 * against the documented format rather than against itself.
 */
private class ResultBlock {
	private var __head:BytesBuffer = new BytesBuffer();
	private var __rows:BytesBuffer = new BytesBuffer();
	private var __rowCount:Int = 0;
	private var __fieldCount:Int = 0;

	public function new() {}

	public function ok(affectedRows:Int, lastInsertRowID:Int, fields:Array<String>):Void {
		__writeInt(__head, PostgresWire.STATUS_OK);
		__writeInt(__head, affectedRows);
		__writeInt(__head, lastInsertRowID);
		__writeInt(__head, fields.length);
		__fieldCount = fields.length;

		for (name in fields) {
			var bytes:Bytes = Bytes.ofString(name);
			__writeInt(__head, bytes.length);
			__head.addBytes(bytes, 0, bytes.length);
		}
	}

	public function row(values:Array<Null<Bytes>>):Void {
		for (value in values) {
			if (value == null) {
				__writeInt(__rows, -1);
			} else {
				__writeInt(__rows, value.length);
				__rows.addBytes(value, 0, value.length);
			}
		}

		__rowCount++;
	}

	public function finish():Bytes {
		var out = new BytesBuffer();
		var head:Bytes = __head.getBytes();
		out.addBytes(head, 0, head.length);
		__writeInt(out, __rowCount);
		var rows:Bytes = __rows.getBytes();
		out.addBytes(rows, 0, rows.length);
		return out.getBytes();
	}

	private static function __writeInt(out:BytesBuffer, value:Int):Void {
		out.addByte(value & 0xFF);
		out.addByte((value >> 8) & 0xFF);
		out.addByte((value >> 16) & 0xFF);
		out.addByte((value >> 24) & 0xFF);
	}
}
