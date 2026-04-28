// CrossByte native libsodium bridge.
//
// This bridge links against a vendored static libsodium build on supported
// native Windows x64 targets. That keeps Ed25519 available without requiring a
// separate DLL at runtime.

#include <stdint.h>
#include <string>
#include <mutex>

#if defined(_WIN32) && defined(_WIN64) && !defined(_M_ARM64)

extern "C" {
	int sodium_init(void);
	int crypto_sign_keypair(unsigned char *pk, unsigned char *sk);
	int crypto_sign_detached(unsigned char *sig, unsigned long long *siglen_p, const unsigned char *m, unsigned long long mlen, const unsigned char *sk);
	int crypto_sign_verify_detached(const unsigned char *sig, const unsigned char *m, unsigned long long mlen, const unsigned char *pk);
}

namespace {
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
	const unsigned char *messagePtr = (messageLength > 0) ? message : nullptr;
	return crypto_sign_detached(signature, &signatureLength, messagePtr, (unsigned long long) messageLength, secretKey);
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

	const unsigned char *messagePtr = (messageLength > 0) ? message : nullptr;
	return crypto_sign_verify_detached(signature, messagePtr, (unsigned long long) messageLength, publicKey);
}

#else

extern "C" bool crossbyte_crypto_sodium_available() {
	return false;
}

extern "C" const char *crossbyte_crypto_sodium_status_message() {
	return "libsodium Ed25519 is currently wired for native Windows x64 cpp targets.";
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

#endif
