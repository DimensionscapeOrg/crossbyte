package crossbyte.utils;

/**
 * Defines the available checksum algorithms for verifying data integrity.
 * 
 * A checksum algorithm is used to detect errors in transmitted or stored data.
 * The choice of algorithm depends on factors like speed, collision resistance, and security.
 */
enum ChecksumAlgorithm {
	/**
	 * **CRC32 (Cyclic Redundancy Check - 32-bit)**
	 * 
	 * - A fast, lightweight **error-detection** algorithm.
	 * - Uses a 32-bit polynomial to compute a checksum.
	 * - **Commonly used in networking (Ethernet, ZIP files, PNG images).**
	 * - **Not suitable for cryptographic security** (can be forged).
	 */
	CRC32;

	/**
	 * **Adler-32**
	 * 
	 * - A **simple, fast checksum** algorithm.
	 * - Uses a **modular sum and rolling hash** technique.
	 * - **Faster but less reliable** than CRC32.
	 * - **Used in zlib compression, but rarely in critical integrity checks.**
	 */
	ADLER32;

	/**
	 * **SHA-1 (Secure Hash Algorithm 1)**
	 * 
	 * - Produces a **160-bit cryptographic hash**.
	 * - **More secure** than CRC32 and Adler-32.
	 * - **Considered weak for cryptographic security** (prone to collision attacks).
	 * - **Commonly used in legacy systems and git version control.**
	 */
	SHA1;

	/**
	 * **MD5 (Message Digest Algorithm 5)**
	 * 
	 * - Produces a **128-bit cryptographic hash**.
	 * - **Faster than SHA-1 but less secure** (vulnerable to collision attacks).
	 * - **Still used for file integrity verification (e.g., checksums on downloads).**
	 */
	MD5;

	/**
	 * **XOR Checksum**
	 * 
	 * - A **basic checksum algorithm** that XORs all bytes together.
	 * - **Extremely fast but weak** (cannot detect certain types of errors).
	 * - **Useful for quick, low-cost integrity checks** in simple protocols.
	 */
	XOR;
}
