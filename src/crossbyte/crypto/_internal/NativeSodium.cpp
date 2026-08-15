// CrossByte native libsodium bridge.
//
// This bridge links against a vendored static libsodium build on supported
// native Windows x64 targets. That keeps the crypto surface available without
// requiring a separate DLL at runtime.
//
// Every function here is a thin argument-checked pass-through: no
// cryptographic logic lives in this file.

#include <stdint.h>
#include <string>
#include <mutex>

// hxcpp build variables used in Build.xml do not always map 1:1 to the exact
// preprocessor defines exposed to custom native sources across hxcpp releases.
// Accept both the hxcpp architecture macros and the compiler's native x64
// macros so the compiled bridge and the link step agree on supported targets.
#if defined(_WIN32) && !defined(HXCPP_ARM64) && !defined(_M_ARM64) && !defined(_M_ARM64EC) && (defined(HXCPP_M64) || defined(_WIN64) || defined(_M_X64) || defined(__x86_64__))

extern "C" {
	int sodium_init(void);
	int crypto_sign_keypair(unsigned char *pk, unsigned char *sk);
	int crypto_sign_detached(unsigned char *sig, unsigned long long *siglen_p, const unsigned char *m, unsigned long long mlen, const unsigned char *sk);
	int crypto_sign_verify_detached(const unsigned char *sig, const unsigned char *m, unsigned long long mlen, const unsigned char *pk);

	int crypto_aead_xchacha20poly1305_ietf_encrypt(unsigned char *c, unsigned long long *clen_p, const unsigned char *m, unsigned long long mlen, const unsigned char *ad, unsigned long long adlen, const unsigned char *nsec, const unsigned char *npub, const unsigned char *k);
	int crypto_aead_xchacha20poly1305_ietf_decrypt(unsigned char *m, unsigned long long *mlen_p, unsigned char *nsec, const unsigned char *c, unsigned long long clen, const unsigned char *ad, unsigned long long adlen, const unsigned char *npub, const unsigned char *k);

	int crypto_scalarmult_curve25519_base(unsigned char *q, const unsigned char *n);
	int crypto_scalarmult_curve25519(unsigned char *q, const unsigned char *n, const unsigned char *p);

	int crypto_kx_keypair(unsigned char *pk, unsigned char *sk);
	int crypto_kx_client_session_keys(unsigned char *rx, unsigned char *tx, const unsigned char *client_pk, const unsigned char *client_sk, const unsigned char *server_pk);
	int crypto_kx_server_session_keys(unsigned char *rx, unsigned char *tx, const unsigned char *server_pk, const unsigned char *server_sk, const unsigned char *client_pk);

	int crypto_generichash(unsigned char *out, size_t outlen, const unsigned char *in, unsigned long long inlen, const unsigned char *key, size_t keylen);

	int crypto_kdf_hkdf_sha256_extract(unsigned char *prk, const unsigned char *salt, size_t salt_len, const unsigned char *ikm, size_t ikm_len);
	int crypto_kdf_hkdf_sha256_expand(unsigned char *out, size_t out_len, const char *ctx, size_t ctx_len, const unsigned char *prk);

	int crypto_pwhash(unsigned char *out, unsigned long long outlen, const char *passwd, unsigned long long passwdlen, const unsigned char *salt, unsigned long long opslimit, size_t memlimit, int alg);
	int crypto_pwhash_str(char *out, const char *passwd, unsigned long long passwdlen, unsigned long long opslimit, size_t memlimit);
	int crypto_pwhash_str_verify(const char *str, const char *passwd, unsigned long long passwdlen);
	int crypto_pwhash_str_needs_rehash(const char *str, unsigned long long opslimit, size_t memlimit);

	int sodium_memcmp(const void *b1_, const void *b2_, size_t len);
	void sodium_memzero(void *pnt, size_t len);
}

