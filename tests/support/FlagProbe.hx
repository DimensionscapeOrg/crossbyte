/**
	Runs on python, the one CSPRNG-less UDP target this machine can execute.

	Before the fix this printed `StunClient.isSupported = true` and then threw
	from the first line of discover() -- the lying-flag bug DatagramSocket's own
	documentation warns about, demonstrated rather than reasoned.
**/
class FlagProbe {
	static function main():Void {
		var udp = crossbyte.net.DatagramSocket.isSupported;
		var rng = crossbyte.crypto.SecureRandom.isSupported;
		var stun = crossbyte.net.StunClient.isSupported;

		Sys.println("DatagramSocket.isSupported = " + udp);
		Sys.println("SecureRandom.isSupported   = " + rng);
		Sys.println("StunClient.isSupported     = " + stun);

		if (stun && !rng) {
			Sys.println("FAIL: the flag lies -- discovery would throw on its first line");
			Sys.exit(1);
		}

		// And a caller who never read the flag gets a failed future that names
		// the reason, not a throw.
		var settled = false;

		try {
			crossbyte.net.StunClient.discover("198.51.100.1", 3478, 1000).then(function(address) {
				Sys.println("FAIL: an address came back with no CSPRNG: " + address);
				Sys.exit(1);
			}, function(error) {
				settled = true;
				Sys.println("discover refused gracefully: " + error);
			});
		} catch (e:Dynamic) {
			Sys.println("FAIL: discover threw instead of failing the future: " + Std.string(e));
			Sys.exit(1);
		}

		if (!settled && !stun) {
			Sys.println("FAIL: discover neither settled nor threw on an unsupported target");
			Sys.exit(1);
		}

		Sys.println("OK: the flag tells the truth and discovery refuses politely");
	}
}
