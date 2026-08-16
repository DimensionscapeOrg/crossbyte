package crossbyte._internal.socket;

import haxe.io.Error;
import utest.Assert;

/**
 * The shared "would block" predicate.
 *
 * Each spelling here was previously recognised by some call sites and not
 * others, and the consequence of missing one is not cosmetic: a
 * would-block read as fatal closes a healthy connection, and a would-block
 * read as success silently discards what was being written. Both have
 * shipped in this codebase.
 */
class BlockedErrorTest extends utest.Test {
	public function testTypedBlockedIsRecognised():Void {
		Assert.isTrue(BlockedError.isBlocked(Error.Blocked));
	}

	/** hxcpp's debugger wraps the error rather than throwing it directly. */
	public function testBlockedWrappedInCustomIsRecognised():Void {
		Assert.isTrue(BlockedError.isBlocked(Error.Custom(Error.Blocked)));
		// Nested more than once, which Custom permits.
		Assert.isTrue(BlockedError.isBlocked(Error.Custom(Error.Custom(Error.Blocked))));
	}

	/**
	 * The TLS layer raises a bare string before anything maps it to a
	 * typed error, so a typed-only check misses it entirely.
	 */
	public function testStringFormsAreRecognised():Void {
		Assert.isTrue(BlockedError.isBlocked("Blocking"));
		Assert.isTrue(BlockedError.isBlocked("Blocked"));
		Assert.isTrue(BlockedError.isBlocked(Error.Custom("Blocking")));
	}

	/**
	 * Genuine failures must stay failures. Treating one as a would-block
	 * means retrying forever instead of closing, which is the worse
	 * direction to be wrong in.
	 */
	public function testRealErrorsAreNotMistakenForBlocking():Void {
		Assert.isFalse(BlockedError.isBlocked(null));
		Assert.isFalse(BlockedError.isBlocked(Error.OutsideBounds));
		Assert.isFalse(BlockedError.isBlocked(Error.Overflow));
		Assert.isFalse(BlockedError.isBlocked(Error.Custom("ssl network error")));
		Assert.isFalse(BlockedError.isBlocked("Connection reset by peer"));
		Assert.isFalse(BlockedError.isBlocked(new haxe.io.Eof()));
	}
}