namespace {
	// crypto_pwhash_ALG_ARGON2ID13 in libsodium.
	const int kPwhashAlgArgon2id13 = 2;

	struct SodiumState {
		bool ready = false;
		std::string status = "libsodium has not been initialized yet.";
	};

	SodiumState g_sodium;
	std::once_flag g_sodium_once;

	void init_sodium() {
		int rc = sodium_init();
		if (rc < 0) {
			g_sodium.status = "libsodium sodium_init() failed.";
			return;
		}

		g_sodium.ready = true;
		g_sodium.status = "libsodium is available.";
	}

	inline SodiumState &state() {
		std::call_once(g_sodium_once, init_sodium);
		return g_sodium;
	}

	inline const unsigned char *opt(const uint8_t *data, int length) {
		return (length > 0) ? data : nullptr;
	}
}

extern "C" bool crossbyte_crypto_sodium_available() {
	return state().ready;
}

extern "C" const char *crossbyte_crypto_sodium_status_message() {
	return state().status.c_str();
}

extern "C" int crossbyte_crypto_ed25519_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || publicKey == nullptr || secretKey == nullptr) {
		return -1;
	}

	return crypto_sign_keypair(publicKey, secretKey);
}

extern "C" int crossbyte_crypto_ed25519_sign_detached(
	uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *secretKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || signature == nullptr || secretKey == nullptr || messageLength < 0) {
		return -1;
	}

	unsigned long long signatureLength = 0;
	return crypto_sign_detached(signature, &signatureLength, opt(message, messageLength), (unsigned long long) messageLength, secretKey);
}

extern "C" int crossbyte_crypto_ed25519_verify_detached(
	const uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *publicKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || signature == nullptr || publicKey == nullptr || messageLength < 0) {
		return -1;
	}

	return crypto_sign_verify_detached(signature, opt(message, messageLength), (unsigned long long) messageLength, publicKey);
}

extern "C" int crossbyte_crypto_aead_xchacha20poly1305_encrypt(
	uint8_t *out,
	const uint8_t *message,
	int messageLength,
	const uint8_t *additionalData,
	int additionalDataLength,
	const uint8_t *nonce,
	const uint8_t *key) {
	SodiumState &sodium = state();
	if (!sodium.ready || out == nullptr || nonce == nullptr || key == nullptr || messageLength < 0 || additionalDataLength < 0) {
		return -1;
	}

	unsigned long long ciphertextLength = 0;
	return crypto_aead_xchacha20poly1305_ietf_encrypt(
		out, &ciphertextLength,
		opt(message, messageLength), (unsigned long long) messageLength,
		opt(additionalData, additionalDataLength), (unsigned long long) additionalDataLength,
		nullptr, nonce, key);
}

extern "C" int crossbyte_crypto_aead_xchacha20poly1305_decrypt(
	uint8_t *out,
	const uint8_t *ciphertext,
	int ciphertextLength,
	const uint8_t *additionalData,
	int additionalDataLength,
	const uint8_t *nonce,
	const uint8_t *key) {
	SodiumState &sodium = state();
	if (!sodium.ready || ciphertext == nullptr || nonce == nullptr || key == nullptr || ciphertextLength < 0 || additionalDataLength < 0) {
		return -1;
	}

	unsigned long long messageLength = 0;
	return crypto_aead_xchacha20poly1305_ietf_decrypt(
		out, &messageLength, nullptr,
		ciphertext, (unsigned long long) ciphertextLength,
		opt(additionalData, additionalDataLength), (unsigned long long) additionalDataLength,
		nonce, key);
}

extern "C" int crossbyte_crypto_scalarmult_base(uint8_t *point, const uint8_t *scalar) {
	SodiumState &sodium = state();
	if (!sodium.ready || point == nullptr || scalar == nullptr) {
		return -1;
	}

	return crypto_scalarmult_curve25519_base(point, scalar);
}

