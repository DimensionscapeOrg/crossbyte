package crossbyte._internal.php;

/**
 * Raised when a FastCGI exchange runs past its deadline.
 *
 * A type of its own so the request handler can tell a backend that is not
 * answering from one that answered badly. Those deserve different statuses --
 * 504 against 502 -- and before this there was no way to tell them apart,
 * because there was no deadline: a php-fpm that accepted a connection and then
 * said nothing held the runtime thread for as long as it cared to, which on a
 * server serving every connection from one tick means forever, for everyone.
 */
class PHPTimeout {
	/** Seconds the exchange was allowed before it was abandoned. */
	public final seconds:Float;

	/** What the bridge was doing when the deadline passed. */
	public final phase:String;

	public function new(seconds:Float, phase:String) {
		this.seconds = seconds;
		this.phase = phase;
	}

	public function toString():String {
		return "PHP backend did not respond within " + seconds + "s (" + phase + ")";
	}
}
