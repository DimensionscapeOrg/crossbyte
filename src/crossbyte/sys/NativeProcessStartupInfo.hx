package crossbyte.sys;

/**
 * A lightweight startup description for `NativeProcess`.
 *
 * This mirrors the common parts of AIR's `NativeProcessStartupInfo` in a
 * compact, modern Haxe form.
 */
class NativeProcessStartupInfo {
	public var executable:String;

	/**
		The arguments, each reaching the program as one.

		On Windows, natively, on HashLink and on neko each goes in quotes, as
		Haxe's `sys.io.Process` writes them. Programs read that as they should,
		but `cmd.exe` takes a quoted word for the name of a program, never one
		of its own commands: `cmd.exe /C echo hi` runs an `echo.exe` from the
		PATH there, or fails where there is none. Run a program instead. The
		jvm and Node quote only an argument that needs it.
	**/
	public var arguments:Array<String>;

	public function new(executable:String, ?arguments:Array<String>) {
		this.executable = executable;
		this.arguments = arguments != null ? arguments : [];
	}
}
