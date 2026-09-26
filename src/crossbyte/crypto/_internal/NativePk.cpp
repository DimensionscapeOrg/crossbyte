// CrossByte asymmetric-signature bridge over mbedTLS.
//
// mbedTLS ships with hxcpp and is already linked for sys.ssl, so this adds
// no new dependency. All cryptography is mbedTLS's; this file only parses
// arguments, manages contexts, and converts between the ASN.1 DER ECDSA
// signatures mbedTLS produces and the raw r||s form JWS carries.

#include <hxcpp.h>
#include "NativePk.h"

#if defined(HX_WINDOWS) || defined(HX_MACOS) || defined(HX_LINUX) || defined(__unix__) || defined(_WIN32) || defined(__APPLE__)
#define CROSSBYTE_PK_ENABLED 1
#endif

#ifdef CROSSBYTE_PK_ENABLED

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <atomic>
#include <mutex>
#include <vector>

#include <mbedtls/pk.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <mbedtls/bignum.h>
#include <mbedtls/asn1.h>
#include <mbedtls/asn1write.h>
#include <mbedtls/error.h>
#include <mbedtls/platform_util.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#endif

// hxcpp compiles mbedTLS with MBEDTLS_THREADING_C and installs the
// platform mutex callbacks in its own _hx_ssl_init(). Without them, RSA's
// internal mutex operations fail with MBEDTLS_ERR_THREADING_BAD_INPUT_DATA
// (-0x001C) on the very first sign. That initializer is idempotent and
// shared with sys.ssl, so calling it here is correct whether or not the
// program also uses TLS.
void _hx_ssl_init();

namespace {
	const size_t kSha256Length = 32;

	// MBEDTLS_PK_SIGNATURE_MAX_SIZE postdates mbedTLS 2.9. 1024 bytes covers an
	// RSA-8192 signature, well beyond the key sizes this API is used with.
	const size_t kMaxSignatureLength = 1024;

	// Returned for a key that has been disposed of, or is the wrong kind for
	// the operation. Outside mbedTLS's error ranges.
	const int kErrorNoKey = -0x7F01;

	std::atomic<int> g_parses(0);

