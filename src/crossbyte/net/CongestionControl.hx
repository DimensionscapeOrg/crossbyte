package crossbyte.net;

/**
	Decides how many frames a `ReliableDatagramSocket` may have in the network
	at once: sent, not acknowledged, and not reported held past a gap.

	A reliable transport that keeps sending into a path already dropping
	packets makes the drops worse, and one slow peer then costs a server the
	bandwidth of many. So a session's window grows as what it sends arrives
	and shrinks when something is lost, and this decides by how much.

	This class is the default, and is Reno as RFC 5681 has it. The window
	doubles each round trip below `slowStartThreshold`, grows by a frame a
	round trip above it, and halves when a burst of loss is found or a frame
	times out. TCP does the same, so a session shares a congested link fairly
	with everything else on it. But every loss is taken for congestion, and on
	a path that loses frames for other reasons -- radio, mostly -- the window
	stays small: at 1% loss it settles near twelve frames a round trip,
	whatever the path could carry. `LossTolerantCongestionControl` is for those
	paths.

	To decide differently, extend this class and override its events, using
	`setWindow` to keep a window in range. One instance belongs to one
	session: give each its own, through `ReliableDatagramSocket.congestionControl`
	or a server's `ReliableDatagramServerSocket.congestionControlFor`.

	The events come from the session's loop, so they must not block, and
	`onAcknowledged` comes once an acknowledgement, so keep it cheap.
	Recovery is the session's either way: which frames were lost, and when
	they go again, does not change with the policy, only how many may be out
	at once.
**/
class CongestionControl {
	/**
		The window a session starts with, in frames: RFC 6928's initial window.
		Small enough not to be a burst, and large enough that a short message
		is not paced out a frame a round trip.
	**/
	public static inline var INITIAL_WINDOW:Int = 10;

	/** The least a window can be. `setWindow` holds it here. **/
	public static inline var MIN_WINDOW:Int = 2;

	/**
		The most a window can usefully be. A session never has more frames
		outstanding than its peer will hold, 500, so a window past that would
		only have further to fall before a loss changed anything.
	**/
	public static inline var MAX_WINDOW:Int = 500;

	/**
		How many frames the session may have in the network, read before every
		frame it sends. A fraction counts as the whole frames below it.
	**/
	public var window(default, null):Float = INITIAL_WINDOW;

	/**
		Where growth changes from doubling each round trip to a frame a round
		trip. It starts at `MAX_WINDOW`, so growth doubles until the first loss
		sets it.
	**/
	public var slowStartThreshold(default, null):Float = MAX_WINDOW;

	public function new() {}

	/**
		The peer's cumulative acknowledgement has passed `frames` more of what
		the session sent. A frame the peer reported holding past a gap counts
		here too, once the gap below it fills. Called once for each
		acknowledgement that moves it, after the session has taken whatever
		round trip it measures from it, and before any loss it shows.

		Each frame opens the window by one below `slowStartThreshold`, which
		doubles it a round trip, and by `1 / window` above it, which grows it
		by a frame a round trip.
	**/
	public function onAcknowledged(session:ReliableDatagramSocket, frames:Int, now:Float):Void {
		var grown:Float = window;
		for (_ in 0...frames) {
			grown += grown < slowStartThreshold ? 1 : 1 / grown;
		}
		setWindow(grown);
	}

	/**
		A frame was lost, found from what arrived after it. Called once for a
		burst: until everything in flight at the time has been acknowledged,
		further losses are the same burst and do not call it again.

		Halves the window, and sets `slowStartThreshold` there.
	**/
	public function onLoss(session:ReliableDatagramSocket, now:Float):Void {
		halve();
	}

	/**
		A frame waited out its whole retransmission timeout, with nothing that
		arrived showing it lost. The session doubles the timeout itself.

		Halves the window, as a loss does. TCP starts again from one frame, on
		the reading that a timeout means the path is gone. Here a timeout is
		as often one frame at the end of a burst with nothing after it, and a
		frame a round trip would be a long way back from that.
	**/
	public function onTimeout(session:ReliableDatagramSocket, now:Float):Void {
		halve();
	}

	/**
		Back to where a new session starts. The session calls this when it
		closes, so a socket connected again starts over. An override should
		reset its own state and call this.
	**/
	public function reset():Void {
		window = INITIAL_WINDOW;
		slowStartThreshold = MAX_WINDOW;
	}

	/** Sets the window, held between `MIN_WINDOW` and `MAX_WINDOW`. **/
	private function setWindow(value:Float):Void {
		window = value < MIN_WINDOW ? MIN_WINDOW : (value > MAX_WINDOW ? MAX_WINDOW : value);
	}

	/** Sets `slowStartThreshold` to half the window, and the window to it. **/
	private function halve():Void {
		var half:Float = window / 2;
		slowStartThreshold = half < MIN_WINDOW ? MIN_WINDOW : half;
		window = slowStartThreshold;
	}
}
