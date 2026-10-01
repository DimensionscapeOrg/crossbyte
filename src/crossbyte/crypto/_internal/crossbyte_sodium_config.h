/*
	What libsodium's configure would have found, said from the compiler's own
	macros, for the gcc and clang builds, which have no configure run: it is
	included ahead of every libsodium source there (NativeSodiumBuild.xml).
	For MSVC, libsodium's private/common.h works the same out itself.

	Without it, the curve25519 field, every X25519 key agreement and every
	Ed25519 signature, was worked in 32-bit limbs where a 64-bit target
	multiplies into 128 bits, Poly1305 likewise, and loads and stores went a
	byte at a time; and on x86-64 none of libsodium's SSE, AVX2 or AVX-512
	code was built, nor could it have been chosen, since nothing asked the
	CPU what it has. On a Ryzen 9 9950X with gcc 13: an X25519 took 41
	microseconds and takes 24; an Ed25519 signature 16 and takes 11, a
	verification 48 and takes 29; Argon2id at its interactive limits about
	72 ms and takes 45; XChaCha20-Poly1305 ran at 0.9 GB/s and runs at 1.9.
	Every one of them answers byte for byte as the portable code does.

	Two groups of sources are built with a switch of their own:
	CROSSBYTE_SODIUM_SCALAR, BLAKE2b's, its SIMD compression ran at half
	the speed of the portable one on that machine, AVX2 included, so it keeps
	the portable one, and CROSSBYTE_SODIUM_RUNTIME, the CPU probe's.
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

/* The x86-64 instruction sets. Each SIMD source enables its own with a
   target pragma, and libsodium picks among them at run time from what the
   CPU reports, so a CPU without AVX2 runs the SSE or portable code. */
#if defined(__x86_64__) && !defined(CROSSBYTE_SODIUM_SCALAR)
# define HAVE_CPUID 1
# define HAVE_MMINTRIN_H 1
# define HAVE_EMMINTRIN_H 1
# define HAVE_PMMINTRIN_H 1
# define HAVE_TMMINTRIN_H 1
# define HAVE_SMMINTRIN_H 1
# define HAVE_AVXINTRIN_H 1
# define HAVE_AVX2INTRIN_H 1
# define HAVE_AVX512FINTRIN_H 1
# define HAVE_WMMINTRIN_H 1
#endif

/* AVX state is enabled by the OS, and the probe reads that with XGETBV,
   which libsodium reaches through an intrinsic gcc does not declare there,
   or through the inline assembly HAVE_AVX_ASM selects. That macro also
   selects assembly sources this build does not compile, so the probe's
   source alone has it. */
#if defined(__x86_64__) && defined(CROSSBYTE_SODIUM_RUNTIME)
# define HAVE_AVX_ASM 1
#endif

#endif
