package crossbyte._internal.socket;

interface IPollableSocket {
	public var registryClosed(get, never):Bool;
	public function registryOnReadable():Void;
	public function registryOnWritable():Void;
}