extern "C" int crossbyte_crypto_scalarmult(uint8_t *point, const uint8_t *scalar, const uint8_t *peerPoint) {
	SodiumState &sodium = state();
	if (!sodium.ready || point == nullptr || scalar == nullptr || peerPoint == nullptr) {
		return -1;
	}

	return crypto_scalarmult_curve25519(point, scalar, peerPoint);
}

extern "C" int crossbyte_crypto_kx_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || publicKey == nullptr || secretKey == nullptr) {
		return -1;
	}

	return crypto_kx_keypair(publicKey, secretKey);
}

extern "C" int crossbyte_crypto_kx_client_session_keys(
	uint8_t *rx,
	uint8_t *tx,
	const uint8_t *clientPublicKey,
	const uint8_t *clientSecretKey,
	const uint8_t *serverPublicKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || rx == nullptr || tx == nullptr || clientPublicKey == nullptr || clientSecretKey == nullptr || serverPublicKey == nullptr) {
		return -1;
	}

	return crypto_kx_client_session_keys(rx, tx, clientPublicKey, clientSecretKey, serverPublicKey);
}

extern "C" int crossbyte_crypto_kx_server_session_keys(
	uint8_t *rx,
	uint8_t *tx,
	const uint8_t *serverPublicKey,
	const uint8_t *serverSecretKey,
	const uint8_t *clientPublicKey) {
	SodiumState &sodium = state();
	if (!sodium.ready || rx == nullptr || tx == nullptr || serverPublicKey == nullptr || serverSecretKey == nullptr || clientPublicKey == nullptr) {
		return -1;
	}

	return crypto_kx_server_session_keys(rx, tx, serverPublicKey, serverSecretKey, clientPublicKey);
}

extern "C" int crossbyte_crypto_generichash(
	uint8_t *out,
	int outLength,
	const uint8_t *input,
	int inputLength,
	const uint8_t *key,
	int keyLength) {
	SodiumState &sodium = state();
	if (!sodium.ready || out == nullptr || outLength <= 0 || inputLength < 0 || keyLength < 0) {
		return -1;
	}

	return crypto_generichash(
		out, (size_t) outLength,
		opt(input, inputLength), (unsigned long long) inputLength,
		opt(key, keyLength), (size_t) keyLength);
}

extern "C" int crossbyte_crypto_hkdf_sha256_extract(
	uint8_t *prk,
	const uint8_t *salt,
	int saltLength,
	const uint8_t *ikm,
	int ikmLength) {
	SodiumState &sodium = state();
	if (!sodium.ready || prk == nullptr || saltLength < 0 || ikmLength < 0) {
		return -1;
	}

	return crypto_kdf_hkdf_sha256_extract(prk, opt(salt, saltLength), (size_t) saltLength, opt(ikm, ikmLength), (size_t) ikmLength);
}

extern "C" int crossbyte_crypto_hkdf_sha256_expand(
	uint8_t *out,
	int outLength,
	const uint8_t *info,
	int infoLength,
	const uint8_t *prk) {
	SodiumState &sodium = state();
	if (!sodium.ready || out == nullptr || prk == nullptr || outLength <= 0 || infoLength < 0) {
		return -1;
	}

	return crypto_kdf_hkdf_sha256_expand(out, (size_t) outLength, (const char *) opt(info, infoLength), (size_t) infoLength, prk);
}

extern "C" int crossbyte_crypto_pwhash_derive(
	uint8_t *out,
	int outLength,
	const uint8_t *password,
	int passwordLength,
	const uint8_t *salt,
	int opslimit,
	int memlimit) {
	SodiumState &sodium = state();
	if (!sodium.ready || out == nullptr || salt == nullptr || outLength <= 0 || passwordLength < 0 || opslimit <= 0 || memlimit <= 0) {
		return -1;
	}

	return crypto_pwhash(
		out, (unsigned long long) outLength,
		(const char *) opt(password, passwordLength), (unsigned long long) passwordLength,
		salt, (unsigned long long) opslimit, (size_t) memlimit, kPwhashAlgArgon2id13);
}

