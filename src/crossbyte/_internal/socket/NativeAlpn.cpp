#include <hxcpp.h>

#include "NativeAlpn.h"

#include <string>
#include <string.h>
#include <vector>

#include "mbedtls/ssl.h"

#ifdef HX_WINDOWS
#include <windows.h>
#else
#include <pthread.h>
#endif

// mbedTLS 3 marks the config's fields private, and MBEDTLS_PRIVATE(x) is the
// name each one has there. 2.28 has neither the macro nor the renaming.
#ifndef MBEDTLS_PRIVATE
#define MBEDTLS_PRIVATE(member) member
#endif

namespace {

// hxcpp wraps each mbedTLS handle in an hx::Object whose definition lives
// inside its SSL.cpp and is not exported. These mirror the layout so the
// handle can be read back out.
//
// Mirroring a private layout is only safe because of two things. The pointer
// is the first and only data member, so a field added later lands after it and
// changes nothing here. And every cast below is guarded by
// `_hx_isInstanceOf`, using the same class id hxcpp assigns -- so a wrong
// object type is refused rather than reinterpreted, and a layout that ever
// does change fails loudly at the first call instead of corrupting memory.
struct HxSslConf : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSslConf };

	mbedtls_ssl_config *c;
};

struct HxSslCtx : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSsl };

	mbedtls_ssl_context *s;
};

mbedtls_ssl_config *configOf(::Dynamic conf) {
	if (conf.mPtr == 0 || !conf.mPtr->_hx_isInstanceOf(hx::clsIdSslConf)) {
		return 0;
	}
	return reinterpret_cast<HxSslConf *>(conf.mPtr)->c;
}

mbedtls_ssl_context *contextOf(::Dynamic ssl) {
	if (ssl.mPtr == 0 || !ssl.mPtr->_hx_isInstanceOf(hx::clsIdSsl)) {
		return 0;
	}
	return reinterpret_cast<HxSslCtx *>(ssl.mPtr)->s;
}

// Every distinct list installed, kept for the life of the process.
//
// mbedTLS stores a config's list by reference -- `conf->alpn_list = protos` --
// and a connection set up on the config keeps a pointer to the name its
// handshake agreed on, which is what `mbedtls_ssl_get_alpn_protocol` hands
// back, with no copy of its own. So a list has to outlive every connection
// that agreed on one of its names, and those outlive the socket that
// installed it: hxcpp shares a listener's config with every connection the
// listener accepts, and keeps the config until the last of them has gone. A
// list was freed when its socket closed, and a connection a server kept on
// after `stopAccepting()` then read its protocol from freed memory -- which
// the next allocation of that size had taken over.
//
// One copy of each distinct list rather than one per config keeps that
// bounded. The lists come from the application, never from a peer -- a
// server's own, the HTTP/2 client's -- so there are a handful, and a client
// no longer allocates one for every connection it makes.
//
// Guarded, because the HTTP/2 client pools connections across threads and each
// one configures its own socket.
std::vector<char **> gInterned;

#ifdef HX_WINDOWS
// Initialised statically, as the pthread one is. A critical section has to be
// initialised by a call, which the first lock made -- and two threads making
// their first HTTP/2 connections at once could both make it.
SRWLOCK gLock = SRWLOCK_INIT;

void lockAcquire() {
	AcquireSRWLockExclusive(&gLock);
}

void lockRelease() {
	ReleaseSRWLockExclusive(&gLock);
}
#else
pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

void lockAcquire() {
	pthread_mutex_lock(&gLock);
}

void lockRelease() {
	pthread_mutex_unlock(&gLock);
}
#endif

void freeList(char **list) {
	if (!list) {
		return;
	}
	for (int i = 0; list[i]; i++) {
		free(list[i]);
	}
	free(list);
}

