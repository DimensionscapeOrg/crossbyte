#pragma once

// ALPN (RFC 7301) for the TLS sockets hxcpp already provides.
//
// mbedTLS has carried ALPN all along and hxcpp compiles it in, but nothing in
// `sys.ssl.Socket` reaches it -- which is what makes HTTP/2 over TLS
// unreachable rather than merely unimplemented, since ALPN is the only way a
// client says `h2` and there is no in-band upgrade to fall back on.
//
// This lives in CrossByte rather than as a patch to hxcpp's SSL.cpp on
// purpose. A patch means every build needs a forked hxcpp, and a link error
// -- not a missing feature -- for anyone using a stock one. The symbols here
// are named `crossbyte_*` so they cannot collide if hxcpp later grows its own,
// which is the intent upstream.
//
// Return values: 0 on success, negative on failure.

#include <hxcpp.h>

// Reports whether the native backend is compiled in.
bool crossbyte_alpn_available();

// Advertises `protocols` on the config wrapped by `conf`, in descending order
// of preference. Must be called before the handshake reads the config.
//
// `conf` is the `Dynamic` that `cpp.NativeSsl.conf_new()` returned. Passing an
// empty list clears any previous one.
int crossbyte_alpn_set(::Dynamic conf, ::Array<::String> protocols);

// Releases the list installed for `conf` and clears it from the config.
//
// Deterministic rather than left to a finalizer: mbedTLS stores the list by
// reference and never owns it, so something has to, and the socket that
// installed it is the only thing that knows when it is done.
void crossbyte_alpn_release(::Dynamic conf);

// The protocol agreed during the handshake on the context wrapped by `ssl`, or
// null when the handshake has not completed or none was negotiated.
::String crossbyte_alpn_selected(::Dynamic ssl);
