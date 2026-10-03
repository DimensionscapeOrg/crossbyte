package crossbyte.crypto;

import haxe.io.Bytes;

/**
 * A native signing keypair consisting of a public verification key and a
 * private signing key.
 */
@:structInit
final class SigningKeyPair {
	/**
	 * The public verification key bytes.
	 */
	public var publicKey:Bytes;

	/**
	 * The private signing key bytes.
	 */
	public var secretKey:Bytes;
}
