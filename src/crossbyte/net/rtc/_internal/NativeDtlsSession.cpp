#include "NativeDtlsSession.h"

// See NativeDtls.cpp: hxcpp builds mbedtls with MBEDTLS_THREADING_C, and a file
// that disagrees about that declares every mutex-bearing struct at the wrong
// size. The failure is silent until it is fatal somewhere unrelated.
#ifndef MBEDTLS_THREADING_C
#error "NativeDtlsBuild.xml must define MBEDTLS_THREADING_C to match how hxcpp builds mbedtls, or every struct shared with it is the wrong size."
#endif

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/pem.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#include <deque>
#include <map>
#include <string>
#include <vector>

#include <stdlib.h>
#include <string.h>

// hxcpp's SSL initialiser, which installs the alt mutex callbacks. Until it
// runs mbedtls_mutex_lock is a stub that fails, and anything touching a
// mutex-bearing struct refuses for reasons that look like nothing.
extern void _hx_ssl_init();

namespace {

const int ERROR_NO_SESSION = -1000001;
const int ERROR_BAD_CERTIFICATE = -1000002;
const int ERROR_BAD_KEY = -1000003;
const int ERROR_TOO_SMALL = -1000004;

// One datagram.
typedef std::vector<uint8_t> Packet;

struct Timer
{
   double now;
   double intermediate;
   double finish;
   bool running;

   Timer() : now(0), intermediate(0), finish(0), running(false) {}
};

struct Session
{
   mbedtls_ssl_context ssl;
   mbedtls_ssl_config conf;
   mbedtls_x509_crt cert;
   mbedtls_pk_context key;

   std::deque<Packet> inbound;
   std::deque<Packet> outbound;
   std::deque<Packet> plaintext;

   Timer timer;
   int state;
   int error;
   bool handshakeDone;

   Session() : state(CROSSBYTE_DTLS_HANDSHAKING), error(0), handshakeDone(false) {}
};

std::map<int, Session *> g_sessions;
int g_nextHandle = 1;

// Shared across sessions. mbedTLS guards it with the mutex MBEDTLS_THREADING_C
// gives it, which is exactly the configuration hxcpp builds, so one is safe and
// seeding per session would only be slower.
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_drbg;
bool g_rngReady = false;

bool ensureRng()
{
   if (g_rngReady)
      return true;

   static const char personal[] = "crossbyte-dtls-session";

   mbedtls_entropy_init(&g_entropy);
   mbedtls_ctr_drbg_init(&g_drbg);

   if (mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
          (const unsigned char *)personal, sizeof(personal) - 1) != 0)
      return false;

   g_rngReady = true;
   return true;
}

Session *find(int handle)
{
   std::map<int, Session *>::iterator at = g_sessions.find(handle);
   return at == g_sessions.end() ? 0 : at->second;
}

// mbedTLS wants to put a datagram on the wire. It goes on a queue instead, and
// the caller takes it from there.
int sendCallback(void *ctx, const unsigned char *buf, size_t len)
{
   Session *session = (Session *)ctx;
   session->outbound.push_back(Packet(buf, buf + len));
   return (int)len;
}

// mbedTLS wants a datagram. WANT_READ rather than a block, because nothing here
// is allowed to wait: the caller is driving this from a tick and the datagram
// may not have arrived yet.
int recvCallback(void *ctx, unsigned char *buf, size_t len)
{
   Session *session = (Session *)ctx;

   if (session->inbound.empty())
      return MBEDTLS_ERR_SSL_WANT_READ;

   Packet &front = session->inbound.front();

   // A datagram is a message, not a stream. One that will not fit is truncated
   // and reported as oversized rather than split, because half a record is not
   // a record.
   if (front.size() > len)
   {
      session->inbound.pop_front();
      return MBEDTLS_ERR_SSL_WANT_READ;
   }

   size_t size = front.size();
   memcpy(buf, front.empty() ? (const uint8_t *)"" : &front[0], size);
   session->inbound.pop_front();
   return (int)size;
}

void setTimer(void *ctx, uint32_t intermediateMs, uint32_t finishMs)
{
   Timer *timer = (Timer *)ctx;

   if (finishMs == 0)
   {
      timer->running = false;
      return;
   }

   timer->running = true;
   timer->intermediate = timer->now + intermediateMs / 1000.0;
   timer->finish = timer->now + finishMs / 1000.0;
}

int getTimer(void *ctx)
{
   Timer *timer = (Timer *)ctx;

   if (!timer->running)
      return -1;

   if (timer->now >= timer->finish)
      return 2;

   if (timer->now >= timer->intermediate)
      return 1;

   return 0;
}

