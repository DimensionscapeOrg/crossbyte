#pragma once

// A DTLS session that owns no socket.
//
// mbedTLS normally drives a file descriptor itself. That is the wrong shape
// here twice over: the socket a WebRTC peer would use is already carrying ICE
// checks and will later carry SCTP, and CrossByte drives its own I/O from a
// tick rather than blocking in a library. So this installs memory callbacks --
// datagrams that arrive are fed in, datagrams mbedTLS wants to send are queued
// and taken out -- and the caller decides when anything moves.
//
// That is the same arrangement `IceAgent` and `TurnClient` use, for the same
// reason, and it means the transport can be exercised by handing two sessions
// each other's datagrams with no network in between.
//
// Sessions are named by an int handle rather than a pointer. Nothing in Haxe
// can then fabricate one, and a handle used after closing is refused instead of
// dereferenced.
//
// Return values: negative is failure, and `crossbyte_dtls_error` says what.

#include <hxcpp.h>
#include <stdint.h>

// Handshake progress, from `crossbyte_dtls_step`.
#define CROSSBYTE_DTLS_HANDSHAKING 0
#define CROSSBYTE_DTLS_ESTABLISHED 1
#define CROSSBYTE_DTLS_CLOSED 2

// Opens a session on a certificate and key, both PEM.
//
// A server here does not run the cookie exchange DTLS normally uses to prove a
// client is reachable at the address it claims. ICE has already done exactly
// that -- a peer that answered a connectivity check demonstrated the round trip
// the cookie exists to demonstrate -- and running it twice would cost another.
//
// Certificates are not verified against any chain either, because WebRTC has no
// authority to verify against: the peer is identified by the fingerprint it
// signalled. The caller must check `crossbyte_dtls_peer_certificate` against
// that fingerprint once the handshake completes, and a session where nobody
// does is a session with no authentication at all.
//
// Returns a handle above zero, or a negative error.
int crossbyte_dtls_open(bool isServer, ::String certificatePem, ::String privateKeyPem);

// Releases a session. A handle that is not open is ignored.
void crossbyte_dtls_close(int handle);

// Hands over a datagram that arrived from the peer.
int crossbyte_dtls_feed(int handle, const uint8_t *data, int length);

// Moves the session forward: continues the handshake, expires retransmission
// timers, and collects any plaintext that has arrived.
//
// `now` is seconds from any clock the caller also uses consistently. DTLS has
// its own retransmission schedule and mbedTLS asks for a timer to run it; this
// is what feeds that timer, so a session that is never stepped never
// retransmits.
//
// Returns one of the CROSSBYTE_DTLS_* states, or negative on failure.
int crossbyte_dtls_step(int handle, double now);

// The size of the next datagram waiting to go out, or 0.
int crossbyte_dtls_pending(int handle);

// Copies the next outgoing datagram into `out` and drops it from the queue.
// Returns the number of bytes written, or negative.
int crossbyte_dtls_take(int handle, uint8_t *out, int capacity);

// Encrypts and queues application data. Returns bytes accepted, or negative.
int crossbyte_dtls_write(int handle, const uint8_t *data, int length);

// The size of the next decrypted message waiting, or 0.
int crossbyte_dtls_available(int handle);

// Copies the next decrypted message into `out`. Returns bytes written.
int crossbyte_dtls_read(int handle, uint8_t *out, int capacity);

// The peer's certificate as PEM, once the handshake has seen one, else null.
//
// Handed back rather than verified here so the fingerprint comparison lives
// beside the signalling that produced the expected value.
::String crossbyte_dtls_peer_certificate(int handle);

// The mbedTLS code behind the last failure on this session, or 0.
int crossbyte_dtls_error(int handle);
