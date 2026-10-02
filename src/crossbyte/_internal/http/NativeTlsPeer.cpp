#include <hxcpp.h>

#include "NativeTlsPeer.h"

#include <string.h>

#include "mbedtls/version.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

// mbedTLS 3 marks the structures' fields private, and MBEDTLS_PRIVATE(x) is the
// name each one has there; 2.28 has neither the macro nor the renaming.
#ifndef MBEDTLS_PRIVATE
#define MBEDTLS_PRIVATE(member) member
#endif

namespace {

// hxcpp wraps each mbedTLS context in an hx::Object whose definition lives in
// its SSL.cpp and is not exported, so the layout is mirrored here, as
// NativeAlpn.cpp mirrors it, and for the same two reasons it is safe: the
// pointer is the first and only data member, and every cast is guarded by
// `_hx_isInstanceOf` with the class id hxcpp assigns, so another object is
// refused rather than reinterpreted.
struct HxSslCtx : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSsl };

	mbedtls_ssl_context *s;
};

} // namespace

Array<unsigned char> crossbyte_tls_peer_der(::Dynamic ssl) {
	if (ssl.mPtr == 0 || !ssl.mPtr->_hx_isInstanceOf(hx::clsIdSsl)) {
		return null();
	}

	mbedtls_ssl_context *context = reinterpret_cast<HxSslCtx *>(ssl.mPtr)->s;
	if (context == 0) {
		return null();
	}

	// Kept for the life of the session: hxcpp's own mbedTLS is built with
	// MBEDTLS_SSL_KEEP_PEER_CERTIFICATE, which its peerCertificate() needs too.
	const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(context);
	if (peer == 0 || peer->raw.p == 0 || peer->raw.len == 0) {
		return null();
	}

	int length = (int)peer->raw.len;
	Array<unsigned char> der = Array_obj<unsigned char>::__new(length, length);
	memcpy(der->GetBase(), peer->raw.p, peer->raw.len);
	return der;
}

::String crossbyte_tls_peer_protocol(::Dynamic ssl) {
	if (ssl.mPtr == 0 || !ssl.mPtr->_hx_isInstanceOf(hx::clsIdSsl)) {
		return null();
	}

	mbedtls_ssl_context *context = reinterpret_cast<HxSslCtx *>(ssl.mPtr)->s;
	if (context == 0) {
		return null();
	}

	// A static string either way: "TLSv1.2", "TLSv1.3", or mbedTLS's word for
	// a session that has not agreed on one yet.
	return ::String::create(mbedtls_ssl_get_version(context));
}

int crossbyte_tls_peer_endpoint(::Dynamic ssl) {
	if (ssl.mPtr == 0 || !ssl.mPtr->_hx_isInstanceOf(hx::clsIdSsl)) {
		return -1;
	}

	mbedtls_ssl_context *context = reinterpret_cast<HxSslCtx *>(ssl.mPtr)->s;
	if (context == 0) {
		return -1;
	}

	// Through the context, as mbedTLS itself goes on every record it reads or
	// writes: the configuration is not the context's to keep, and has to stay
	// alive and unchanged for as long as the context does.
	const mbedtls_ssl_config *config = context->MBEDTLS_PRIVATE(conf);
	if (config == 0) {
		return -1;
	}
	return (int)config->MBEDTLS_PRIVATE(endpoint);
}

int crossbyte_tls_mbedtls_version() {
	return (int)MBEDTLS_VERSION_NUMBER;
}
