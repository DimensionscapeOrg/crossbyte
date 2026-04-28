// CrossByte native BLAKE3 bridge.
//
// The official BLAKE3 sources are compiled as separate hxcpp build units from
// NativeBlake3Build.xml. This bridge exposes a compact native API to Haxe and
// leaves CPU-specific optimization selection to the compiled BLAKE3 dispatch
// layer.

#include <stdint.h>
#include <stddef.h>

#include "./vendor/blake3/blake3.h"
#include "./vendor/blake3/blake3_impl.h"

extern "C" int crossbyte_crypto_blake3_hash(const uint8_t *input, int inputLength, uint8_t *output, int outputLength) {
	if (output == nullptr || outputLength < 0 || inputLength < 0) {
		return -1;
	}

	blake3_hasher hasher;
	blake3_hasher_init(&hasher);

	if (input != nullptr && inputLength > 0) {
		blake3_hasher_update(&hasher, input, (size_t)inputLength);
	}

	blake3_hasher_finalize(&hasher, output, (size_t)outputLength);
	return 0;
}

extern "C" int crossbyte_crypto_blake3_simd_degree() {
	return (int)blake3_simd_degree();
}
