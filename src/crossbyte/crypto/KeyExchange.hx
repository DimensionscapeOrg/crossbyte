package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * A key-exchange keypair (X25519 keys in libsodium's `crypto_kx` format).
 */
typedef KeyExchangeKeyPair = {
	/**
	 * The 32-byte public key.
	 */
	var publicKey:Bytes;

	/**
	 * The 32-byte secret key.
	 */
	var secretKey:Bytes;
}

/**
 * Directional session keys produced by a key exchange.
 */
typedef SessionKeys = {
	/**
	 * The 32-byte receive key: decrypts data sent by the peer.
	 */
	var rx:Bytes;

	/**
	 * The 32-byte transmit key: encrypts data sent to the peer.
	 */
	var tx:Bytes;
}

/**
 * Session-key agreement over X25519 (libsodium `crypto_kx`).
 *
 * The client and server each derive an (rx, tx) pair from their own keypair
 * and the peer's public key; `client.rx == server.tx` and
 * `client.tx == server.rx`. The derived keys are suitable directly as `Aead`
 * keys.
 *
 * Available on supported native `cpp` targets via the statically linked
 * libsodium backend.
 */
class KeyExchange {
	/**
	 * Length in bytes of a public key.
	 */
	public static inline final PUBLIC_KEY_BYTES:Int = 32;

	/**
	 * Length in bytes of a secret key.
	 */
	public static inline final SECRET_KEY_BYTES:Int = 32;

	/**
	 * Length in bytes of each derived session key.
	 */
	public static inline final SESSION_KEY_BYTES:Int = 32;

	/**
	 * Returns `true` when the native key-exchange backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Generates a fresh key-exchange keypair.
	 */
	public static function keypair():KeyExchangeKeyPair {
		#if cpp
		SodiumGlue.ensureAvailable();

		var publicKey = Bytes.alloc(PUBLIC_KEY_BYTES);
		var secretKey = Bytes.alloc(SECRET_KEY_BYTES);
		var rc = NativeSodium.kxKeypair(SodiumGlue.ptr(publicKey), SodiumGlue.ptr(secretKey));
		if (rc != 0) {
			throw "libsodium crypto_kx_keypair failed: " + rc;
		}
		return {publicKey: publicKey, secretKey: secretKey};
		#else
		throw "KeyExchange is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Derives the client-side session keys against a server public key.
	 */
	public static function clientSessionKeys(clientPublicKey:Bytes, clientSecretKey:Bytes, serverPublicKey:Bytes):SessionKeys {
		__validateKeys(clientPublicKey, clientSecretKey, serverPublicKey);

		#if cpp
		SodiumGlue.ensureAvailable();

		var rx = Bytes.alloc(SESSION_KEY_BYTES);
		var tx = Bytes.alloc(SESSION_KEY_BYTES);
		var rc = NativeSodium.kxClientSessionKeys(SodiumGlue.ptr(rx), SodiumGlue.ptr(tx), SodiumGlue.cptr(clientPublicKey),
			SodiumGlue.cptr(clientSecretKey), SodiumGlue.cptr(serverPublicKey));
		if (rc != 0) {
			throw "libsodium crypto_kx_client_session_keys rejected the server public key: " + rc;
		}
		return {rx: rx, tx: tx};
		#else
		throw "KeyExchange is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Derives the server-side session keys against a client public key.
	 */
	public static function serverSessionKeys(serverPublicKey:Bytes, serverSecretKey:Bytes, clientPublicKey:Bytes):SessionKeys {
		__validateKeys(serverPublicKey, serverSecretKey, clientPublicKey);

		#if cpp
		SodiumGlue.ensureAvailable();

		var rx = Bytes.alloc(SESSION_KEY_BYTES);
		var tx = Bytes.alloc(SESSION_KEY_BYTES);
		var rc = NativeSodium.kxServerSessionKeys(SodiumGlue.ptr(rx), SodiumGlue.ptr(tx), SodiumGlue.cptr(serverPublicKey),
			SodiumGlue.cptr(serverSecretKey), SodiumGlue.cptr(clientPublicKey));
		if (rc != 0) {
			throw "libsodium crypto_kx_server_session_keys rejected the client public key: " + rc;
		}
		return {rx: rx, tx: tx};
		#else
		throw "KeyExchange is only available on supported native cpp targets.";
		#end
	}

	@:noCompletion
	private static function __validateKeys(ownPublicKey:Bytes, ownSecretKey:Bytes, peerPublicKey:Bytes):Void {
		if (ownPublicKey == null || ownPublicKey.length != PUBLIC_KEY_BYTES) {
			throw "publicKey must be " + PUBLIC_KEY_BYTES + " bytes";
		}
		if (ownSecretKey == null || ownSecretKey.length != SECRET_KEY_BYTES) {
			throw "secretKey must be " + SECRET_KEY_BYTES + " bytes";
		}
		if (peerPublicKey == null || peerPublicKey.length != PUBLIC_KEY_BYTES) {
			throw "peer publicKey must be " + PUBLIC_KEY_BYTES + " bytes";
		}
	}
}
