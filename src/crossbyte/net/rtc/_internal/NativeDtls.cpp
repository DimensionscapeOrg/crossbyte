#include "NativeDtls.h"

// Not a preference: hxcpp compiles mbedtls with MBEDTLS_THREADING_C, which adds
// a mutex member to mbedtls_ctr_drbg_context and mbedtls_entropy_context among
// others. A translation unit that disagrees with the library about the size of
// those structs declares a smaller one than the library then writes into, and
// the overrun reports success and kills the process somewhere else entirely --
// which is exactly how this file behaved before NativeDtlsBuild.xml set the
// flags. Failing the build is the cheaper outcome by a wide margin.
#ifndef MBEDTLS_THREADING_C
#error "NativeDtlsBuild.xml must define MBEDTLS_THREADING_C to match how hxcpp builds mbedtls, or every struct shared with it is the wrong size."
#endif

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/pk.h>
#include <mbedtls/platform_util.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509_crt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// hxcpp's own SSL initialiser, which installs the alt mutex callbacks that
// MBEDTLS_THREADING_ALT leaves unset. Until it runs, mbedtls_mutex_lock is a
// stub that *fails*, so every call that touches a mutex-bearing struct --
// ctr_drbg, entropy, the hmac_drbg deterministic ECDSA uses internally --
// refuses with an error that looks nothing like its cause.
//
// It is idempotent and guarded by its own flag, so calling it is free. Not
// calling it is what made this bridge work in one program and fail in another
// built from the same source: whether hxcpp had already initialised depended on
// static initialiser order across translation units, which nothing here
// controls.
extern void _hx_ssl_init();

namespace {

// A P-256 certificate and key are well under this even with PEM's expansion.
const size_t PEM_BUFFER = 4096;

const size_t SERIAL_BYTES = 16;

// Reasons of this bridge's own, kept clear of mbedtls's range.
const int ERROR_SEEDING = -1;
const int ERROR_ALLOCATION = -2;
const int ERROR_NAME_TOO_LONG = -3;

// The code from the last call that refused, for diagnosis.
int g_lastError = 0;

// Seeds the drbg. Personalised so two processes starting in the same second do
// not draw the same stream if the entropy source is coarse.
bool seed(mbedtls_entropy_context *entropy, mbedtls_ctr_drbg_context *drbg)
{
   static const char personal[] = "crossbyte-dtls-certificate";

   mbedtls_entropy_init(entropy);
   mbedtls_ctr_drbg_init(drbg);

   return mbedtls_ctr_drbg_seed(drbg, mbedtls_entropy_func, entropy,
      (const unsigned char *)personal, sizeof(personal) - 1) == 0;
}

} // namespace

bool crossbyte_dtls_available()
{
   return true;
}

int crossbyte_dtls_last_error()
{
   return g_lastError;
}

