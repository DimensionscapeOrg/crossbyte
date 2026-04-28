package crossbyte.sys;

/**
 * A lightweight startup description for `NativeProcess`.
 *
 * This mirrors the common parts of AIR's `NativeProcessStartupInfo` in a
 * compact, modern Haxe form.
 */
class NativeProcessStartupInfo {
	public var executable:String;
	public var arguments:Array<String>;

	public function new(executable:String, ?arguments:Array<String>) {
		this.executable = executable;
		this.arguments = arguments != null ? arguments : [];
	}
}
