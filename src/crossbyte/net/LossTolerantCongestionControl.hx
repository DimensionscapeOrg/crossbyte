package crossbyte.net;

import haxe.ds.Vector;

/**
	A congestion policy for paths that lose frames to something other than
	congestion: Wi-Fi, mobile, anything with radio in it.

	It tells the two kinds of loss apart by the round trip. A queue building
	at a bottleneck stretches the round trip before it overflows, while a
	frame lost to interference leaves the round trip where it was. So on a
	loss the window becomes what the path has been delivering times the
	fastest round trip seen: what the path holds with nothing queued. Where
	the round trip is at its fastest, that is about the window as it was,
	and the loss costs little. Behind a queue it is less, by as much as the
	queue adds. Between losses the window grows as `CongestionControl`'s does.

	This is TCP Westwood's answer to a loss, with the rate measured as BBR
	measures a bottleneck's: the most delivered over the last ten
	measurements, each at least a round trip long. It is counted by
	`ReliableDatagramSocket.framesDelivered`, what the peer has whether or
	not a gap is below it, so that a gap filling is not read as a burst of
	bandwidth. Westwood+ averages instead, and an average trails a growing
	window, so every loss cut the window more: at a 20 ms round trip and 1%
	loss it held near 46 frames and 1.7 MB/s. This grew to about 230 frames
	and carried 7.0 MB/s, where the default carries 0.63; at 5% loss, 2.1
	MB/s to the default's 0.28, and at 10%, 1.0 to 0.19 -- the medians of
	six runs each.

	It still trims the window a little at each loss: frames lost on the way
	were not delivered, so the rate falls short of what was sent by about
	the loss rate. That is what limits it at 10%, and it is also what keeps
	it honest where loss is congestion. With a 208 KB receive buffer
	overflowing, it lost no more frames than the default and carried as
	much.

	A loss never takes the window below half, which is where the default
	would put it. Where a round trip is too short to measure against the
	session's own loop, as over loopback, the estimate says too little, and
	this is then as cautious as the default and no more.

	The cost is fairness. On a link shared with TCP, this backs off less than
	TCP does whenever the round trip has not grown, and a congested link with
	shallow buffers can drop frames before the round trip grows much. Use it
	where the path is known to be lossy, and the default where it is shared
	and congestion is the likelier cause of a loss.

	Like any `CongestionControl`, one instance serves one session.
**/
class LossTolerantCongestionControl extends CongestionControl {
	/**
		The shortest time a delivery rate is measured over, in seconds, however
		short the round trip. Acknowledgements bunch, and a rate taken over
		less would read a bunch as bandwidth.
	**/
	public static inline var MIN_SAMPLE_INTERVAL:Float = 0.05;

	/** How many measurements the most delivered is taken from. **/
	public static inline var SAMPLES:Int = 10;

	/**
		The most frames a second the path has delivered over any of the last
		`SAMPLES` measurements; -1 until the first is complete.
	**/
	public var deliveryRate(default, null):Float = -1;

	// The last measurements, the next to be replaced at `__sampleNext`.
	@:noCompletion private var __samples:Vector<Float> = new Vector(SAMPLES);
	@:noCompletion private var __sampleNext:Int = 0;
	@:noCompletion private var __sampleCount:Int = 0;

	// When the current measurement began, -1 before the first
	// acknowledgement, and the session's `framesDelivered` then.
	@:noCompletion private var __sampleStart:Float = -1;
	@:noCompletion private var __sampleDelivered:Float = 0;

	public function new() {
		super();
	}

	/**
		Grows the window as the default does, and once a round trip -- at
		least `MIN_SAMPLE_INTERVAL` -- measures the rate the peer received
		frames at over it.

		Not from `frames`: that is what the cumulative acknowledgement passed,
		which stands still while a lost frame is sent again and then passes a
		round trip's worth at once. Where a round trip is longer than
		`MIN_SAMPLE_INTERVAL`, a measurement that caught the jump read twice
		the rate, the most delivered held it for ten, and a loss behind a
		queue was taken for one with none.
	**/
	override public function onAcknowledged(session:ReliableDatagramSocket, frames:Int, now:Float):Void {
		super.onAcknowledged(session, frames, now);

		// The first acknowledgement only starts the clock.
		if (__sampleStart < 0) {
			__sampleStart = now;
			__sampleDelivered = session.framesDelivered;
			return;
		}

		var elapsed:Float = now - __sampleStart;
		var roundTrip:Float = session.roundTripTime;
		if (elapsed < (roundTrip > MIN_SAMPLE_INTERVAL ? roundTrip : MIN_SAMPLE_INTERVAL)) {
			return;
		}

		var delivered:Float = session.framesDelivered;
		__samples[__sampleNext] = (delivered - __sampleDelivered) / elapsed;
		__sampleNext = (__sampleNext + 1) % SAMPLES;
		if (__sampleCount < SAMPLES) {
			__sampleCount++;
		}
		var most:Float = 0;
		for (i in 0...__sampleCount) {
			if (__samples[i] > most) {
				most = __samples[i];
			}
		}
		deliveryRate = most;
		__sampleStart = now;
		__sampleDelivered = delivered;
	}

	/**
		Sets the window to what the path holds with nothing queued, but never
		below half of what it was, and never above it; `slowStartThreshold`
		goes to whichever is more, so growth doubles back to what the path
		carried. Halves, as the default does, until there is an estimate.
	**/
	override public function onLoss(session:ReliableDatagramSocket, now:Float):Void {
		var unqueued:Float = __unqueuedWindow(session);
		if (unqueued < 0) {
			super.onLoss(session, now);
			return;
		}

		var half:Float = window / 2;
		var kept:Float = unqueued < half ? half : (unqueued < window ? unqueued : window);
		var threshold:Float = unqueued > kept ? unqueued : kept;
		slowStartThreshold = threshold < CongestionControl.MIN_WINDOW ? CongestionControl.MIN_WINDOW : threshold;
		setWindow(kept);
	}

	/**
		Halves the window, as the default does -- a timeout says nothing
		arrived at all, which is no time to trust an estimate -- but sets
		`slowStartThreshold` to what the path held without a queue, so growth
		doubles back to it rather than creeping.
	**/
	override public function onTimeout(session:ReliableDatagramSocket, now:Float):Void {
		super.onTimeout(session, now);
		var unqueued:Float = __unqueuedWindow(session);
		if (unqueued > slowStartThreshold) {
			slowStartThreshold = unqueued;
		}
	}

	override public function reset():Void {
		super.reset();
		deliveryRate = -1;
		__sampleNext = 0;
		__sampleCount = 0;
		__sampleStart = -1;
		__sampleDelivered = 0;
	}

	/**
		The delivery rate times the fastest round trip, in frames, or -1 while
		either is unmeasured.
	**/
	@:noCompletion private function __unqueuedWindow(session:ReliableDatagramSocket):Float {
		var fastest:Float = session.minRoundTripTime;
		if (deliveryRate <= 0 || fastest <= 0) {
			return -1;
		}
		return deliveryRate * fastest;
	}
}
