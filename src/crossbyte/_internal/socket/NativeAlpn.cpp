#include <hxcpp.h>

#include "NativeAlpn.h"

#include <map>
#include <string.h>

#include "mbedtls/ssl.h"

#ifdef HX_WINDOWS
#include <windows.h>
#else
#include <pthread.h>
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

// mbedTLS stores the ALPN list by reference -- `conf->alpn_list = protos` --
// and `mbedtls_ssl_config_free` only zeroizes the struct without releasing it.
// So the array and every string in it have to outlive the config, and
// something has to own them. A field on hxcpp's struct would be the natural
// home; this is the next best thing, keyed by the config it belongs to.
//
// Guarded, because the HTTP/2 client pools connections across threads and each
// one configures its own socket.
std::map<mbedtls_ssl_config *, char **> gLists;

#ifdef HX_WINDOWS
CRITICAL_SECTION gLock;
bool gLockReady = false;

void lockAcquire() {
	if (!gLockReady) {
		InitializeCriticalSection(&gLock);
		gLockReady = true;
	}
	EnterCriticalSection(&gLock);
}

void lockRelease() {
	LeaveCriticalSection(&gLock);
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

// Replaces whatever was installed for this config, freeing the old list.
//
// Replacing rather than only inserting also covers the one case a table keyed
// by address cannot otherwise survive: a config freed without a release, whose
// address is later handed back out by the allocator. The stale entry is
// overwritten the first time the new owner configures itself.
void remember(mbedtls_ssl_config *conf, char **list) {
	lockAcquire();

	std::map<mbedtls_ssl_config *, char **>::iterator found = gLists.find(conf);
	if (found != gLists.end()) {
		freeList(found->second);
		gLists.erase(found);
	}

	if (list) {
		gLists[conf] = list;
	}

	lockRelease();
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
		// protos, so passing NULL to turn ALPN off segfaults. The handshake
		// guards on `alpn_list == NULL`, which is the supported way off.
		remember(config, 0);
		config->alpn_list = 0;
		return 0;
	}

	// mbedTLS walks the list until it reads a NULL, hence the terminator slot.
	char **list = (char **)calloc(count + 1, sizeof(char *));
	if (!list) {
		return -2;
	}

	for (int i = 0; i < count; i++) {
		::String protocol = protocols->__get(i);
		if (protocol == null()) {
			freeList(list);
			return -3;
		}

		hx::strbuf buf;
		const char *utf8 = protocol.utf8_str(&buf);
		size_t length = strlen(utf8);

		list[i] = (char *)malloc(length + 1);
		if (!list[i]) {
			freeList(list);
			return -2;
		}
		memcpy(list[i], utf8, length + 1);
	}

	// Rejects empty names, names over MBEDTLS_SSL_MAX_ALPN_NAME_LEN and lists
	// over MBEDTLS_SSL_MAX_ALPN_LIST_LEN. On failure it has not stored the
	// pointer, so the list is still ours to free.
	int result = mbedtls_ssl_conf_alpn_protocols(config, (const char **)list);
	if (result != 0) {
		freeList(list);
		return result;
	}

	remember(config, list);
	return 0;
#endif
}

void crossbyte_alpn_release(::Dynamic conf) {
	mbedtls_ssl_config *config = configOf(conf);
	if (!config) {
		return;
	}

	remember(config, 0);

#if defined(MBEDTLS_SSL_ALPN)
	config->alpn_list = 0;
#endif
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
