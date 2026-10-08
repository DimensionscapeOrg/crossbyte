package crossbyte._internal.socket;


import haxe.io.Error;

/**
 * Recognises "the socket would block" however the platform spells it.
 *
 * A non-blocking socket with a full send buffer, or nothing yet to read,
 * reports the condition four different ways across the targets CrossByte
 * supports: as `haxe.io.Error.Blocked`; wrapped in `Error.Custom` by the
 * hxcpp debugger; and as the bare strings `"Blocking"` or `"Blocked"`
 * from the TLS layer, which throws before the error is mapped to a type.
 *
 * Written out by hand at every call site, each covering some subset of the
 * spellings, the check would miss one somewhere. That is not a cosmetic bug:
 * a would-block mistaken for a fatal error closes a healthy connection, and a
 * would-block mistaken for success silently discards whatever was being
 * written.
 */
class BlockedError {
	/**
	 * Whether `error` means the operation would have blocked.
	 *
	 * Accepts `Dynamic` deliberately: callers catch from `sys.net.Socket`,
	 * `sys.ssl.Socket` and the hxcpp bridges, which do not agree on a type.
	 */
	public static function isBlocked(error:Dynamic):Bool {
		if (error == null) {
			return false;
		}

		if (Std.isOfType(error, Error)) {
			return __isBlockedError(cast error);
		}

		// The TLS layer raises a bare string before anything maps it to a
		// typed error, so this is the only way to see it there.
		var text:String = Std.string(error);
		return text == "Blocking" || text == "Blocked";
	}

	private static function __isBlockedError(error:Error):Bool {
		return switch (error) {
			// Custom wraps the underlying value, which may itself be either
			// a nested Error or one of the string forms.
			case Error.Custom(value): isBlocked(value);
			case Error.Blocked: true;
			default: false;
		}
	}
}