::Array< ::String> crossbyte_dtls_generate(::String commonName, ::String notBefore, ::String notAfter)
{
   _hx_ssl_init();
   g_lastError = 0;

   if (commonName == null() || notBefore == null() || notAfter == null())
      return null();

   hx::strbuf nameBuf;
   hx::strbuf beforeBuf;
   hx::strbuf afterBuf;

   const char *name = commonName.utf8_str(&nameBuf);
   const char *before = notBefore.utf8_str(&beforeBuf);
   const char *after = notAfter.utf8_str(&afterBuf);

   mbedtls_entropy_context entropy;
   mbedtls_ctr_drbg_context drbg;
   mbedtls_pk_context key;
   mbedtls_x509write_cert crt;
   mbedtls_mpi serial;

   mbedtls_pk_init(&key);
   mbedtls_x509write_crt_init(&crt);
   mbedtls_mpi_init(&serial);

   ::Array< ::String> result = null();
   unsigned char *certPem = 0;
   unsigned char *keyPem = 0;
   int ret = 0;

   // One exit path, so each of the five things initialised above is released
   // exactly once however this ends.
   do
   {
      if (!seed(&entropy, &drbg))
      {
         ret = ERROR_SEEDING;
         break;
      }

      ret = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));

      if (ret != 0)
         break;

      ret = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key),
         mbedtls_ctr_drbg_random, &drbg);

      if (ret != 0)
         break;

      // A random serial rather than a counter. Nothing here keeps state between
      // runs, and two certificates from one host sharing a serial is the sort
      // of thing a strict peer is entitled to object to.
      unsigned char serialBytes[SERIAL_BYTES];

      ret = mbedtls_ctr_drbg_random(&drbg, serialBytes, sizeof(serialBytes));

      if (ret != 0)
         break;

      // Cleared so the value is unambiguously positive: a leading bit set would
      // make the DER integer negative.
      serialBytes[0] &= 0x7F;

      ret = mbedtls_mpi_read_binary(&serial, serialBytes, sizeof(serialBytes));

      if (ret != 0)
         break;

      char subject[256];
      int written = snprintf(subject, sizeof(subject), "CN=%s", name);

      if (written < 0 || (size_t)written >= sizeof(subject))
      {
         ret = ERROR_NAME_TOO_LONG;
         break;
      }

      mbedtls_x509write_crt_set_subject_key(&crt, &key);

      // Self signed: the issuer key is the subject key, which is what makes a
      // certificate no authority vouches for and the fingerprint has to.
      mbedtls_x509write_crt_set_issuer_key(&crt, &key);
      mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
      mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);

      ret = mbedtls_x509write_crt_set_subject_name(&crt, subject);

      if (ret != 0)
         break;

      ret = mbedtls_x509write_crt_set_issuer_name(&crt, subject);

      if (ret != 0)
         break;

      ret = mbedtls_x509write_crt_set_serial(&crt, &serial);

      if (ret != 0)
         break;

      ret = mbedtls_x509write_crt_set_validity(&crt, before, after);

      if (ret != 0)
         break;

      ret = mbedtls_x509write_crt_set_basic_constraints(&crt, 0, -1);

      if (ret != 0)
         break;

      certPem = (unsigned char *)malloc(PEM_BUFFER);
      keyPem = (unsigned char *)malloc(PEM_BUFFER);

      if (certPem == 0 || keyPem == 0)
      {
         ret = ERROR_ALLOCATION;
         break;
      }

      memset(certPem, 0, PEM_BUFFER);
      memset(keyPem, 0, PEM_BUFFER);

      ret = mbedtls_x509write_crt_pem(&crt, certPem, PEM_BUFFER,
         mbedtls_ctr_drbg_random, &drbg);

      if (ret != 0)
         break;

      ret = mbedtls_pk_write_key_pem(&key, keyPem, PEM_BUFFER);

      if (ret != 0)
         break;

      result = ::Array_obj< ::String>::__new(2, 2);
      result[0] = ::String::create((const char *)certPem, strlen((const char *)certPem));
      result[1] = ::String::create((const char *)keyPem, strlen((const char *)keyPem));
   } while (false);

   g_lastError = ret;

   if (keyPem != 0)
   {
      // Wiped before release. A private key left in freed memory is a private
      // key still in the process, and this one is the whole security of the
      // session it belongs to.
      mbedtls_platform_zeroize(keyPem, PEM_BUFFER);
      free(keyPem);
   }

   if (certPem != 0)
      free(certPem);

   mbedtls_mpi_free(&serial);
   mbedtls_x509write_crt_free(&crt);
   mbedtls_pk_free(&key);
   mbedtls_ctr_drbg_free(&drbg);
   mbedtls_entropy_free(&entropy);

   return result;
}

::String crossbyte_dtls_fingerprint(::String certificatePem)
{
   _hx_ssl_init();

   if (certificatePem == null())
      return null();

   hx::strbuf pemBuf;
   const char *pem = certificatePem.utf8_str(&pemBuf);
   size_t length = strlen(pem);

   mbedtls_x509_crt cert;
   mbedtls_x509_crt_init(&cert);

   ::String result = null();

   // The trailing NUL counts: mbedtls_x509_crt_parse decides PEM from DER by
   // looking for one, and a length that excludes it makes a PEM certificate
   // fail to parse as though it were malformed.
   if (mbedtls_x509_crt_parse(&cert, (const unsigned char *)pem, length + 1) == 0)
   {
      unsigned char hash[32];

      // Over cert.raw, which is the DER the PEM decoded to. Hashing the PEM
      // text instead would give two different answers for one certificate and
      // agree with no peer on the other end.
      if (mbedtls_sha256_ret(cert.raw.p, cert.raw.len, hash, 0) == 0)
      {
         char formatted[32 * 3];
         static const char *digits = "0123456789ABCDEF";

         for (int i = 0; i < 32; i++)
         {
            formatted[i * 3] = digits[(hash[i] >> 4) & 0x0F];
            formatted[i * 3 + 1] = digits[hash[i] & 0x0F];
            formatted[i * 3 + 2] = ':';
         }

         // The last separator is one too many.
         formatted[32 * 3 - 1] = 0;
         result = ::String::create(formatted, 32 * 3 - 1);
      }
   }

   mbedtls_x509_crt_free(&cert);
   return result;
}
