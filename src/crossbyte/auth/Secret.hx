package crossbyte.auth;

/**
 * Shared secret material used by authentication helpers such as JWT signers.
 * Written as an object literal, `{key: "2026-09", secret: value}`, with `key`
 * left out where there is one secret.
 */
@:structInit
final class Secret {
	/** Optional key identifier used to select a specific secret. */
	public var key:Null<String> = null;

	/** Secret bytes represented as a string payload. */
	public var secret:String;
}
