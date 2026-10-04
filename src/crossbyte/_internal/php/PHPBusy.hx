package crossbyte._internal.php;

/**
	Raised when a PHP exchange is refused because the bridge already has as
	many as it will hold: `maxExchanges` with the backend, and a queue of
	`PHPBridge.MAX_WAITING` behind them.

	A type of its own, as `PHPTimeout` is, so the request handler can answer
	a server that is busy, `503 Service Unavailable`, apart from a backend
	that answered badly, `502`, and tell them apart without reading the
	message.
**/
class PHPBusy {
	/** Exchanges the bridge had with the backend when this one came. **/
	public final inFlight:Int;

	/** Exchanges already waiting for one of them to end. **/
	public final waiting:Int;

	public function new(inFlight:Int, waiting:Int) {
		this.inFlight = inFlight;
		this.waiting = waiting;
	}

	public function toString():String {
		return "PHP backend busy: " + inFlight + " requests with it and " + waiting + " waiting";
	}
}