extern "C" int crossbyte_crypto_pwhash_str(
	uint8_t *out128,
	const uint8_t *password,
	int passwordLength,
	int opslimit,
	int memlimit) {
	SodiumState &sodium = state();
	if (!sodium.ready || out128 == nullptr || passwordLength < 0 || opslimit <= 0 || memlimit <= 0) {
		return -1;
	}

	return crypto_pwhash_str(
		(char *) out128,
		(const char *) opt(password, passwordLength), (unsigned long long) passwordLength,
		(unsigned long long) opslimit, (size_t) memlimit);
}

extern "C" int crossbyte_crypto_pwhash_str_verify(
	const uint8_t *hashStr,
	const uint8_t *password,
	int passwordLength) {
	SodiumState &sodium = state();
	if (!sodium.ready || hashStr == nullptr || passwordLength < 0) {
		return -1;
	}

	return crypto_pwhash_str_verify(
		(const char *) hashStr,
		(const char *) opt(password, passwordLength), (unsigned long long) passwordLength);
}

extern "C" int crossbyte_crypto_pwhash_str_needs_rehash(
	const uint8_t *hashStr,
	int opslimit,
	int memlimit) {
	SodiumState &sodium = state();
	if (!sodium.ready || hashStr == nullptr || opslimit <= 0 || memlimit <= 0) {
		return -1;
	}

	return crypto_pwhash_str_needs_rehash((const char *) hashStr, (unsigned long long) opslimit, (size_t) memlimit);
}

extern "C" int crossbyte_crypto_memcmp(const uint8_t *a, const uint8_t *b, int length) {
	SodiumState &sodium = state();
	if (!sodium.ready || a == nullptr || b == nullptr || length < 0) {
		return -1;
	}
	if (length == 0) {
		return 0;
	}

	return sodium_memcmp(a, b, (size_t) length);
}

extern "C" void crossbyte_crypto_memzero(uint8_t *buffer, int length) {
	if (buffer == nullptr || length <= 0) {
		return;
	}

	SodiumState &sodium = state();
	if (!sodium.ready) {
		// Plain wipe fallback keeps the contract even if sodium_init failed.
		volatile uint8_t *cursor = buffer;
		for (int i = 0; i < length; i++) {
			cursor[i] = 0;
		}
		return;
	}

	sodium_memzero(buffer, (size_t) length);
}

#else

extern "C" bool crossbyte_crypto_sodium_available() {
	return false;
}

extern "C" const char *crossbyte_crypto_sodium_status_message() {
	return "libsodium is currently wired for native Windows x64 cpp targets.";
}

extern "C" int crossbyte_crypto_ed25519_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	(void) publicKey;
	(void) secretKey;
	return -1;
}

extern "C" int crossbyte_crypto_ed25519_sign_detached(
	uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *secretKey) {
	(void) signature;
	(void) message;
	(void) messageLength;
	(void) secretKey;
	return -1;
}

extern "C" int crossbyte_crypto_ed25519_verify_detached(
	const uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *publicKey) {
	(void) signature;
	(void) message;
	(void) messageLength;
	(void) publicKey;
	return -1;
}

extern "C" int crossbyte_crypto_aead_xchacha20poly1305_encrypt(uint8_t *out, const uint8_t *message, int messageLength, const uint8_t *additionalData, int additionalDataLength, const uint8_t *nonce, const uint8_t *key) {
	(void) out; (void) message; (void) messageLength; (void) additionalData; (void) additionalDataLength; (void) nonce; (void) key;
	return -1;
}

