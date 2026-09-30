#pragma once

// Guarded as NativeAlpn.h is, and for the same reason: generated code pulls
// this in through `@:include` having already had hxcpp.h through the
// precompiled header, and a second <hxcpp.h> sends gcc to hxcpp's __pch
// directory, which holds hxcpp.h.gch and no hxcpp.h, "fatal error:
// .../__pch/haxe/hxcpp.h: No such file or directory", on Linux only.
#ifndef HXCPP_H
#include <hxcpp.h>
#endif

// The DER of the certificate the peer presented on an hxcpp TLS context, or
// null when there is none. See NativeTlsPeer.hx.
Array<unsigned char> crossbyte_tls_peer_der(::Dynamic ssl);