	// Randomness for signing comes straight from the operating system's
	// CSPRNG rather than an mbedTLS DRBG seeded from its entropy pollers,
	// which fail to seed in this build. This matters most for ECDSA, where
	// a predictable nonce leaks the private key outright.
	int osRandom(void *context, unsigned char *out, size_t length) {
		(void)context;
		if (out == nullptr) {
			return -1;
		}
		if (length == 0) {
			return 0;
		}

#if defined(_WIN32)
		NTSTATUS status = BCryptGenRandom(nullptr, out, (ULONG)length, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
		return (status == 0) ? 0 : -1;
#else
		FILE *source = fopen("/dev/urandom", "rb");
		if (source == nullptr) {
			return -1;
		}
		size_t read = fread(out, 1, length, source);
		fclose(source);
		return (read == length) ? 0 : -1;
#endif
	}

	size_t ecCoordinateSize(mbedtls_pk_context *ctx) {
		mbedtls_pk_type_t type = mbedtls_pk_get_type(ctx);
		if (type != MBEDTLS_PK_ECKEY && type != MBEDTLS_PK_ECKEY_DH && type != MBEDTLS_PK_ECDSA) {
			return 0;
		}
		mbedtls_ecp_keypair *ec = mbedtls_pk_ec(*ctx);
		if (ec == nullptr) {
			return 0;
		}
		return (ec->grp.nbits + 7) / 8;
	}

	// JOSE carries ECDSA signatures as the fixed-width concatenation r||s;
	// mbedTLS speaks ASN.1 DER. Convert raw -> DER for verification.
	int rawToDer(const uint8_t *raw, int rawLength, size_t coordinate, std::vector<unsigned char> &out) {
		if (coordinate == 0 || rawLength != (int)(coordinate * 2)) {
			return -1;
		}

		mbedtls_mpi r, s;
		mbedtls_mpi_init(&r);
		mbedtls_mpi_init(&s);

		int rc = mbedtls_mpi_read_binary(&r, raw, coordinate);
		if (rc == 0) {
			rc = mbedtls_mpi_read_binary(&s, raw + coordinate, coordinate);
		}

		if (rc == 0) {
			// mbedtls_asn1_write_* fills the buffer from the back.
			unsigned char scratch[MBEDTLS_ECDSA_MAX_LEN];
			unsigned char *p = scratch + sizeof(scratch);
			int length = 0;

			int written = mbedtls_asn1_write_mpi(&p, scratch, &s);
			if (written < 0) {
				rc = written;
			} else {
				length += written;
				written = mbedtls_asn1_write_mpi(&p, scratch, &r);
				if (written < 0) {
					rc = written;
				} else {
					length += written;
					written = mbedtls_asn1_write_len(&p, scratch, (size_t)length);
					if (written < 0) {
						rc = written;
					} else {
						length += written;
						written = mbedtls_asn1_write_tag(&p, scratch, MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE);
						if (written < 0) {
							rc = written;
						} else {
							length += written;
							out.assign(p, p + length);
						}
					}
				}
			}
		}

		mbedtls_mpi_free(&r);
		mbedtls_mpi_free(&s);
		return rc;
	}

	// DER -> raw r||s, zero-padded to the curve's coordinate width.
	int derToRaw(const unsigned char *der, size_t derLength, size_t coordinate, uint8_t *out) {
		unsigned char *p = (unsigned char *)der;
		const unsigned char *end = der + derLength;
		size_t sequenceLength = 0;

		int rc = mbedtls_asn1_get_tag(&p, end, &sequenceLength, MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE);
		if (rc != 0) {
			return rc;
		}

		mbedtls_mpi r, s;
		mbedtls_mpi_init(&r);
		mbedtls_mpi_init(&s);

		rc = mbedtls_asn1_get_mpi(&p, end, &r);
		if (rc == 0) {
			rc = mbedtls_asn1_get_mpi(&p, end, &s);
		}
		if (rc == 0) {
			rc = mbedtls_mpi_write_binary(&r, out, coordinate);
		}
		if (rc == 0) {
			rc = mbedtls_mpi_write_binary(&s, out + coordinate, coordinate);
		}

		mbedtls_mpi_free(&r);
		mbedtls_mpi_free(&s);
		return rc;
	}

	// A parsed key and the lock its operations take. Native memory, so it can
	// be used inside a GC-free zone. Freed by the owning object's finalizer
	// only: disposing of a key wipes the context but leaves this in place, so
	// a thread already waiting on the lock never finds it gone.
	struct KeyState {
		mbedtls_pk_context pk;
		std::mutex lock;
		bool isPrivate;
		bool live;

		KeyState(bool isPrivateKey) : isPrivate(isPrivateKey), live(false) {
			mbedtls_pk_init(&pk);
		}

		~KeyState() {
			if (live) {
				mbedtls_pk_free(&pk);
			}
		}

		// Under the lock. mbedtls_pk_free zeroes the key material it frees.
		void release() {
			if (live) {
				mbedtls_pk_free(&pk);
				live = false;
			}
		}
	};

	// The GC's handle on a KeyState, after the pattern of hxcpp's own sslpkey:
	// the finalizer is what frees the native side when the key is dropped.
	struct PkKey : public hx::Object {
		HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdAbstract };

		KeyState *state;

		void create(KeyState *keyState) {
			state = keyState;
			_hx_set_finalizer(this, finalize);
		}

		static void finalize(Dynamic obj) {
			PkKey *key = (PkKey *)(obj.mPtr);
			delete key->state;
			key->state = nullptr;
		}

		String toString() HXCPP_OVERRIDE {
			return HX_CSTRING("PublicKeySignature key");
		}
	};

	KeyState *stateOf(Dynamic key) {
		if (key.mPtr == 0) {
			return nullptr;
		}
		PkKey *handle = dynamic_cast<PkKey *>(key.mPtr);
		return handle == nullptr ? nullptr : handle->state;
	}
}

bool crossbyte_pk_available() {
	return true;
}

