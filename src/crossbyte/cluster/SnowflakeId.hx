package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import haxe.Int64;

/**
	Identifiers that stay unique across machines without asking anyone.

	`Seq32` counts one stream. The moment a second process is answering for
	the same world, a counter each is not enough: two nodes hand out the same
	number for different things and nothing downstream can tell them apart.
	Asking a database for the next value works and costs a round trip on the
	hot path, which is the thing horizontal scale was meant to avoid.

	So the node's identity goes in the identifier. Sixty four bits: forty one
	of milliseconds, ten of node, twelve of sequence -- a thousand and
	twenty four nodes, four thousand and ninety six identifiers per
	millisecond each, and roughly sixty nine years from whatever epoch is
	chosen. They sort by time, which makes them usable as a key in anything
	ordered.

	```haxe
	var ids = new SnowflakeId(nodeId);
	var id:Int64 = ids.next();
	```

	## The clock

	Two things go wrong with a clock, and neither may produce a duplicate.

	It can go backwards, when something adjusts it or the machine resumes
	from sleep. This keeps issuing from the last millisecond it saw rather
	than reissuing a range it has already spent, so a backward step costs
	nothing and duplicates nothing.

	It can also stand still long enough for a millisecond's sequence to run
	out, under a burst. Rather than block -- a server's loop is the worst
	place to sleep -- the generator moves to the next millisecond and carries
	on, so identifiers may run briefly ahead of the wall clock under load.
	They remain unique and ordered, which is what they are for; they are not
	a timestamp, and `timestampOf` is for diagnostics rather than for telling
	the time.
**/
class SnowflakeId {
	/** Bits of node identity: 1024 nodes. **/
	public static inline var NODE_BITS:Int = 10;

	/** Bits of per-millisecond sequence: 4096 identifiers each. **/
	public static inline var SEQUENCE_BITS:Int = 12;

	/** The largest node number this partition allows. **/
	public static inline var MAX_NODE:Int = (1 << NODE_BITS) - 1;

	/** The most identifiers one node may issue in a single millisecond. **/
	public static inline var MAX_SEQUENCE:Int = (1 << SEQUENCE_BITS) - 1;

	/**
		The default epoch, in milliseconds: 2020-01-01T00:00:00Z.

		Forty one bits of milliseconds is about sixty nine years, so counting
		from a recent date rather than 1970 is what keeps the range useful.
		Every node in a cluster must agree on it; identifiers minted under
		two different epochs are not comparable and may collide.
	**/
	public static inline var DEFAULT_EPOCH_MS:Float = 1577836800000.0;

	/** Which node these identifiers say they came from. **/
	public var node(default, null):Int;

	/** The epoch these count from, in milliseconds. **/
	public var epochMs(default, null):Float;

	private var __clock:Void->Float;
	private var __lastMs:Float = -1;
	private var __sequence:Int = 0;

	/**
		@param node This node's number, 0 to `MAX_NODE`. It has to be unique
		       in the cluster; nothing here can check that for you.
		@param epochMs What the identifiers count from. Every node must agree.
		@param clock Milliseconds since the Unix epoch. Supply one in a test
		       rather than waiting for real time to pass.
	**/
	public function new(node:Int, epochMs:Float = DEFAULT_EPOCH_MS, ?clock:Void->Float) {
		if (node < 0 || node > MAX_NODE) {
			throw new ArgumentError("A node number must be between 0 and " + MAX_NODE + "; got " + node + ".");
		}

		this.node = node;
		this.epochMs = epochMs;
		this.__clock = clock == null ? function():Float return Date.now().getTime() : clock;
	}

	/** The next identifier. Never equal to one already returned. **/
	public function next():Int64 {
		var now:Float = __clock();

		if (now > __lastMs) {
			__lastMs = now;
			__sequence = 0;
		} else {
			// Either the clock went back, or it has not moved and this
			// millisecond is still being spent. Both are handled by staying
			// where we are rather than reissuing anything.
			__sequence++;

			if (__sequence > MAX_SEQUENCE) {
				__lastMs += 1;
				__sequence = 0;
			}
		}

		var elapsed:Int64 = Int64.fromFloat(__lastMs - epochMs);
		return (elapsed << (NODE_BITS + SEQUENCE_BITS)) | (Int64.ofInt(node) << SEQUENCE_BITS) | Int64.ofInt(__sequence);
	}

	/** When an identifier was minted, in milliseconds since `epochMs`. **/
	public static function elapsedOf(id:Int64):Int64 {
		return id >>> (NODE_BITS + SEQUENCE_BITS);
	}

	/**
		When an identifier was minted, in milliseconds since the Unix epoch.

		For diagnostics. Under a burst the generator runs ahead of the wall
		clock on purpose, so this is when the identifier says it was made
		rather than when it was.
	**/
	public static function timestampOf(id:Int64, epochMs:Float = DEFAULT_EPOCH_MS):Float {
		return Int64.toInt(elapsedOf(id)) + epochMs;
	}

	/** Which node minted an identifier. **/
	public static function nodeOf(id:Int64):Int {
		return Int64.toInt((id >>> SEQUENCE_BITS) & Int64.ofInt(MAX_NODE));
	}

	/** Where in its millisecond an identifier fell. **/
	public static function sequenceOf(id:Int64):Int {
		return Int64.toInt(id & Int64.ofInt(MAX_SEQUENCE));
	}
}
