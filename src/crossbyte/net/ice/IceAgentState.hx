package crossbyte.net.ice;

/**
	Where the agent as a whole has got to.

	Deliberately coarse. The detail lives per pair; this is what a caller
	watches to know whether it has a usable path, and it is the same set of
	words WebRTC exposes so a developer moving between them is not learning two
	vocabularies for one idea.
**/
enum abstract IceAgentState(Int) {
	/** Gathering and exchanging. Nothing has been sent yet. **/
	var NEW = 0;

	/** Working down the check list. **/
	var CHECKING = 1;

	/** A pair has been nominated, and traffic can use it. **/
	var CONNECTED = 2;

	/** Every pair failed, or the whole attempt ran out of time. **/
	var FAILED = 3;

	/** Shut down by the caller. **/
	var CLOSED = 4;
}