// A NULL-terminated copy of `names`, as mbedTLS walks it, or 0 when an
// allocation fails.
char **copyList(const std::vector<std::string> &names) {
	char **list = (char **)calloc(names.size() + 1, sizeof(char *));
	if (!list) {
		return 0;
	}
	for (size_t i = 0; i < names.size(); i++) {
		list[i] = (char *)malloc(names[i].size() + 1);
		if (!list[i]) {
			freeList(list);
			return 0;
		}
		memcpy(list[i], names[i].c_str(), names[i].size() + 1);
	}
	return list;
}

bool sameList(char **list, const std::vector<std::string> &names) {
	size_t i = 0;
	for (; list[i]; i++) {
		if (i >= names.size() || names[i] != list[i]) {
			return false;
		}
	}
	return i == names.size();
}

} // namespace

bool crossbyte_alpn_available() {
#if defined(MBEDTLS_SSL_ALPN)
	return true;
#else
	return false;
#endif
}

int crossbyte_alpn_set(::Dynamic conf, ::Array<::String> protocols) {
#if !defined(MBEDTLS_SSL_ALPN)
	return -1;
#else
	mbedtls_ssl_config *config = configOf(conf);
	if (!config) {
		return -1;
	}

	int count = (protocols == null()) ? 0 : protocols->length;
	if (count <= 0) {
		// `mbedtls_ssl_conf_alpn_protocols` walks *protos before testing
		// protos, so passing NULL to turn ALPN off segfaults (2.28 and 3.6
		// alike). The handshake guards on `alpn_list == NULL`, which is the
		// supported way off.
		config->MBEDTLS_PRIVATE(alpn_list) = 0;
		return 0;
	}

	std::vector<std::string> names;
	names.reserve(count);
	for (int i = 0; i < count; i++) {
		::String protocol = protocols->__get(i);
		if (protocol == null()) {
			return -3;
		}
		hx::strbuf buf;
		names.push_back(std::string(protocol.utf8_str(&buf)));
	}

	lockAcquire();

	char **list = 0;
	for (size_t i = 0; i < gInterned.size() && !list; i++) {
		if (sameList(gInterned[i], names)) {
			list = gInterned[i];
		}
	}

	bool fresh = (list == 0);
	if (fresh) {
		list = copyList(names);
		if (!list) {
			lockRelease();
			return -2;
		}
	}

	// Rejects empty names, names over MBEDTLS_SSL_MAX_ALPN_NAME_LEN and lists
	// over MBEDTLS_SSL_MAX_ALPN_LIST_LEN. On failure it has not stored the
	// pointer, so a list made for this call is still ours to free -- and one
	// already kept was accepted before, so is not refused now.
	int result = mbedtls_ssl_conf_alpn_protocols(config, (const char **)list);
	if (result != 0) {
		if (fresh) {
			freeList(list);
		}
		lockRelease();
		return result;
	}

	if (fresh) {
		gInterned.push_back(list);
	}

	lockRelease();
	return 0;
#endif
}

void crossbyte_alpn_release(::Dynamic) {
	// Nothing to give back: the list stays for the connections that agreed on
	// one of its names (see gInterned). The config is left pointing at it,
	// too, rather than cleared: a listener's is shared with the connections
	// it accepted, and one of those may still be in its handshake -- on
	// another thread, under hxcpp's own sockets -- reading the list as this
	// runs. Kept so a socket closes the same way it always has.
}

::String crossbyte_alpn_selected(::Dynamic ssl) {
#if !defined(MBEDTLS_SSL_ALPN)
	return null();
#else
	mbedtls_ssl_context *context = contextOf(ssl);
	if (!context) {
		return null();
	}

	// Points into the config's list, so copy it out rather than wrap it.
	const char *selected = mbedtls_ssl_get_alpn_protocol(context);
	if (selected == 0) {
		return null();
	}

	// RFC 7301 names are ASCII, so a byte-by-byte widen is exact whether
	// HX_CHAR is char or char16_t.
	int length = (int)strlen(selected);
	HX_CHAR *out = hx::NewString(length);
	for (int i = 0; i < length; i++) {
		out[i] = (unsigned char)selected[i];
	}
	out[length] = 0;

	return ::String(out, length);
#endif
}