::Dynamic crossbyte_pk_key_load(const uint8_t *pem, int pemLength, bool isPrivate, int *error) {
	if (error != nullptr) {
		*error = -1;
	}
	if (pem == nullptr || pemLength <= 0) {
		return null();
	}

	_hx_ssl_init();

	// mbedTLS PEM parsing requires the length to count a terminating NUL.
	// The copy is native memory, so the parse can run in a GC-free zone, and
	// it is wiped before it is freed: a private key left in freed memory is a
	// private key still in the process.
	size_t capacity = (size_t)pemLength + 1;
	unsigned char *buffer = (unsigned char *)malloc(capacity);
	if (buffer == nullptr) {
		return null();
	}
	memcpy(buffer, pem, (size_t)pemLength);
	buffer[pemLength] = 0;
	size_t parseLength = (pem[pemLength - 1] == 0) ? (size_t)pemLength : capacity;

	KeyState *state = new KeyState(isPrivate);
	g_parses++;

	hx::EnterGCFreeZone();
	int rc = isPrivate ? mbedtls_pk_parse_key(&state->pk, buffer, parseLength, nullptr, 0)
		: mbedtls_pk_parse_public_key(&state->pk, buffer, parseLength);
	hx::ExitGCFreeZone();

	mbedtls_platform_zeroize(buffer, capacity);
	free(buffer);

	if (error != nullptr) {
		*error = rc;
	}
	if (rc != 0) {
		// mbedtls_pk_free on a context a failed parse left behind.
		mbedtls_pk_free(&state->pk);
		delete state;
		return null();
	}

	state->live = true;
	PkKey *key = new PkKey();
	key->create(state);
	return key;
}

int crossbyte_pk_key_type(::Dynamic key) {
	KeyState *state = stateOf(key);
	if (state == nullptr) {
		return 0;
	}

	std::lock_guard<std::mutex> guard(state->lock);
	if (!state->live) {
		return 0;
	}

	mbedtls_pk_type_t type = mbedtls_pk_get_type(&state->pk);
	if (type == MBEDTLS_PK_RSA) {
		return 1;
	}
	if (type == MBEDTLS_PK_ECKEY || type == MBEDTLS_PK_ECKEY_DH || type == MBEDTLS_PK_ECDSA) {
		return 2;
	}
	return 0;
}

int crossbyte_pk_key_coordinate_size(::Dynamic key) {
	KeyState *state = stateOf(key);
	if (state == nullptr) {
		return -1;
	}

	std::lock_guard<std::mutex> guard(state->lock);
	if (!state->live) {
		return -1;
	}

	size_t coordinate = ecCoordinateSize(&state->pk);
	return coordinate == 0 ? -1 : (int)coordinate;
}

int crossbyte_pk_key_sign_sha256(::Dynamic key, const uint8_t *hash, uint8_t *out, int outCapacity, int *outLength, int signatureFormat) {
	KeyState *state = stateOf(key);
	if (state == nullptr || hash == nullptr || out == nullptr || outLength == nullptr || outCapacity <= 0) {
		return -1;
	}
	*outLength = 0;

	// Everything the zone touches is native: the digest in, the signature out.
	unsigned char digest[kSha256Length];
	memcpy(digest, hash, kSha256Length);
	unsigned char signature[kMaxSignatureLength];
	size_t produced = 0;
	int rc = 0;

	hx::EnterGCFreeZone();
	{
		std::lock_guard<std::mutex> guard(state->lock);

		if (!state->live || !state->isPrivate) {
			rc = kErrorNoKey;
		} else {
			unsigned char der[kMaxSignatureLength];
			size_t derLength = 0;
			rc = mbedtls_pk_sign(&state->pk, MBEDTLS_MD_SHA256, digest, kSha256Length, der, &derLength, osRandom, nullptr);

			if (rc == 0) {
				if (signatureFormat == 1) {
					size_t coordinate = ecCoordinateSize(&state->pk);
					if (coordinate == 0 || coordinate * 2 > kMaxSignatureLength) {
						rc = kErrorNoKey;
					} else {
						rc = derToRaw(der, derLength, coordinate, signature);
						produced = coordinate * 2;
					}
				} else {
					memcpy(signature, der, derLength);
					produced = derLength;
				}
			}
		}
	}
	hx::ExitGCFreeZone();

	if (rc != 0) {
		return rc;
	}
	if ((int)produced > outCapacity) {
		return -1;
	}

	memcpy(out, signature, produced);
	*outLength = (int)produced;
	return 0;
}

