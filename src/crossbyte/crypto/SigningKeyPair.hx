package crossbyte.crypto;

import haxe.io.Bytes;

/**
 * A native signing keypair consisting of a public verification key and a
 * private signing key.
 */
typedef SigningKeyPair = {
	/**
	 * The public verification key bytes.
	 */
	var publicKey:Bytes;

	/**
	 * The private signing key bytes.
	 */
	var secretKey:Bytes;
}
