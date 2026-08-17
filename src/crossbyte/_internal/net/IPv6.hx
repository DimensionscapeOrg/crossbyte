package crossbyte._internal.net;

/**
 * Canonical IPv6 text, so an address reads the same on every target.
 *
 * The platform decides how it renders an address, and the platforms
 * disagree: hxcpp gives the compressed `::1`, the jvm gives the expanded
 * `0:0:0:0:0:0:0:1`. Both are the same address and neither is wrong, but
 * an application that compares what it bound against what it is told back
 * — the obvious thing to do — works on one target and fails on the other.
 *
 * `compress` produces the RFC 5952 canonical form: lowercase, no leading
 * zeros in a group, and the longest run of two or more zero groups
 * replaced by `::` (leftmost when tied).
 */
class IPv6 {
	/**
	 * Returns `address` in canonical IPv6 form, or unchanged if it is not
	 * a plain IPv6 literal.
	 *
	 * Anything that is not an eight-group literal — a hostname, an IPv4
	 * address, an already-compressed form, a zone-suffixed address — is
	 * returned as-is rather than guessed at. Being conservative matters
	 * more than being clever: mangling a hostname would be far worse than
	 * leaving one platform's spelling alone.
	 */
	public static function compress(address:String):String {
		if (address == null || address.indexOf(":") < 0) {
			return address;
		}

		// Already compressed, or carries a zone/scope suffix: leave the
		// structure alone and only normalise case.
		if (address.indexOf("::") >= 0 || address.indexOf("%") >= 0) {
			return address.toLowerCase();
		}

		var groups:Array<String> = address.split(":");
		if (groups.length != 8) {
			return address;
		}

		var values:Array<String> = [];
		for (group in groups) {
			// An IPv4 tail (as in IPv4-mapped addresses) is not hex and is
			// left exactly as written.
			if (group.indexOf(".") >= 0) {
				return address;
			}
			if (group.length == 0 || group.length > 4) {
				return address;
			}
			for (i in 0...group.length) {
				var c:String = group.charAt(i).toLowerCase();
				var isHex:Bool = (c >= "0" && c <= "9") || (c >= "a" && c <= "f");
				if (!isHex) {
					return address;
				}
			}
			// Strip leading zeros, keeping a single zero for an empty group.
			var trimmed:String = group.toLowerCase();
			while (trimmed.length > 1 && trimmed.charAt(0) == "0") {
				trimmed = trimmed.substr(1);
			}
			values.push(trimmed);
		}

		// Longest run of zero groups, leftmost on a tie.
		var bestStart:Int = -1;
		var bestLength:Int = 0;
		var runStart:Int = -1;
		var runLength:Int = 0;

		for (i in 0...values.length) {
			if (values[i] == "0") {
				if (runStart < 0) {
					runStart = i;
					runLength = 0;
				}
				runLength++;
				if (runLength > bestLength) {
					bestLength = runLength;
					bestStart = runStart;
				}
			} else {
				runStart = -1;
				runLength = 0;
			}
		}

		// A single zero group is written out; `::` is only for two or more.
		if (bestLength < 2) {
			return values.join(":");
		}

		var head:String = values.slice(0, bestStart).join(":");
		var tail:String = values.slice(bestStart + bestLength).join(":");
		return head + "::" + tail;
	}
}