// Collects whatever plaintext has become readable. Called after every step, so
// a caller that only ever steps still sees its data.
void drainPlaintext(Session *session)
{
   for (;;)
   {
      unsigned char buffer[MBEDTLS_SSL_IN_CONTENT_LEN > 16384 ? 16384 : MBEDTLS_SSL_IN_CONTENT_LEN];
      int read = mbedtls_ssl_read(&session->ssl, buffer, sizeof(buffer));

      if (read > 0)
      {
         session->plaintext.push_back(Packet(buffer, buffer + read));
         continue;
      }

      if (read == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
      {
         session->state = CROSSBYTE_DTLS_CLOSED;
         return;
      }

      // WANT_READ is the ordinary end of the queue, not a fault.
      if (read != MBEDTLS_ERR_SSL_WANT_READ && read != MBEDTLS_ERR_SSL_WANT_WRITE && read != 0)
         session->error = read;

      return;
   }
}

} // namespace

int crossbyte_dtls_open(bool isServer, ::String certificatePem, ::String privateKeyPem)
{
   _hx_ssl_init();

   if (certificatePem == null() || privateKeyPem == null())
      return ERROR_BAD_CERTIFICATE;

   if (!ensureRng())
      return ERROR_BAD_CERTIFICATE;

   hx::strbuf certBuf;
   hx::strbuf keyBuf;

   const char *certPem = certificatePem.utf8_str(&certBuf);
   const char *keyPem = privateKeyPem.utf8_str(&keyBuf);

   Session *session = new Session();

   mbedtls_ssl_init(&session->ssl);
   mbedtls_ssl_config_init(&session->conf);
   mbedtls_x509_crt_init(&session->cert);
   mbedtls_pk_init(&session->key);

   int ret = 0;

   do
   {
      // The trailing NUL is part of the length for PEM, which is how the parser
      // tells PEM from DER.
      ret = mbedtls_x509_crt_parse(&session->cert, (const unsigned char *)certPem, strlen(certPem) + 1);

      if (ret != 0)
      {
         ret = ERROR_BAD_CERTIFICATE;
         break;
      }

      // Five arguments, not seven: the RNG parameters are a 3.x addition and
      // hxcpp ships 2.28.
      ret = mbedtls_pk_parse_key(&session->key, (const unsigned char *)keyPem, strlen(keyPem) + 1, 0, 0);

      if (ret != 0)
      {
         ret = ERROR_BAD_KEY;
         break;
      }

      ret = mbedtls_ssl_config_defaults(&session->conf,
         isServer ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
         MBEDTLS_SSL_TRANSPORT_DATAGRAM, MBEDTLS_SSL_PRESET_DEFAULT);

      if (ret != 0)
         break;

      // OPTIONAL, and the distinction from NONE is the whole of mutual
      // authentication here. There is no chain to verify -- WebRTC identifies a
      // peer by the fingerprint it signalled, which the caller checks against
      // crossbyte_dtls_peer_certificate -- so it is tempting to ask for no
      // verification at all. But NONE means a server never sends a certificate
      // request, so the client never sends a certificate, so the server has
      // nothing to fingerprint and the peer at that end is unauthenticated.
      //
      // OPTIONAL asks for the certificate and declines to fail the handshake
      // over a chain that leads nowhere, which is exactly the arrangement
      // wanted: mbedtls delivers the certificate, and the fingerprint decides.
      // That check is not optional in turn, which is why DtlsTransport cannot
      // be constructed without an expected fingerprint to compare against.
      mbedtls_ssl_conf_authmode(&session->conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
      mbedtls_ssl_conf_rng(&session->conf, mbedtls_ctr_drbg_random, &g_drbg);

      ret = mbedtls_ssl_conf_own_cert(&session->conf, &session->cert, &session->key);

      if (ret != 0)
         break;

      if (isServer)
      {
         // The cookie exchange proves a client is reachable at the address it
         // claims, so that a forged source address cannot make a server hold
         // state. ICE has already proved exactly that, one round trip earlier,
         // by getting an answer to a connectivity check.
         mbedtls_ssl_conf_dtls_cookies(&session->conf, 0, 0, 0);
      }

      ret = mbedtls_ssl_setup(&session->ssl, &session->conf);

      if (ret != 0)
         break;

      mbedtls_ssl_set_bio(&session->ssl, session, sendCallback, recvCallback, 0);
      mbedtls_ssl_set_timer_cb(&session->ssl, &session->timer, setTimer, getTimer);
   } while (false);

   if (ret != 0)
   {
      mbedtls_ssl_free(&session->ssl);
      mbedtls_ssl_config_free(&session->conf);
      mbedtls_x509_crt_free(&session->cert);
      mbedtls_pk_free(&session->key);
      delete session;
      return ret;
   }

   int handle = g_nextHandle++;
   g_sessions[handle] = session;
   return handle;
}

void crossbyte_dtls_close(int handle)
{
   Session *session = find(handle);

   if (session == 0)
      return;

   mbedtls_ssl_free(&session->ssl);
   mbedtls_ssl_config_free(&session->conf);
   mbedtls_x509_crt_free(&session->cert);
   mbedtls_pk_free(&session->key);

   delete session;
   g_sessions.erase(handle);
}

int crossbyte_dtls_feed(int handle, const uint8_t *data, int length)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   if (length > 0 && data != 0)
      session->inbound.push_back(Packet(data, data + length));

   return 0;
}

