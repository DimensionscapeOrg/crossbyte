package crossbyte.net.ice;

import crossbyte.crypto.SecureRandom;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;

/**
	The short-term credentials one peer publishes for the other to authenticate
	with.

	Every connectivity check is signed, and this is what signs it. The two
	halves do different jobs: the fragment says *who* a check is for, and the
	password proves it was not written by somebody else. Both are exchanged the
	same way the candidates are -- over whatever channel already brought the two
	peers together.

	## Why a check has to be signed at all

	A check is a datagram arriving at a port from an address nobody has
	confirmed yet. Without a signature, anything that can see one can answer
	one, and a peer would nominate a path to whoever replied first. Worse, an
	unauthenticated binding request is a way to make a peer send traffic to an
	address of the sender's choosing.

	## Which password signs what

	The sender keys a check with the *receiver's* password, because it is
	authenticating to them with the credential they published. A receiver
	therefore verifies with its own. Responses are keyed the same way -- the
	responder's own password -- so the two directions of one exchange use one
	key and each side needs only the other's published half.
**/
class IceCredentials {
	/**
		RFC 8445 section 5.3 gives the fragment at least 24 bits of randomness
		and the password at least 128, expressed as a minimum character count
		over the alphabet below.
	**/
	public static inline var MIN_FRAGMENT_LENGTH:Int = 4;

	public static inline var MIN_PASSWORD_LENGTH:Int = 22;

	/**
		The alphabet ICE allows, from RFC 8839: unreserved URI characters plus
		`+` and `/`. Sixty-four of them, so each character carries exactly six
		bits and the entropy is countable rather than estimated.
	**/
	private static inline var ALPHABET:String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	private static inline var GENERATED_FRAGMENT_LENGTH:Int = 8;
	private static inline var GENERATED_PASSWORD_LENGTH:Int = 24;

	/**
		Whether credentials can be generated here.

		Aliases `SecureRandom`, because that is the only thing `generate` needs
		and the only reason it could fail. Credentials that an attacker can
		guess are not credentials, so there is no lesser source to fall back to
		-- a caller on a target without one has to be given them rather than
		make them.
	**/
	public static var isSupported(default, null):Bool = SecureRandom.isSupported;

	/** Identifies which session a check belongs to. Not a secret. **/
	public var usernameFragment(default, null):String;

	/** Signs and verifies checks. Never sent. **/
	public var password(default, null):String;

	/**
		@throws ArgumentError if either half is shorter than ICE permits. The
		lengths are the RFC's minimum entropy restated in characters, so a
		shorter one is not merely unusual -- it is guessable.
	**/
	public function new(usernameFragment:String, password:String) {
		if (usernameFragment == null || usernameFragment.length < MIN_FRAGMENT_LENGTH) {
			throw new ArgumentError("An ICE username fragment must be at least " + MIN_FRAGMENT_LENGTH + " characters.");
		}

		if (password == null || password.length < MIN_PASSWORD_LENGTH) {
			throw new ArgumentError("An ICE password must be at least " + MIN_PASSWORD_LENGTH
				+ " characters, which is how RFC 8445 states 128 bits of randomness. A shorter one is guessable.");
		}

		this.usernameFragment = usernameFragment;
		this.password = password;
	}

	/**
		A fresh pair from the platform CSPRNG.

		@throws String on a target with no secure source, rather than falling
		back to one that only looks random. Check `isSupported`, or construct
		them directly from credentials a peer sent.
	**/
	public static function generate():IceCredentials {
		return new IceCredentials(__random(GENERATED_FRAGMENT_LENGTH), __random(GENERATED_PASSWORD_LENGTH));
	}

	/**
		The `USERNAME` a check carries, which is the receiver's fragment then
		the sender's, joined by a colon.

		That order is not arbitrary and is worth stating, because reversing it
		produces something that looks right and works nowhere: a receiver
		matches the *first* half against its own fragment to decide whether a
		check is for it at all. Reversed, every check is addressed to the wrong
		session and gets dropped by a peer that is behaving correctly.

		@param receiver The peer being checked.
		@param sender The peer doing the checking.
	**/
	public static function username(receiver:IceCredentials, sender:IceCredentials):String {
		if (receiver == null || sender == null) {
			throw new ArgumentError("Both peers' credentials are needed to address a check.");
		}

		return receiver.usernameFragment + ":" + sender.usernameFragment;
	}

	/**
		The fragment a `USERNAME` is addressed to, or null if it is malformed.

		Used to tell whether an arriving check belongs to this session before
		spending a signature verification on it.
	**/
	public static function receiverFragment(username:String):Null<String> {
		if (username == null) {
			return null;
		}

		var at = username.indexOf(":");

		if (at <= 0) {
			return null;
		}

		return username.substring(0, at);
	}

	/** Whether an arriving check names this peer. **/
	public function addressedByUsername(username:String):Bool {
		return receiverFragment(username) == usernameFragment;
	}

	public function toString():String {
		// The password is deliberately absent. A credential that reaches a log
		// is a credential that has been published.
		return "IceCredentials(" + usernameFragment + ")";
	}

	@:noCompletion private static function __random(length:Int):String {
		var bytes:ByteArray = SecureRandom.getSecureRandomBytes(length);
		var out = new StringBuf();

		bytes.position = 0;

		for (_ in 0...length) {
			// Six bits per character, taken from the low end of each byte. The
			// alphabet is exactly 64 long, so this is a straight mapping with
			// no modulo bias to reason about.
			out.add(ALPHABET.charAt(bytes.readUnsignedByte() & 0x3F));
		}

		return out.toString();
	}
}
