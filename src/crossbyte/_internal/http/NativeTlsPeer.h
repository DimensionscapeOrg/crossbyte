#pragma once

// Guarded as NativeAlpn.h is, and for the same reason: generated code pulls
// this in through `@:include` having already had hxcpp.h through the
// precompiled header, and a second <hxcpp.h> sends gcc to hxcpp's __pch
// directory, which holds hxcpp.h.gch and no hxcpp.h ("fatal error:
// .../__pch/haxe/hxcpp.h: No such file or directory"), on Linux only.
#ifndef HXCPP_H
#include <hxcpp.h>
#endif

// The DER of the certificate the peer presented on an hxcpp TLS context, or
// null when there is none. See NativeTlsPeer.hx.
Array<unsigned char> crossbyte_tls_peer_der(::Dynamic ssl);

// The protocol an hxcpp TLS context runs, as mbedTLS names it ("TLSv1.3"), or
// null for anything that is not one.
::String crossbyte_tls_peer_protocol(::Dynamic ssl);

// The end of the handshake the configuration under an hxcpp TLS context says
// it is, MBEDTLS_SSL_IS_SERVER (1) or MBEDTLS_SSL_IS_CLIENT (0), or -1 for
// anything that is not one.
int crossbyte_tls_peer_endpoint(::Dynamic ssl);

// MBEDTLS_VERSION_NUMBER of the mbedTLS hxcpp built this program with.
int crossbyte_tls_mbedtls_version();
