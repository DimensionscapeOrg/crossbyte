// CrossByte asymmetric-signature bridge over mbedTLS.
//
// mbedTLS ships with hxcpp and is already linked for sys.ssl, so this adds
// no new dependency. All cryptography is mbedTLS's; this file only parses
// arguments, manages contexts, and converts between the ASN.1 DER ECDSA
// signatures mbedTLS produces and the raw r||s form JWS carries.

#include "NativePk.h"

#if defined(HX_WINDOWS) || defined(HX_MACOS) || defined(HX_LINUX) || defined(__unix__) || defined(_WIN32) || defined(__APPLE__)
#define CROSSBYTE_PK_ENABLED 1
#endif

#ifdef CROSSBYTE_PK_ENABLED

#include <string.h>
#include <vector>

#include <mbedtls/pk.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <mbedtls/bignum.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/asn1.h>
#include <mbedtls/asn1write.h>
#include <mbedtls/error.h>
#include <stdio.h>

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#else
#include <stdio.h>
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

	// MBEDTLS_PK_SIGNATURE_MAX_SIZE postdates mbedTLS 2.9, which is what
	// hxcpp bundles. 1024 bytes covers an RSA-8192 signature, well beyond
	// the key sizes this API is used with.
	const size_t kMaxSignatureLength = 1024;

	// mbedTLS PEM parsing requires the buffer length to include a
	// terminating NUL byte.
	std::vector<unsigned char> asPemBuffer(const uint8_t *pem, int length) {
		std::vector<unsigned char> buffer;
		if (pem == nullptr || length <= 0) {
			return buffer;
		}
		buffer.assign(pem, pem + length);
		if (buffer.empty() || buffer.back() != '\0') {
			buffer.push_back('\0');
		}
		return buffer;
	}

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

	int loadKey(mbedtls_pk_context *ctx, const uint8_t *pem, int length, bool isPrivate) {
		std::vector<unsigned char> buffer = asPemBuffer(pem, length);
		if (buffer.empty()) {
			return -1;
		}

		if (isPrivate) {
			return mbedtls_pk_parse_key(ctx, buffer.data(), buffer.size(), nullptr, 0);
		}
		return mbedtls_pk_parse_public_key(ctx, buffer.data(), buffer.size());
	}

	size_t ecCoordinateSize(mbedtls_pk_context *ctx) {
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
}

extern "C" bool crossbyte_pk_available() {
	return true;
}

extern "C" int crossbyte_pk_verify_sha256(const uint8_t *publicKeyPem, int publicKeyLength, const uint8_t *hash, const uint8_t *signature,
	int signatureLength, int signatureFormat) {
	if (hash == nullptr || signature == nullptr || signatureLength <= 0) {
		return -1;
	}

	mbedtls_pk_context ctx;
	_hx_ssl_init();
	mbedtls_pk_init(&ctx);

	int rc = loadKey(&ctx, publicKeyPem, publicKeyLength, false);
	if (rc != 0) {
		mbedtls_pk_free(&ctx);
		return rc;
	}

	std::vector<unsigned char> converted;
	const uint8_t *effectiveSignature = signature;
	size_t effectiveLength = (size_t)signatureLength;

	if (signatureFormat == 1) {
		size_t coordinate = ecCoordinateSize(&ctx);
		rc = rawToDer(signature, signatureLength, coordinate, converted);
		if (rc != 0) {
			mbedtls_pk_free(&ctx);
			return rc;
		}
		effectiveSignature = converted.data();
		effectiveLength = converted.size();
	}

	rc = mbedtls_pk_verify(&ctx, MBEDTLS_MD_SHA256, hash, kSha256Length, effectiveSignature, effectiveLength);
	mbedtls_pk_free(&ctx);
	return rc;
}

