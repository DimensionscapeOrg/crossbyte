// CrossByte native libsodium bridge.
//
// The bridge deliberately loads libsodium at runtime rather than linking
// directly. That keeps the CrossByte haxelib light and lets applications ship
// the DLL alongside the executable or point to it with
// CROSSBYTE_LIBSODIUM_DLL.

#include <stdint.h>
#include <string>
#include <mutex>

#if defined(_WIN32)
#include <Windows.h>

namespace {
	typedef int(__cdecl *sodium_init_fn)(void);
	typedef int(__cdecl *crypto_sign_keypair_fn)(unsigned char *, unsigned char *);
	typedef int(__cdecl *crypto_sign_detached_fn)(unsigned char *, unsigned long long *, const unsigned char *, unsigned long long, const unsigned char *);
	typedef int(__cdecl *crypto_sign_verify_detached_fn)(const unsigned char *, const unsigned char *, unsigned long long, const unsigned char *);

	struct SodiumApi {
		HMODULE module = nullptr;
		sodium_init_fn sodium_init = nullptr;
		crypto_sign_keypair_fn crypto_sign_keypair = nullptr;
		crypto_sign_detached_fn crypto_sign_detached = nullptr;
		crypto_sign_verify_detached_fn crypto_sign_verify_detached = nullptr;
		bool ready = false;
		std::string status = "libsodium has not been loaded yet.";
	};

	SodiumApi g_sodium;
	std::once_flag g_sodium_once;

	template <typename T>
	bool load_proc(const char *name, T &target) {
		target = reinterpret_cast<T>(GetProcAddress(g_sodium.module, name));
		if (target == nullptr) {
			g_sodium.status = std::string("libsodium is missing required symbol: ") + name;
			return false;
		}
		return true;
	}

	void try_load_candidate(const char *path) {
		if (g_sodium.module == nullptr && path != nullptr && path[0] != '\0') {
			g_sodium.module = LoadLibraryA(path);
		}
	}

	void init_sodium() {
		char envPath[4096];
		DWORD envLen = GetEnvironmentVariableA("CROSSBYTE_LIBSODIUM_DLL", envPath, sizeof(envPath));
		if (envLen > 0 && envLen < sizeof(envPath)) {
			try_load_candidate(envPath);
		}

		try_load_candidate("libsodium.dll");

		if (g_sodium.module == nullptr) {
			g_sodium.status = "libsodium.dll could not be loaded. Ship libsodium.dll with the application or set CROSSBYTE_LIBSODIUM_DLL.";
			return;
		}

		if (!load_proc("sodium_init", g_sodium.sodium_init) ||
			!load_proc("crypto_sign_keypair", g_sodium.crypto_sign_keypair) ||
			!load_proc("crypto_sign_detached", g_sodium.crypto_sign_detached) ||
			!load_proc("crypto_sign_verify_detached", g_sodium.crypto_sign_verify_detached)) {
			FreeLibrary(g_sodium.module);
			g_sodium.module = nullptr;
			return;
		}

		int rc = g_sodium.sodium_init();
		if (rc < 0) {
			g_sodium.status = "libsodium sodium_init() failed.";
			FreeLibrary(g_sodium.module);
			g_sodium.module = nullptr;
			return;
		}

		g_sodium.ready = true;
		g_sodium.status = "libsodium is available.";
	}

	inline SodiumApi &api() {
		std::call_once(g_sodium_once, init_sodium);
		return g_sodium;
	}
}

extern "C" bool crossbyte_crypto_sodium_available() {
	return api().ready;
}

extern "C" const char *crossbyte_crypto_sodium_status_message() {
	return api().status.c_str();
}

extern "C" int crossbyte_crypto_ed25519_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	SodiumApi &sodium = api();
	if (!sodium.ready || publicKey == nullptr || secretKey == nullptr) {
		return -1;
	}

	return sodium.crypto_sign_keypair(publicKey, secretKey);
}

extern "C" int crossbyte_crypto_ed25519_sign_detached(
	uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *secretKey) {
	SodiumApi &sodium = api();
	if (!sodium.ready || signature == nullptr || secretKey == nullptr || messageLength < 0) {
		return -1;
	}

	unsigned long long signatureLength = 0;
	const unsigned char *messagePtr = (messageLength > 0) ? message : nullptr;
	return sodium.crypto_sign_detached(signature, &signatureLength, messagePtr, (unsigned long long)messageLength, secretKey);
}

extern "C" int crossbyte_crypto_ed25519_verify_detached(
	const uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *publicKey) {
	SodiumApi &sodium = api();
	if (!sodium.ready || signature == nullptr || publicKey == nullptr || messageLength < 0) {
		return -1;
	}

	const unsigned char *messagePtr = (messageLength > 0) ? message : nullptr;
	return sodium.crypto_sign_verify_detached(signature, messagePtr, (unsigned long long)messageLength, publicKey);
}

#else

extern "C" bool crossbyte_crypto_sodium_available() {
	return false;
}

extern "C" const char *crossbyte_crypto_sodium_status_message() {
	return "libsodium is currently only wired for native Windows builds in CrossByte.";
}

extern "C" int crossbyte_crypto_ed25519_keypair(uint8_t *publicKey, uint8_t *secretKey) {
	(void)publicKey;
	(void)secretKey;
	return -1;
}

extern "C" int crossbyte_crypto_ed25519_sign_detached(
	uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *secretKey) {
	(void)signature;
	(void)message;
	(void)messageLength;
	(void)secretKey;
	return -1;
}

extern "C" int crossbyte_crypto_ed25519_verify_detached(
	const uint8_t *signature,
	const uint8_t *message,
	int messageLength,
	const uint8_t *publicKey) {
	(void)signature;
	(void)message;
	(void)messageLength;
	(void)publicKey;
	return -1;
}

#endif
