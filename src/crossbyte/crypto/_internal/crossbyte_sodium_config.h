/*
	What libsodium's configure would have found, said from the compiler's own
	macros, for the gcc and clang builds, which have no configure run: it is
	included ahead of every libsodium source there (NativeSodiumBuild.xml).
	For MSVC, libsodium's private/common.h works the same out itself.

	Without it, the curve25519 field -- every X25519 key agreement and every
	Ed25519 signature -- was worked in 32-bit limbs where a 64-bit target
	multiplies into 128 bits, Poly1305 likewise, and loads and stores went a
	byte at a time. On a Ryzen 9 9950X with gcc 13: an X25519 took 41
	microseconds and takes 24; an Ed25519 signature 16 and takes 11; a
	verification 48 and takes 29.

	Left out: the instruction-set families (HAVE_*INTRIN_H, HAVE_CPUID). On
	the same machine they made Argon2 and ChaCha20 faster but BLAKE2b half as
	fast, and libsodium cannot find AVX2 without XGETBV, which it reaches only
	through its assembly sources or an intrinsic gcc does not declare there.
*/
#ifndef CROSSBYTE_SODIUM_CONFIG_H
#define CROSSBYTE_SODIUM_CONFIG_H

/* Says a configure run's results are here, which stops libsodium warning,
   three lines for each of its sources, that it is "being compiled using an
   undocumented method". */
#define CONFIGURED 1

/* A configure run also says how to make a variable thread-local, and with
   CONFIGURED set and no answer, randombytes_internal_random.c makes its
   state one for the whole process. Thread-local, as it was without. */
#if !defined(TLS) && !defined(__STDC_NO_THREADS__) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
# define TLS _Thread_local
#endif

#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
# define NATIVE_LITTLE_ENDIAN 1
#endif

/* Only where a 64-bit multiply gives the high half: configure asks for
   128-bit products that need no helper call, which rules out the 32-bit
   targets, wasm32 among them, even where the compiler offers __int128. */
#if defined(__SIZEOF_INT128__) && (defined(__x86_64__) || defined(__aarch64__))
# define HAVE_TI_MODE 1
#endif

#endif
