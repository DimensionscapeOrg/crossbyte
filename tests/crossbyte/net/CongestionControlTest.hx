package crossbyte.net;

import utest.Assert;

/**
	The congestion policies on their own, fed the events a session would give
	them. No socket is opened: the session they are handed is an empty one
	carrying only the round trips a case sets, so this runs on every target.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.CongestionControl)
class CongestionControlTest extends utest.Test {
	// ------------------------------------------------------------- default

	public function testTheDefaultStartsAtTheInitialWindow():Void {
		var control = new CongestionControl();
		Assert.equals(10.0, control.window);
		Assert.equals(500.0, control.slowStartThreshold);
	}

	public function testBelowTheThresholdEachFrameAcknowledgedAddsOne():Void {
		var control = new CongestionControl();
		var session = sessionWith(0.02, 0.02);

		// A window's worth acknowledged, a round trip: the window doubles.
		control.onAcknowledged(session, 10, 0);
		Assert.equals(20.0, control.window);
	}

	public function testAboveTheThresholdAWindowOfFramesAddsAboutOne():Void {
		var control = new CongestionControl();
		var session = sessionWith(0.02, 0.02);
		control.onLoss(session, 0);
		Assert.equals(5.0, control.window);

		control.onAcknowledged(session, 5, 0);
		Assert.isTrue(control.window > 5.9 && control.window < 6.0, 'a round trip above the threshold took five frames to ${control.window}');
	}

	public function testALossOrATimeoutHalvesTheWindowAndSetsTheThreshold():Void {
		var session = sessionWith(0.02, 0.02);

		var lost = new CongestionControl();
		lost.onLoss(session, 0);
		Assert.equals(5.0, lost.window);
		Assert.equals(5.0, lost.slowStartThreshold);

		var timedOut = new CongestionControl();
		timedOut.onTimeout(session, 0);
		Assert.equals(5.0, timedOut.window);
		Assert.equals(5.0, timedOut.slowStartThreshold);
	}

	public function testTheWindowStaysBetweenItsBounds():Void {
		var session = sessionWith(0.02, 0.02);
		var control = new CongestionControl();

		for (_ in 0...20) {
			control.onLoss(session, 0);
		}
		Assert.equals(CongestionControl.MIN_WINDOW * 1.0, control.window, "losses took the window below where a session can recover");

		control.reset();
		for (_ in 0...100) {
			control.onAcknowledged(session, 50, 0);
		}
		Assert.equals(CongestionControl.MAX_WINDOW * 1.0, control.window, "the window grew past anything a peer will hold");
	}

	public function testResetStartsOver():Void {
		var session = sessionWith(0.02, 0.02);
		var control = new CongestionControl();
		control.onAcknowledged(session, 30, 0);
		control.onLoss(session, 0);

		control.reset();
		Assert.equals(10.0, control.window);
		Assert.equals(500.0, control.slowStartThreshold);
	}

	// ------------------------------------------------------ loss tolerant

	public function testLossTolerantHalvesUntilItHasMeasuredARate():Void {
		var control = new LossTolerantCongestionControl();
		control.onLoss(sessionWith(0.02, 0.02), 0);
		Assert.equals(5.0, control.window);
		Assert.equals(-1.0, control.deliveryRate);
	}

	public function testLossTolerantKeepsItsWindowThroughALossWithNoQueueBehindIt():Void {
		// The round trip is at its fastest, so nothing is queued: the path is
		// carrying what the window sends, and a loss says nothing about that.
		var session = sessionWith(0.02, 0.02);
		var control = new LossTolerantCongestionControl();
		var before = cruise(control, session, 0.02);

		// Nearly all of it: the rate is the most delivered over the last few
		// measurements, a round trip or two behind a window that has been
		// growing. The default would keep half.
		control.onLoss(session, 0);
		Assert.isTrue(control.window > before * 0.9, 'a loss with no queue took the window from $before to ${control.window}');
		Assert.isTrue(control.window <= before, "a loss raised the window");
	}

	public function testLossTolerantDrainsAQueueTheRoundTripShows():Void {
		// The round trip is half again its fastest: a third of what is in
		// flight is queued, and that third is what goes.
		var session = sessionWith(0.03, 0.02);
		var control = new LossTolerantCongestionControl();
		var before = cruise(control, session, 0.03);

		control.onLoss(session, 0);
		var share = control.window / before;
		Assert.isTrue(share > 0.6 && share < 0.72, 'a loss behind a queue left ${Math.round(share * 100)}% of the window');
	}

	public function testLossTolerantNeverCutsDeeperThanTheDefault():Void {
		// The round trip is four times its fastest, so three quarters is
		// queue -- or the round trip is too short to measure against the
		// session's own loop, which reads the same. Either way the window
		// goes no lower than the default would take it.
		var session = sessionWith(0.08, 0.02);
		var control = new LossTolerantCongestionControl();
		var before = cruise(control, session, 0.08);

		control.onLoss(session, 0);
		Assert.equals(before / 2, control.window);
	}

	public function testLossTolerantRemembersTheBestOfItsRecentMeasurements():Void {
		// A round trip in which the peer received almost nothing -- the
		// application paused, or a burst went missing -- is not what the path
		// can carry: the most delivered over the last few still is.
		var session = sessionWith(0.02, 0.02);
		var control = new LossTolerantCongestionControl();
		var before = cruise(control, session, 0.02);
		var now = 1.0;
		for (_ in 0...4) {
			now += 0.02;
			session.__framesDelivered += 1;
			control.onAcknowledged(session, 1, now);
		}

		control.onLoss(session, now);
		Assert.isTrue(control.window > before * 0.9, 'one poor measurement took the window from $before to ${control.window}');
	}

	public function testLossTolerantIsNotFooledByAGapFilling():Void {
		// A round trip longer than a measurement's least, and twice its
		// fastest, so half of what is in flight is queue. Every fifth round
		// trip a loss holds half of each of the next two round trips' frames
		// behind a gap, and the third passes them all at once. The peer
		// received frames at one rate throughout.
		var session = sessionWith(0.1, 0.05);
		var control = new LossTolerantCongestionControl();
		control.window = 100;
		control.slowStartThreshold = 100;
		var now = 0.0;
		var held = 0;
		var round = 0;
		while (now < 3.0) {
			var frames = Std.int(control.window);
			session.__framesDelivered += frames;
			var passed = switch (round % 5) {
				case 1, 2:
					held += frames - (frames >> 1);
					frames >> 1;
				case 3:
					var all = frames + held;
					held = 0;
					all;
				default:
					frames;
			}
			control.onAcknowledged(session, passed, now);
			now += 0.1;
			round++;
		}

		// Measured by what the acknowledgement passed, the round trip that
		// caught the gap filling read twice the rate, the most delivered kept
		// it, and this loss kept 97% of the window behind a queue of half.
		var before = control.window;
		control.onLoss(session, 0);
		Assert.equals(before / 2, control.window, "a gap filling was read as bandwidth");
	}

	public function testLossTolerantNeverRaisesTheWindowOnALoss():Void {
		var session = sessionWith(0.02, 0.02);
		var control = new LossTolerantCongestionControl();
		cruise(control, session, 0.02);
		var unqueued = control.deliveryRate * 0.02;

		// Something else took the window down, below what the path carries.
		control.window = unqueued / 4;
		control.onLoss(session, 0);
		Assert.equals(unqueued / 4, control.window);
		Assert.isTrue(Math.abs(control.slowStartThreshold - unqueued) < 0.001, "growth was not aimed back at what the path carries");
	}

	public function testLossTolerantHalvesOnATimeoutButAimsGrowthAtWhatThePathCarried():Void {
		var session = sessionWith(0.02, 0.02);
		var control = new LossTolerantCongestionControl();
		var before = cruise(control, session, 0.02);

		control.onTimeout(session, 0);
		Assert.equals(before / 2, control.window);
		Assert.isTrue(control.slowStartThreshold > before * 0.7, 'after a timeout, growth creeps from ${control.slowStartThreshold}');
	}

	public function testLossTolerantResetForgetsTheRate():Void {
		var session = sessionWith(0.02, 0.02);
		var control = new LossTolerantCongestionControl();
		cruise(control, session, 0.02);
		Assert.isTrue(control.deliveryRate > 0);

		control.reset();
		Assert.equals(-1.0, control.deliveryRate);
		control.onLoss(session, 0);
		Assert.equals(5.0, control.window, "a reset policy used a rate from before");
	}

	// ------------------------------------------------------------- helpers

	/**
		A session that has measured these round trips and delivered nothing:
		all a policy reads from one. Made empty, so every field a policy reads
		is set here -- on eval an unset one is null, not zero.
	**/
	private static function sessionWith(smoothed:Float, fastest:Float):ReliableDatagramSocket {
		var session:ReliableDatagramSocket = Type.createEmptyInstance(ReliableDatagramSocket);
		session.__smoothedRtt = smoothed;
		session.__minRtt = fastest;
		session.__framesDelivered = 0;
		return session;
	}

	/**
		A second of steady sending: a window of a hundred frames, above the
		threshold, each round trip acknowledging a window's worth. Returns the
		window it ends on.
	**/
	private static function cruise(control:CongestionControl, session:ReliableDatagramSocket, roundTrip:Float):Float {
		control.window = 100;
		control.slowStartThreshold = 100;
		var now = 0.0;
		while (now < 1.0) {
			var frames = Std.int(control.window);
			session.__framesDelivered += frames;
			control.onAcknowledged(session, frames, now);
			now += roundTrip;
		}
		return control.window;
	}
}
