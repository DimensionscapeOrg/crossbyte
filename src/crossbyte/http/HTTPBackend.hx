package crossbyte.http;

/**
 * Extension point for HTTP protocol backends that are not bundled with core.
 */
interface HTTPBackend {
	public function supports(version:HTTPVersion):Bool;
	public function load(context:HTTPRequestContext):Void;
}