int crossbyte_pk_key_verify_sha256(::Dynamic key, const uint8_t *hash, const uint8_t *signature, int signatureLength, int signatureFormat) {
	KeyState *state = stateOf(key);
	if (state == nullptr || hash == nullptr || signature == nullptr || signatureLength <= 0 || signatureLength > (int)kMaxSignatureLength) {
		return -1;
	}

	unsigned char digest[kSha256Length];
	memcpy(digest, hash, kSha256Length);
	unsigned char presented[kMaxSignatureLength];
	memcpy(presented, signature, (size_t)signatureLength);
	int rc = 0;

	hx::EnterGCFreeZone();
	{
		std::lock_guard<std::mutex> guard(state->lock);

		if (!state->live) {
			rc = kErrorNoKey;
		} else if (signatureFormat == 1) {
			std::vector<unsigned char> der;
			rc = rawToDer(presented, signatureLength, ecCoordinateSize(&state->pk), der);
			if (rc == 0) {
				rc = mbedtls_pk_verify(&state->pk, MBEDTLS_MD_SHA256, digest, kSha256Length, der.data(), der.size());
			}
		} else {
			rc = mbedtls_pk_verify(&state->pk, MBEDTLS_MD_SHA256, digest, kSha256Length, presented, (size_t)signatureLength);
		}
	}
	hx::ExitGCFreeZone();

	return rc;
}

void crossbyte_pk_key_dispose(::Dynamic key) {
	KeyState *state = stateOf(key);
	if (state == nullptr) {
		return;
	}

	hx::EnterGCFreeZone();
	{
		std::lock_guard<std::mutex> guard(state->lock);
		state->release();
	}
	hx::ExitGCFreeZone();
}

::String crossbyte_pk_error_message(int code) {
	if (code == kErrorNoKey) {
		return HX_CSTRING("the key has been disposed of, or cannot do this");
	}

	char buffer[256];
	buffer[0] = 0;
	mbedtls_strerror(code, buffer, sizeof(buffer));
	if (buffer[0] == '\0') {
		snprintf(buffer, sizeof(buffer), "mbedTLS error %d", code);
	}
	return ::String::create(buffer);
}

int crossbyte_pk_parse_count() {
	return g_parses.load();
}

#else

bool crossbyte_pk_available() {
	return false;
}

::Dynamic crossbyte_pk_key_load(const uint8_t *pem, int pemLength, bool isPrivate, int *error) {
	(void)pem; (void)pemLength; (void)isPrivate;
	if (error != nullptr) {
		*error = -1;
	}
	return null();
}

int crossbyte_pk_key_type(::Dynamic key) {
	(void)key;
	return 0;
}

int crossbyte_pk_key_coordinate_size(::Dynamic key) {
	(void)key;
	return -1;
}

int crossbyte_pk_key_sign_sha256(::Dynamic key, const uint8_t *hash, uint8_t *out, int outCapacity, int *outLength, int signatureFormat) {
	(void)key; (void)hash; (void)out; (void)outCapacity; (void)signatureFormat;
	if (outLength != nullptr) {
		*outLength = 0;
	}
	return -1;
}

int crossbyte_pk_key_verify_sha256(::Dynamic key, const uint8_t *hash, const uint8_t *signature, int signatureLength, int signatureFormat) {
	(void)key; (void)hash; (void)signature; (void)signatureLength; (void)signatureFormat;
	return -1;
}

void crossbyte_pk_key_dispose(::Dynamic key) {
	(void)key;
}

::String crossbyte_pk_error_message(int code) {
	(void)code;
	return HX_CSTRING("mbedTLS public-key support is unavailable on this target.");
}

int crossbyte_pk_parse_count() {
	return 0;
}

#endif
