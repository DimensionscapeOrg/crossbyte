#pragma once

// ALPN (RFC 7301) for the TLS sockets hxcpp already provides.
//
// mbedTLS has carried ALPN all along and hxcpp compiles it in, but nothing in
// `sys.ssl.Socket` reaches it, which is what makes HTTP/2 over TLS
// unreachable rather than merely unimplemented, since ALPN is the only way a
// client says `h2` and there is no in-band upgrade to fall back on.
//
// This lives in CrossByte rather than as a patch to hxcpp's SSL.cpp on
// purpose. A patch means every build needs a forked hxcpp, and a link error,
// not a missing feature, for anyone using a stock one. The symbols here
// are named `crossbyte_*` so they cannot collide if hxcpp later grows its own,
// which is the intent upstream.
//
// Return values: 0 on success, negative on failure.

// Guarded because this header is pulled into generated code by
// `@:include`, which has already had hxcpp.h through the precompiled
// header. Including it again makes gcc resolve <hxcpp.h> a second time,
// and the first thing on the include path is hxcpp's own __pch directory,
// which holds hxcpp.h.gch rather than hxcpp.h, so the build stops at
// "fatal error: .../__pch/haxe/hxcpp.h: No such file or directory". MSVC
// resolves it differently, which is why this only ever broke on Linux.
#ifndef HXCPP_H
#include <hxcpp.h>
#endif

// Reports whether the native backend is compiled in.
bool crossbyte_alpn_available();

// Advertises `protocols` on the config wrapped by `conf`, in descending order
// of preference. Must be called before the handshake reads the config.
//
// `conf` is the `Dynamic` that `cpp.NativeSsl.conf_new()` returned. Passing an
// empty list clears any previous one.
int crossbyte_alpn_set(::Dynamic conf, ::Array<::String> protocols);

// Called when the socket that installed a list on `conf` is done with it, and
// does nothing: each distinct list is kept for the life of the process, since
// the connections that agreed on one of its names point into it and can
// outlive that socket. See NativeAlpn.cpp.
void crossbyte_alpn_release(::Dynamic conf);

// The protocol agreed during the handshake on the context wrapped by `ssl`, or
// null when the handshake has not completed or none was negotiated.
::String crossbyte_alpn_selected(::Dynamic ssl);