int crossbyte_dtls_step(int handle, double now)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   session->timer.now = now;

   if (session->state == CROSSBYTE_DTLS_CLOSED)
      return session->state;

   if (!session->handshakeDone)
   {
      int ret = mbedtls_ssl_handshake(&session->ssl);

      if (ret == 0)
      {
         session->handshakeDone = true;
         session->state = CROSSBYTE_DTLS_ESTABLISHED;
      }
      else if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
      {
         // Waiting on the peer, which over a datagram transport is the normal
         // condition rather than an error.
         return session->state;
      }
      else if (ret == MBEDTLS_ERR_SSL_HELLO_VERIFY_REQUIRED)
      {
         // A server asked for a cookie despite cookies being off. Restarting is
         // what mbedTLS expects here.
         mbedtls_ssl_session_reset(&session->ssl);
         return session->state;
      }
      else
      {
         session->error = ret;
         session->state = CROSSBYTE_DTLS_CLOSED;
         return ret;
      }
   }

   if (session->state == CROSSBYTE_DTLS_ESTABLISHED)
      drainPlaintext(session);

   return session->state;
}

int crossbyte_dtls_pending(int handle)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   return session->outbound.empty() ? 0 : (int)session->outbound.front().size();
}

int crossbyte_dtls_take(int handle, uint8_t *out, int capacity)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   if (session->outbound.empty())
      return 0;

   Packet &front = session->outbound.front();

   if ((int)front.size() > capacity)
      return ERROR_TOO_SMALL;

   int size = (int)front.size();

   if (size > 0)
      memcpy(out, &front[0], size);

   session->outbound.pop_front();
   return size;
}

int crossbyte_dtls_write(int handle, const uint8_t *data, int length)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   if (session->state != CROSSBYTE_DTLS_ESTABLISHED)
      return MBEDTLS_ERR_SSL_WANT_WRITE;

   int written = mbedtls_ssl_write(&session->ssl, data, length);

   if (written < 0)
      session->error = written;

   return written;
}

int crossbyte_dtls_available(int handle)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   return session->plaintext.empty() ? 0 : (int)session->plaintext.front().size();
}

int crossbyte_dtls_read(int handle, uint8_t *out, int capacity)
{
   Session *session = find(handle);

   if (session == 0)
      return ERROR_NO_SESSION;

   if (session->plaintext.empty())
      return 0;

   Packet &front = session->plaintext.front();

   if ((int)front.size() > capacity)
      return ERROR_TOO_SMALL;

   int size = (int)front.size();

   if (size > 0)
      memcpy(out, &front[0], size);

   session->plaintext.pop_front();
   return size;
}

::String crossbyte_dtls_peer_certificate(int handle)
{
   Session *session = find(handle);

   if (session == 0)
      return null();

   const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&session->ssl);

   if (peer == 0)
      return null();

   // Written back out as PEM so the Haxe side can hand it to the same
   // fingerprint function it uses on its own certificates, rather than growing
   // a second path that could disagree with the first.
   size_t olen = 0;
   std::vector<unsigned char> buffer(peer->raw.len * 2 + 128);

   if (mbedtls_pem_write_buffer("-----BEGIN CERTIFICATE-----\n", "-----END CERTIFICATE-----\n",
          peer->raw.p, peer->raw.len, &buffer[0], buffer.size(), &olen) != 0)
      return null();

   return ::String::create((const char *)&buffer[0], (int)strlen((const char *)&buffer[0]));
}

int crossbyte_dtls_error(int handle)
{
   Session *session = find(handle);
   return session == 0 ? ERROR_NO_SESSION : session->error;
}
