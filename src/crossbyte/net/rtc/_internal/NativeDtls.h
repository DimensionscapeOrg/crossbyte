#pragma once

// The certificate half of DTLS, over the mbedTLS hxcpp already links.
//
// WebRTC peers do not use a certificate authority. Each side generates a
// self-signed certificate, sends the fingerprint of it over the signalling
// channel that already brought the two together, and verifies that the
// certificate presented in the DTLS handshake hashes to what was signalled.
// The trust comes from the signalling channel; the certificate only has to be
// stable for the length of a session, which is why generating one per peer is
// normal rather than negligent.
//
// Nothing here reaches into hxcpp's own SSL objects the way the ALPN bridge
// does. hxcpp creates mbedTLS contexts for TLS over TCP and never for DTLS, so
// there is nothing to borrow -- this owns what it makes.
//
// Symbols are named `crossbyte_*` so they cannot collide if hxcpp later grows
// its own, which is the same rule the ALPN bridge follows.

// Guarded because this header is pulled into generated code by
// `@:include`, which has already had hxcpp.h through the precompiled
// header. Including it again makes gcc resolve <hxcpp.h> a second time,
// and the first thing on the include path is hxcpp's own __pch directory,
// which holds hxcpp.h.gch rather than hxcpp.h -- so the build stops at
// "fatal error: .../__pch/haxe/hxcpp.h: No such file or directory". MSVC
// resolves it differently, which is why this only ever broke on Linux.
#ifndef HXCPP_H
#include <hxcpp.h>
#endif

// Reports whether the native backend is compiled in.
bool crossbyte_dtls_available();

// Generates a self-signed P-256 certificate and its private key.
//
// P-256 rather than RSA because it is what every WebRTC implementation
// defaults to: the keys are two orders of magnitude faster to generate, which
// matters when a certificate is made per session rather than per deployment.
//
// `notBefore` and `notAfter` are mbedTLS validity strings, "YYYYMMDDHHMMSS".
// They are passed in rather than computed here so the clock stays on the Haxe
// side, where the rest of CrossByte already reads it.
//
// Returns a two element array of PEM strings, certificate then private key, or
// null if generation failed.
::Array<::String> crossbyte_dtls_generate(::String commonName, ::String notBefore, ::String notAfter);

// The SHA-256 fingerprint of a PEM certificate, as SDP writes it: colon
// separated uppercase hex.
//
// Taken over the DER the certificate parses to, not over the PEM text. Two
// encodings of one certificate are the same certificate and must produce the
// same fingerprint, and a peer on the other end is hashing the DER it received
// on the wire.
//
// Returns null if the PEM will not parse.
::String crossbyte_dtls_fingerprint(::String certificatePem);

// The code from the mbedtls call that last refused, or 0.
//
// A bridge that hands back null says only that something went wrong, which is
// the least useful thing it could say about a failure nobody can reproduce on
// demand. Negative values below -1000 are mbedtls's own; -1, -2 and -3 are
// seeding, allocation and a name too long for the buffer.
int crossbyte_dtls_last_error();