extern "C" int crossbyte_pk_sign_sha256(const uint8_t *privateKeyPem, int privateKeyLength, const uint8_t *hash, uint8_t *out, int outCapacity,
	int *outLength, int signatureFormat) {
	if (hash == nullptr || out == nullptr || outLength == nullptr || outCapacity <= 0) {
		return -1;
	}

	*outLength = 0;

	mbedtls_pk_context ctx;
	_hx_ssl_init();
	mbedtls_pk_init(&ctx);

	int rc = loadKey(&ctx, privateKeyPem, privateKeyLength, true);

	if (rc == 0) {
		unsigned char scratch[kMaxSignatureLength];
		size_t produced = 0;

		rc = mbedtls_pk_sign(&ctx, MBEDTLS_MD_SHA256, hash, kSha256Length, scratch, &produced, osRandom, nullptr);

		if (rc == 0) {
			if (signatureFormat == 1) {
				size_t coordinate = ecCoordinateSize(&ctx);
				if (coordinate == 0 || outCapacity < (int)(coordinate * 2)) {
					rc = -1;
				} else {
					rc = derToRaw(scratch, produced, coordinate, out);
					if (rc == 0) {
						*outLength = (int)(coordinate * 2);
					}
				}
			} else if ((int)produced > outCapacity) {
				rc = -1;
			} else {
				memcpy(out, scratch, produced);
				*outLength = (int)produced;
			}
		}
	}

	mbedtls_pk_free(&ctx);
	return rc;
}

extern "C" const char *crossbyte_pk_error_message(int code) {
	static char buffer[256];
	mbedtls_strerror(code, buffer, sizeof(buffer));
	if (buffer[0] == '\0') {
		snprintf(buffer, sizeof(buffer), "mbedTLS error %d", code);
	}
	return buffer;
}

extern "C" int crossbyte_pk_key_type(const uint8_t *keyPem, int keyLength, bool isPrivate) {
	mbedtls_pk_context ctx;
	_hx_ssl_init();
	mbedtls_pk_init(&ctx);

	int rc = loadKey(&ctx, keyPem, keyLength, isPrivate);
	int result = 0;

	if (rc == 0) {
		mbedtls_pk_type_t type = mbedtls_pk_get_type(&ctx);
		if (type == MBEDTLS_PK_RSA) {
			result = 1;
		} else if (type == MBEDTLS_PK_ECKEY || type == MBEDTLS_PK_ECKEY_DH || type == MBEDTLS_PK_ECDSA) {
			result = 2;
		}
	}

	mbedtls_pk_free(&ctx);
	return result;
}

extern "C" int crossbyte_pk_ec_coordinate_size(const uint8_t *keyPem, int keyLength, bool isPrivate) {
	mbedtls_pk_context ctx;
	_hx_ssl_init();
	mbedtls_pk_init(&ctx);

	int rc = loadKey(&ctx, keyPem, keyLength, isPrivate);
	int result = -1;

	if (rc == 0) {
		size_t coordinate = ecCoordinateSize(&ctx);
		result = (coordinate == 0) ? -1 : (int)coordinate;
	}

	mbedtls_pk_free(&ctx);
	return result;
}

#else

extern "C" bool crossbyte_pk_available() {
	return false;
}

extern "C" int crossbyte_pk_verify_sha256(const uint8_t *publicKeyPem, int publicKeyLength, const uint8_t *hash, const uint8_t *signature,
	int signatureLength, int signatureFormat) {
	(void)publicKeyPem; (void)publicKeyLength; (void)hash; (void)signature; (void)signatureLength; (void)signatureFormat;
	return -1;
}

extern "C" int crossbyte_pk_sign_sha256(const uint8_t *privateKeyPem, int privateKeyLength, const uint8_t *hash, uint8_t *out, int outCapacity,
	int *outLength, int signatureFormat) {
	(void)privateKeyPem; (void)privateKeyLength; (void)hash; (void)out; (void)outCapacity; (void)signatureFormat;
	if (outLength != nullptr) {
		*outLength = 0;
	}
	return -1;
}

extern "C" const char *crossbyte_pk_error_message(int code) {
	(void)code;
	return "mbedTLS public-key support is unavailable on this target.";
}

extern "C" int crossbyte_pk_key_type(const uint8_t *keyPem, int keyLength, bool isPrivate) {
	(void)keyPem; (void)keyLength; (void)isPrivate;
	return 0;
}

extern "C" int crossbyte_pk_ec_coordinate_size(const uint8_t *keyPem, int keyLength, bool isPrivate) {
	(void)keyPem; (void)keyLength; (void)isPrivate;
	return -1;
}

#endif