extern "C" int crossbyte_crypto_aead_xchacha20poly1305_decrypt(uint8_t *out, const uint8_t *ciphertext, int ciphertextLength, const uint8_t *additionalData, int additionalDataLength, const uint8_t *nonce, const uint8_t *key) {
	(void) out; (void) ciphertext; (void) ciphertextLength; (void) additionalData; (void) additionalDataLength; (void) nonce; (void) key;
	return -1;
}

extern "C" int crossbyte_crypto_scalarmult_base(uint8_t *point, const uint8_t *scalar) {
	(void) point; (void) scalar;
	return -1;
}

extern "C" int crossbyte_crypto_scalarmult(uint8_t *point, const uint8_t *scalar, const uint8_t *peerPoint) {
	(void) point; (void) scalar; (void) peerPoint;
	return -1;
}

extern "C" int crossbyte_crypto_kx_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	(void) publicKey; (void) secretKey;
	return -1;
}

extern "C" int crossbyte_crypto_kx_client_session_keys(uint8_t *rx, uint8_t *tx, const uint8_t *clientPublicKey, const uint8_t *clientSecretKey, const uint8_t *serverPublicKey) {
	(void) rx; (void) tx; (void) clientPublicKey; (void) clientSecretKey; (void) serverPublicKey;
	return -1;
}

extern "C" int crossbyte_crypto_kx_server_session_keys(uint8_t *rx, uint8_t *tx, const uint8_t *serverPublicKey, const uint8_t *serverSecretKey, const uint8_t *clientPublicKey) {
	(void) rx; (void) tx; (void) serverPublicKey; (void) serverSecretKey; (void) clientPublicKey;
	return -1;
}

extern "C" int crossbyte_crypto_generichash(uint8_t *out, int outLength, const uint8_t *input, int inputLength, const uint8_t *key, int keyLength) {
	(void) out; (void) outLength; (void) input; (void) inputLength; (void) key; (void) keyLength;
	return -1;
}

extern "C" int crossbyte_crypto_hkdf_sha256_extract(uint8_t *prk, const uint8_t *salt, int saltLength, const uint8_t *ikm, int ikmLength) {
	(void) prk; (void) salt; (void) saltLength; (void) ikm; (void) ikmLength;
	return -1;
}

extern "C" int crossbyte_crypto_hkdf_sha256_expand(uint8_t *out, int outLength, const uint8_t *info, int infoLength, const uint8_t *prk) {
	(void) out; (void) outLength; (void) info; (void) infoLength; (void) prk;
	return -1;
}

extern "C" int crossbyte_crypto_pwhash_derive(uint8_t *out, int outLength, const uint8_t *password, int passwordLength, const uint8_t *salt, int opslimit, int memlimit) {
	(void) out; (void) outLength; (void) password; (void) passwordLength; (void) salt; (void) opslimit; (void) memlimit;
	return -1;
}

extern "C" int crossbyte_crypto_pwhash_str(uint8_t *out128, const uint8_t *password, int passwordLength, int opslimit, int memlimit) {
	(void) out128; (void) password; (void) passwordLength; (void) opslimit; (void) memlimit;
	return -1;
}

extern "C" int crossbyte_crypto_pwhash_str_verify(const uint8_t *hashStr, const uint8_t *password, int passwordLength) {
	(void) hashStr; (void) password; (void) passwordLength;
	return -1;
}

extern "C" int crossbyte_crypto_pwhash_str_needs_rehash(const uint8_t *hashStr, int opslimit, int memlimit) {
	(void) hashStr; (void) opslimit; (void) memlimit;
	return -1;
}

extern "C" int crossbyte_crypto_memcmp(const uint8_t *a, const uint8_t *b, int length) {
	(void) a; (void) b; (void) length;
	return -1;
}

extern "C" void crossbyte_crypto_memzero(uint8_t *buffer, int length) {
	if (buffer == nullptr || length <= 0) {
		return;
	}

	volatile uint8_t *cursor = buffer;
	for (int i = 0; i < length; i++) {
		cursor[i] = 0;
	}
}

#endif
